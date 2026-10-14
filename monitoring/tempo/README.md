# Tempo — Deploy

> **Values live in [`infra-base/k8s/monitoring/tempo/`](../../infra-base/k8s/monitoring/tempo/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Distributed trace storage. Receives OTLP from the OpenTelemetry Collector, serves traces
to Grafana, and generates RED + service-graph metrics from spans (remote-written to
Prometheus).

| | |
|---|---|
| Chart | `grafana/tempo` (single binary) |
| Version | `1.24.4` |
| Release / Namespace | `tempo` / `observability` |
| Selector | `-l name=tempo` |
| Labels | `layer=platform, tier=infra, component=traces` |
| Values | `values.yaml.gotmpl` |
| Endpoint | `tempo.observability.svc.cluster.local:3100` (query), `:4317/:4318` (OTLP in) |

| Env | Storage | Retention |
|---|---|---|
| dev | 10Gi filesystem | 48h |
| staging | 20Gi filesystem | 168h (7d) |
| prod | S3 (`tempo-traces-<env>`) | 336h (14d) |

---

## 1. Prerequisites

- `kube-prometheus-stack` — ServiceMonitor CRD **and** the remote-write receiver used by
  the metrics-generator (`kube-prometheus-stack-prometheus:9090/api/v1/write`).
  Prometheus must have the remote-write receiver enabled, otherwise span metrics are dropped.
- prod: MinIO bucket `tempo-traces` + the `tempo` user (provisioned by `minio`), and
  `secrets.minio.tempoSecretKey`.
- StorageClass for dev/staging PVCs.

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f ../monitoring/tempo/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f ../monitoring/tempo/helmfile.yaml.gotmpl sync
```

`opentelemetry-collector` declares `needs: [tempo, loki]`, so
Tempo must be Ready before the collector starts forwarding.

---

## 3. Verify

```bash
kubectl -n observability rollout status statefulset/tempo --timeout=300s

kubectl -n observability port-forward svc/tempo 3100:3100 &
curl -s localhost:3100/ready
curl -s localhost:3100/api/echo

# is the OTLP receiver listening?
kubectl -n observability get svc tempo -o jsonpath='{.spec.ports[*].name}{"\n"}'   # expect otlp-grpc / otlp-http
```

End-to-end: send a trace through the collector, then search for it in Grafana → Explore →
Tempo. Also confirm span metrics arrived in Prometheus:

```promql
traces_spanmetrics_calls_total
```

---

## 4. Rollback

```bash
helm history tempo -n observability
helm rollback tempo <REVISION> -n observability --wait
```

Switching the backend between `filesystem` and `s3` does **not** migrate existing blocks:
traces written before the switch stay in the old backend and disappear from queries.
Accept the gap, or run both backends during a retention window.

---

## 5. Monitoring & alerting

| Signal | Metric |
|---|---|
| Ingest failures | `rate(tempo_receiver_refused_spans_total[5m])` |
| Storage write errors | `rate(tempo_ingester_blocks_flushed_total[5m])` vs failures |
| Compaction health | `tempodb_compaction_errors_total` |
| Query latency | `tempo_query_frontend_queries_total` / duration buckets |
| Metrics-generator | `tempo_metrics_generator_registry_active_series`, remote-write failures |

Alert on `refused_spans` — it means the collector is producing more than Tempo accepts and
traces are being dropped silently.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Grafana "trace not found" for a known trace ID | Trace older than retention, or written to the previous storage backend. |
| Collector logs `connection refused` to tempo:4317 | Tempo not Ready, or the OTLP receiver disabled in values. |
| No RED metrics in Prometheus | Metrics-generator remote-write URL wrong, or Prometheus started without `--web.enable-remote-write-receiver`. |
| `S3 AccessDenied` (prod) | `secrets.minio.tempoSecretKey` mismatch with the MinIO `tempo` user. |
| Disk fills fast in dev | Retention 48h with high span volume — reduce sampling at the app or collector. |

---

## 7. Notes

- The single-binary chart is fine for small/medium volume. For high trace throughput switch
  to `tempo-distributed`, which splits distributor/ingester/querier.
- Correlation is the point of this release: Loki `derivedFields` → Tempo, and Tempo →
  Loki/Prometheus links are configured in `monitoring/grafana/values/datasources.yaml.gotmpl`.
  Verify the round trip after any change to either release.
- Control cost at the source with head/tail sampling in the collector, not by shrinking
  Tempo's retention to uselessness.
