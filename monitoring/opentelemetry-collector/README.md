# OpenTelemetry Collector — Deploy

> **Values live in [`infra-base/k8s/monitoring/opentelemetry-collector/`](../../infra-base/k8s/monitoring/opentelemetry-collector/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Single OTLP ingest point for application telemetry. Apps send OTLP to it; it enriches every
signal with Kubernetes metadata and fans out: **traces → Tempo, metrics → Prometheus
(scraped on :8889), logs → Loki**.

| | |
|---|---|
| Chart | `open-telemetry/opentelemetry-collector` |
| Version | `0.165.0` |
| Release / Namespace | `opentelemetry-collector` / `observability` |
| Selector | `-l name=opentelemetry-collector` |
| Labels | `layer=platform, tier=infra, component=traces` |
| Values | `values.yaml.gotmpl` |
| Needs | `tempo`, `loki` |
| Endpoint | `opentelemetry-collector.observability.svc.cluster.local:4317` (gRPC) / `:4318` (HTTP) |

| Env | Replicas | HPA | Memory limiter |
|---|---|---|---|
| dev | 1 | off | 400 MiB |
| staging | 2 | off | 900 MiB |
| prod | 2 | 2→6 @70% CPU | 1800 MiB + PDB |

---

## 1. Prerequisites

- **Tempo and Loki Ready** — both are declared `needs`; the collector's exporters fail
  fast otherwise.
- `kube-prometheus-stack` for the ServiceMonitor CRD (Prometheus scrapes `:8889`).
- The **contrib** image is required (`otel/opentelemetry-collector-contrib`) for the
  `k8sattributes` processor and the extra exporters. Do not swap it for the core image.

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f ../monitoring/opentelemetry-collector/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f ../monitoring/opentelemetry-collector/helmfile.yaml.gotmpl sync

# on a fresh cluster, pull Tempo + Loki along
helmfile -e $ENV -f ../monitoring/opentelemetry-collector/helmfile.yaml.gotmpl sync --include-needs
```

App-side configuration is already wired in the app values, e.g.
`OTEL_EXPORTER_OTLP_ENDPOINT: http://opentelemetry-collector.observability.svc.cluster.local:4317`
(`apps/be-payment/config.yaml`, `be-user`, `be-notification`).

---

## 3. Verify

```bash
kubectl -n observability rollout status deploy/opentelemetry-collector --timeout=300s
kubectl -n observability logs deploy/opentelemetry-collector --tail=50 | grep -iE 'error|refused|exporter'

# send a synthetic span through the OTLP HTTP receiver
kubectl -n observability port-forward svc/opentelemetry-collector 4318:4318 &
curl -s -X POST localhost:4318/v1/traces -H 'Content-Type: application/json' -d '{
  "resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoke-test"}}]},
  "scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174",
  "name":"smoke","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000"}]}]}]}'
```

Then search `service.name="smoke-test"` in Grafana → Tempo. Pipeline counters:

```promql
otelcol_receiver_accepted_spans
otelcol_exporter_sent_spans
otelcol_exporter_send_failed_spans     # must stay flat
```

---

## 4. Rollback

```bash
helm history opentelemetry-collector -n observability
helm rollback opentelemetry-collector <REVISION> -n observability --wait
```

The collector is stateless — rollback is cheap and safe. Telemetry produced while it is
down is **lost**, not queued, so keep the window short. Apps do not fail when the collector
is unavailable (OTLP export errors are non-fatal), but you go blind.

---

## 5. Monitoring & alerting

| Signal | Metric |
|---|---|
| Dropped by backpressure | `otelcol_processor_refused_spans`, `otelcol_processor_dropped_spans` |
| Export failures | `otelcol_exporter_send_failed_spans` / `_metric_points` / `_log_records` |
| Queue saturation | `otelcol_exporter_queue_size` vs `otelcol_exporter_queue_capacity` |
| Memory limiter kicking in | `otelcol_processor_refused_spans` rising with stable input |
| Restarts | container restart count — usually OOM |

Alert on `send_failed_*` and on `queue_size` approaching capacity; both mean telemetry is
being dropped while everything still looks "healthy".

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| App logs `connection refused :4317` | Collector not Ready, or the app targets the wrong namespace/port. |
| Spans accepted but nothing in Tempo | Exporter endpoint wrong, or Tempo's OTLP receiver disabled. Check `otelcol_exporter_send_failed_spans`. |
| OOMKilled loop | `memory_limiter` above the container limit. Keep the limiter ~80% of the pod memory limit. |
| Missing k8s attributes on spans | `k8sattributes` processor needs RBAC to list pods — verify the ClusterRole was installed and you are on the contrib image. |
| Logs missing in Loki but traces fine | Loki OTLP endpoint path (`/otlp`) or tenant header misconfigured. |
| High cardinality alerts from span metrics | Tempo's metrics-generator + collector both emitting — pick one source. |

---

## 7. Notes

- One ingest point on purpose: apps never talk to Tempo/Loki/Prometheus directly, so
  backend changes stay invisible to services.
- Sampling belongs here (tail sampling) or in the SDK — not in Tempo. Decide before trace
  volume becomes a cost problem.
- Scaling: prod uses an HPA on CPU **and** memory; the memory limiter is the safety net,
  not the scaling signal.
