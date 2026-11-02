# Redis — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/redis/`](../../../../environments/dev/kubernetes/tools/redis/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Cache, ephemeral store and rate-limit backend. Consumed by the app tier
(`redis-master.database.svc.cluster.local:6379`) and by Harbor.

| | |
|---|---|
| Chart | `bitnami/redis` |
| Version | `20.11.3` |
| Release / Namespace | `redis` / `database` |
| Selector | `-l name=redis` |
| Labels | `layer=platform, tier=infra, component=cache` |
| Values | `values.yaml.gotmpl` + `files/redis.conf` |
| Secrets | `.Values.secrets.redis.password` (SOPS → Secret `redis`) |

| Env | Architecture | Replicas | Storage |
|---|---|---|---|
| dev | standalone | 0 | 5Gi |
| staging | standalone | 0 | 8Gi |
| prod | replication (+Sentinel) | 2 | 20Gi |

---

## 1. Prerequisites

- `database` namespace + PSA labels applied.
- SOPS key `secrets.redis.password` present in `environments/<env>/kubernetes/secrets.enc.yaml`.
- Bitnami registry decision made for prod (mirror through Harbor — see
  `releases/platform/postgresql/README.md`).
- `kube-prometheus-stack` for the ServiceMonitor CRD.

---

## 2. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f releases/platform/redis/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/redis/helmfile.yaml.gotmpl sync
```

`files/redis.conf` is the source of truth for tunables (maxmemory policy, persistence,
timeouts) and is read into `commonConfiguration` — edit the file, not the values.

---

## 3. Verify

```bash
kubectl -n database rollout status statefulset/redis-master --timeout=300s

PASS=$(kubectl -n database get secret redis -o jsonpath='{.data.redis-password}' | base64 -d)
kubectl -n database exec -it redis-master-0 -- redis-cli -a "$PASS" ping          # PONG
kubectl -n database exec -it redis-master-0 -- redis-cli -a "$PASS" info replication
kubectl -n database exec -it redis-master-0 -- redis-cli -a "$PASS" info memory | grep -E 'used_memory_human|maxmemory_human'
```

Prod: `info replication` should list the connected replicas, and Sentinel should agree on
the master:

```bash
kubectl -n database exec -it redis-node-0 -c sentinel -- \
  redis-cli -p 26379 sentinel master mymaster | head
```

---

## 4. Rollback

```bash
helm history redis -n database
helm rollback redis <REVISION> -n database --wait
```

- Switching `architecture` between `standalone` and `replication` **replaces the
  StatefulSet topology**. Cached data is lost; that is usually acceptable for a cache but
  **not** if Redis is used as a rate-limit or session store — plan for cold-start load.
- A password change requires a restart of every consumer that cached the old credential.

---

## 5. Monitoring & alerting

| Signal | Metric |
|---|---|
| Availability | `redis_up` |
| Memory pressure | `redis_memory_used_bytes / redis_memory_max_bytes` > 0.85 |
| Evictions | `rate(redis_evicted_keys_total[5m])` — a sudden rise means undersized cache |
| Hit rate | `redis_keyspace_hits_total / (hits + misses)` |
| Replication (prod) | `redis_connected_slaves`, `redis_master_link_up` |
| Blocked clients | `redis_blocked_clients` |

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `NOAUTH Authentication required` | Consumer missing `REDIS_PASSWORD` — check the app's SOPS secret matches `secrets.redis.password`. |
| `OOM command not allowed when used memory > maxmemory` | Raise `maxmemory` in `files/redis.conf` or set an eviction policy (`allkeys-lru`). |
| Failover storms (prod) | Sentinel quorum too tight or network latency; check `down-after-milliseconds`. |
| Master switched, app still writes to the old one | App not Sentinel-aware — point it at the Sentinel service or restart it. |
| Pod `Pending` | PVC/StorageClass, same as any StatefulSet here. |

---

## 7. Notes

- Kong's `rate-limit-default` plugin uses `policy: local`. For accurate cluster-wide
  rate limiting across multiple Kong replicas, switch that plugin to `policy: redis` and
  point it at this release (`releases/platform/kong/manifests/plugins.yaml`).
- Persistence is enabled, but treat Redis as a **cache**: every consumer must tolerate a
  cold Redis. Do not make it the system of record.
