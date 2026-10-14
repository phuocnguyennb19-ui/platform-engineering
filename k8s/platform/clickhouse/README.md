# ClickHouse — Deploy

> **Values live in [`infra-base/k8s/platform/clickhouse/`](../../../infra-base/k8s/platform/clickhouse/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

OLAP / analytics columnar store, coordinated by ClickHouse Keeper (Raft, no ZooKeeper).

| | |
|---|---|
| Chart | `bitnami/clickhouse` |
| Version | `9.4.4` |
| Release / Namespace | `clickhouse` / `database` |
| Selector | `-l name=clickhouse` |
| Labels | `layer=platform, tier=infra, component=analytics` |
| Values | `values.yaml.gotmpl` + `files/config.d/custom.xml` |
| Secrets | `.Values.secrets.clickhouse.password` (user `admin`) |

| Env | Shards | Replicas | Keeper nodes | Storage |
|---|---|---|---|---|
| dev | 1 | 1 | 1 | 10Gi |
| staging | 1 | 1 | 1 | 20Gi |
| prod | 2 | 2 | 3 | 100Gi |

---

## 1. Prerequisites

- `database` namespace applied; SOPS key `secrets.clickhouse.password` present.
- Bitnami mirror decision for prod (see `platform/postgresql/README.md`).
- prod: at least 3 nodes so the Keeper ensemble can tolerate one failure.
- ClickHouse is memory-hungry — prod requests 4Gi and limits 8Gi per pod. Confirm the
  node pool can host `shards × replicas` of that.

---

## 2. Configuration map

| Where | Owns |
|---|---|
| `files/config.d/custom.xml` | logging, profiles, quotas, Prometheus endpoint (read via `readFile` → `extraOverrides`) |
| `values.yaml.gotmpl` | shards/replicas, Keeper, sizing, persistence |
| SOPS | admin password → Secret `clickhouse` (`existingSecret`) |

---

## 3. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f platform/clickhouse/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/clickhouse/helmfile.yaml.gotmpl sync
```

---

## 4. Verify

```bash
kubectl -n database get pods -l app.kubernetes.io/name=clickhouse
kubectl -n database rollout status statefulset/clickhouse-shard0 --timeout=600s

PASS=$(kubectl -n database get secret clickhouse -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl -n database exec -it clickhouse-shard0-0 -- \
  clickhouse-client --user admin --password "$PASS" --query "SELECT version()"

# cluster topology as ClickHouse sees it
kubectl -n database exec -it clickhouse-shard0-0 -- \
  clickhouse-client --user admin --password "$PASS" \
  --query "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters"

# Keeper health (prod)
kubectl -n database exec -it clickhouse-keeper-0 -- \
  bash -c 'echo mntr | nc localhost 9181 | grep -E "zk_server_state|zk_followers"'
```

Expect exactly one `leader` and the rest `follower` in the Keeper ensemble.

---

## 5. Rollback

```bash
helm history clickhouse -n database
helm rollback clickhouse <REVISION> -n database --wait --timeout 15m
```

⚠ **Shard count changes are not reversible by Helm.** Reducing `shards` orphans the data
on the removed shard — it is not redistributed. Re-shard by creating new tables and
`INSERT SELECT`-ing across, then dropping the old ones.

Backups: use `BACKUP TABLE ... TO S3(...)` against MinIO, or Velero PV snapshots. Test the
restore before you rely on it.

---

## 6. Monitoring & alerting

The Prometheus endpoint is enabled in `files/config.d/custom.xml`.

| Signal | Metric |
|---|---|
| Availability | `ClickHouseMetrics_Query` scrape success |
| Replication delay | `ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay` > 60s |
| Read-only replicas | `ClickHouseMetrics_ReadonlyReplica` > 0 (Keeper unreachable) |
| Merge backlog | `ClickHouseMetrics_BackgroundMergesAndMutationsPoolTask` |
| Rejected inserts | `ClickHouseProfileEvents_RejectedInserts` — too many small parts |
| Disk | PVC used % > 80 |

`ReadonlyReplica > 0` almost always means Keeper is down — check the ensemble first.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Replica stuck read-only | Keeper quorum lost. Restore the ensemble; ClickHouse recovers on its own. |
| `TOO_MANY_PARTS` on insert | Client inserting too frequently in small batches — batch inserts (≥10k rows) or raise `parts_to_throw_insert` deliberately. |
| OOMKilled during a query | `max_memory_usage` unset per-profile; set quotas in `custom.xml` rather than growing the pod forever. |
| Auth failure | `secrets.clickhouse.password` changed after the volume was initialised — reset the user in-database. |
| Pod `Pending` in prod | Not enough nodes/memory for `shards × replicas`. |

---

## 8. Notes

- Coordination uses ClickHouse Keeper, not ZooKeeper — do not deploy a separate ZK.
- For multi-tenant analytics at scale, the **Altinity operator** manages sharding,
  upgrades and backups far better than a plain chart.
- Keep quotas and profiles in `custom.xml` under git; ad-hoc `SET` statements in the client
  are not reproducible.
