# Mimir — Deploy

> **Values live in [`infra-base/k8s/monitoring/mimir/`](../../infra-base/k8s/monitoring/mimir/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Long-term, horizontally scalable Prometheus storage. `kube-prometheus-stack` remote-writes
here for durable, de-duplicated, long-retention metrics.

> ⚠ **Not yet queryable from Grafana.** `monitoring/grafana/values/datasources.yaml.gotmpl`
> currently defines Prometheus, Loki, Tempo and OpenSearch — **no Mimir datasource**.
> Data is being written but nobody reads it. Add a `prometheus`-type datasource pointing at
> the Mimir query frontend (with the `X-Scope-OrgID` header) to close the loop.

| | |
|---|---|
| Chart | `grafana/mimir-distributed` |
| Version | `5.7.0` |
| Release / Namespace | `mimir` / `observability` |
| Selector | `-l name=mimir` |
| Labels | `layer=platform, tier=infra, component=metrics` |
| Values | `values.yaml.gotmpl` (topology) + `config.yaml.gotmpl` (`structuredConfig`) |
| **Hard dependency** | `minio` — Mimir has no local storage mode here |

| Env | deploymentMode | Replicas | Storage |
|---|---|---|---|
| dev | `monolithic` | 1 | 10Gi |
| staging | `monolithic` | 1 | 20Gi |
| prod | `distributed` | 3 per component | 50Gi + MinIO blocks |

---

## 1. Prerequisites

| Requirement | Why |
|---|---|
| **MinIO synced first** | buckets `mimir-blocks`, `mimir-ruler`, `mimir-alerts` + user `mimir` |
| `secrets.minio.mimirSecretKey` | injected as `AWS_SECRET_ACCESS_KEY` (`AWS_ACCESS_KEY_ID=mimir`) |
| `kube-prometheus-stack` | the remote-write source and the ServiceMonitor CRD |
| StorageClass | ingester/store-gateway PVCs |

The root helmfile include order (`data/` before `observability/`) is what guarantees MinIO
exists — there is no cross-domain `needs`. If you sync only `observability/`, check MinIO
yourself.

---

## 2. Configuration map

| File | Owns |
|---|---|
| `values.yaml.gotmpl` | deployment mode, replicas, resources, gateway, S3 env injection |
| `config.yaml.gotmpl` | `mimir.structuredConfig`: limits, `blocks_storage`, ruler |

`mimir.structuredConfig` is deliberately empty in `values.yaml.gotmpl` so the two files
never fight over the same key.

---

## 3. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f ../monitoring/mimir/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f ../monitoring/mimir/helmfile.yaml.gotmpl sync
```

---

## 4. Verify

```bash
kubectl -n observability get pods -l app.kubernetes.io/name=mimir

kubectl -n observability port-forward svc/mimir-nginx 8080:80 &
curl -s localhost:8080/ready

# Is Prometheus actually writing here?
curl -s -H 'X-Scope-OrgID: anonymous' \
  'localhost:8080/prometheus/api/v1/query?query=up' | jq '.data.result | length'
```

Also verify the *source* side — remote-write health on Prometheus:

```promql
rate(prometheus_remote_storage_samples_failed_total[5m])   # must stay 0
prometheus_remote_storage_samples_pending
```

---

## 5. Rollback

```bash
helm history mimir -n observability
helm rollback mimir <REVISION> -n observability --wait --timeout 15m
```

- `monolithic` ↔ `distributed` is a **topology change**, not an upgrade: pod names, PVCs
  and the ring membership all change. Historical blocks in MinIO survive (they are the
  source of truth); in-memory/unflushed series in the ingesters do not. Flush first where
  possible and expect a short ingestion gap.
- Reducing ingester replicas in `distributed` mode risks losing unflushed data — scale
  down one at a time and wait for the ring to rebalance.

---

## 6. Monitoring & alerting

| Signal | Metric |
|---|---|
| Write path | `rate(cortex_distributor_ingester_append_failures_total[5m])` |
| Ingester ring health | `cortex_ring_members{state!="ACTIVE"}` |
| Object store errors | `rate(thanos_objstore_bucket_operation_failures_total[5m])` |
| Compactor progress | `cortex_compactor_last_successful_run_timestamp_seconds` staleness > 6h |
| Per-tenant limits | `cortex_discarded_samples_total` — silent data loss |
| Query latency | `cortex_request_duration_seconds` p99 on the query path |

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Mimir pods `CrashLoopBackOff` at startup | MinIO unreachable or buckets missing — sync `minio` first. |
| `AccessDenied` on the bucket | `secrets.minio.mimirSecretKey` does not match the MinIO `mimir` user; both come from the same SOPS key, so re-sync both releases. |
| Prometheus `remote_storage_samples_failed_total` climbing | Mimir rejecting writes: per-tenant limits, or the distributor is down. Check `cortex_discarded_samples_total` reasons. |
| Grafana shows no historical metrics | There is no Mimir datasource yet (see the note at the top). Once added, a missing `X-Scope-OrgID` header is the next thing to check. |
| Compactor never runs | Not enough blocks yet (normal on a new install) or the compactor pod is starved of memory. |

---

## 8. Notes

- Why remote_write instead of Prometheus federation: one global query view, per-tenant
  limits, compaction, and retention decoupled from the local TSDB.
- Local Prometheus retention stays deliberately short — do **not** treat Prometheus as the
  archive; Mimir is.
- Multi-tenancy: if you enable real tenants, every client (Grafana, ruler, remote-write)
  must send a matching `X-Scope-OrgID`.
