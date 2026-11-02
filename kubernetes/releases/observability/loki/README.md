# Loki — Deploy

> **Values live in [`environments/<env>/kubernetes/monitoring/loki/`](../../../../environments/dev/kubernetes/monitoring/loki/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Log aggregation backend. Alloy ships node logs into it; Grafana queries it with LogQL and
uses `derivedFields` to jump from a log line straight to the Tempo trace.

| | |
|---|---|
| Chart | `grafana/loki` |
| Version | `7.1.0` |
| Release / Namespace | `loki` / `observability` |
| Selector | `-l name=loki` |
| Labels | `layer=platform, tier=infra, component=logs` |
| Values | `values.yaml.gotmpl` (topology) + `config.yaml.gotmpl` (server config) |
| Depends on | `kube-prometheus-stack` (CRDs), `minio` (prod object store) |

| Env | Deployment mode | Replicas | Storage |
|---|---|---|---|
| dev | `SingleBinary` | 1 | 20Gi filesystem PVC |
| staging | `SingleBinary` | 1 | 50Gi filesystem PVC |
| prod | `SimpleScalable` | 2 read / 2 write / 2 backend | S3 (MinIO bucket `loki-chunks`) |

---

## 1. Prerequisites

| Requirement | Why |
|---|---|
| `kube-prometheus-stack` synced | ServiceMonitor CRD |
| **MinIO synced (prod)** | `loki-chunks`, `loki-ruler`, `loki-admin` buckets + the `loki` user |
| SOPS key `secrets.minio.lokiSecretKey` | S3 credentials for the `loki` MinIO user |
| StorageClass | dev/staging PVCs |

Deploying prod Loki before MinIO produces a write path that fails on every push.

---

## 2. Configuration map

| File | Owns |
|---|---|
| `values.yaml.gotmpl` | deployment mode, replicas, persistence, gateway, sizing |
| `config.yaml.gotmpl` | schema config, limits, compactor, storage backend, ruler |

Keep them separate — topology changes and retention/limits changes have very different
review risk.

---

## 3. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f ../kubernetes/releases/observability/loki/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f ../kubernetes/releases/observability/loki/helmfile.yaml.gotmpl sync
```

Loki is first in the observability domain: `alloy`, `opentelemetry-collector` and
`grafana` all declare `needs: [loki]`.

---

## 4. Verify

```bash
kubectl -n observability get pods -l app.kubernetes.io/name=loki

# readiness through the gateway (the endpoint everything else uses)
kubectl -n observability port-forward svc/loki-gateway 3100:80 &
curl -s localhost:3100/ready
curl -s 'localhost:3100/loki/api/v1/labels' | jq .

# is anything actually arriving?
curl -sG 'localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={namespace="observability"}' | jq '.data.result | length'
```

Then confirm end-to-end in Grafana → Explore → Loki datasource. An empty label list means
Alloy is not shipping (see `kubernetes/releases/observability/alloy/README.md`).

---

## 5. Rollback

```bash
helm history loki -n observability
helm rollback loki <REVISION> -n observability --wait --timeout 10m
```

⚠ **Changing `deploymentMode` between `SingleBinary` and `SimpleScalable` is a topology
replacement, not an upgrade.** Filesystem-backed chunks from SingleBinary are *not*
readable by a SimpleScalable deployment pointed at S3 — old logs become unreachable even
though the PVC still exists. Plan that change as a migration with a retention overlap.

Rolling back a **schema_config** change is worse: entries written under the new schema
become unreadable. Schema changes must be additive with a `from:` date in the future.

---

## 6. Monitoring & alerting

| Signal | Metric |
|---|---|
| Ingestion errors | `rate(loki_request_duration_seconds_count{status_code=~"5.."}[5m])` |
| Rate-limit drops | `rate(loki_discarded_samples_total[5m])` — the usual cause of "missing logs" |
| Object store failures | `rate(loki_boltdb_shipper_request_duration_seconds_count{status_code!~"2.."}[5m])` |
| Compactor health | `loki_boltdb_shipper_compact_tables_operation_last_successful_run_timestamp_seconds` staleness |
| Query latency | `histogram_quantile(0.99, loki_request_duration_seconds_bucket{route=~"loki_api_v1_query.*"})` |

Alert on `loki_discarded_samples_total` — silent per-tenant limit drops are the most common
way logs go missing without anything looking broken.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Grafana Loki datasource: `no such host loki-gateway` | Release not synced, or Grafana points at the wrong namespace — check `kubernetes/releases/observability/grafana/values/datasources.yaml.gotmpl`. |
| Writes fail with `AccessDenied` (prod) | `secrets.minio.lokiSecretKey` differs from the key MinIO provisioned. Re-sync both releases. |
| `429 Too Many Requests` from Alloy | Per-tenant ingestion limits in `config.yaml.gotmpl` too low for the log volume. |
| Queries time out over long ranges | SingleBinary mode at scale — move to SimpleScalable, or narrow the query. |
| Disk fills in dev | Filesystem storage with no compaction pressure; lower retention. |
| Falco alerts missing from Loki | Falco output path not wired — see `releases/platform/falco/README.md`. |

---

## 8. Notes

- The write endpoint used by Alloy is
  `http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push`.
- Cardinality discipline matters more than sizing: never put request IDs, user IDs or
  pod-generated suffixes into Loki **labels** — keep them in the log line.
- prod runs on MinIO rather than a cloud bucket so the whole stack stays portable; swap
  the S3 endpoint in `config.yaml.gotmpl` if you move to native S3.
