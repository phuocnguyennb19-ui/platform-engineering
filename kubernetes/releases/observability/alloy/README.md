# Alloy — Deploy

> **Values live in [`environments/<env>/kubernetes/monitoring/alloy/`](../../../../environments/dev/kubernetes/monitoring/alloy/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Node-level **log shipper** (DaemonSet). Discovers pods, tails `/var/log/pods`, relabels
Kubernetes metadata into Loki labels, and pushes to Loki. Replaces Promtail.

| | |
|---|---|
| Chart | `grafana/alloy` |
| Version | `1.11.0` |
| Release / Namespace | `alloy` / `observability` |
| Selector | `-l name=alloy` |
| Labels | `layer=platform, tier=infra, component=logs` |
| Values | `values.yaml.gotmpl` (River pipeline inline in `alloy.configMap.content`) |
| Needs | `loki` |
| Controller | DaemonSet, `tolerations: [{operator: Exists}]` — runs on every node incl. tainted/control-plane |

---

## 1. Prerequisites

- **Loki Ready** (declared `needs`) — the write endpoint is
  `http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push`.
- The `observability` namespace is PSA `privileged` (it hosts hostPath/hostNetwork
  workloads) — Alloy mounts `/var/log` via `alloy.mounts.varlog: true`.
- Node OS must write container logs under `/var/log/pods` (standard on containerd/CRI-O).

Application OTLP telemetry does **not** go through Alloy — that is the OpenTelemetry
Collector's job. Alloy is specifically the node log shipper.

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f ../kubernetes/releases/observability/alloy/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f ../kubernetes/releases/observability/alloy/helmfile.yaml.gotmpl sync
```

Because it is a DaemonSet, a sync rolls one pod per node — on a large cluster expect the
rollout to take a while and watch for log gaps during the restart.

---

## 3. Verify

```bash
kubectl -n observability rollout status daemonset/alloy --timeout=300s
kubectl -n observability get ds alloy      # DESIRED must equal READY (one per node)

kubectl -n observability logs -l app.kubernetes.io/name=alloy --tail=30 | grep -iE 'error|loki'

# Alloy's own UI shows every pipeline component's health
kubectl -n observability port-forward ds/alloy 12345:12345 &
open http://localhost:12345/graph
```

End-to-end — logs must be queryable in Loki:

```bash
kubectl -n observability port-forward svc/loki-gateway 3100:80 &
curl -sG 'localhost:3100/loki/api/v1/query' \
  --data-urlencode 'query={namespace="dev"}' | jq '.data.result | length'
```

---

## 4. Rollback

```bash
helm history alloy -n observability
helm rollback alloy <REVISION> -n observability --wait
```

Alloy tracks read positions on disk. A rollback or restart resumes roughly where it left
off, but logs rotated away while it was down are gone. There is no backfill — keep restarts
short and staged.

---

## 5. Monitoring & alerting

| Signal | Metric |
|---|---|
| Pods running everywhere | `kube_daemonset_status_number_unavailable{daemonset="alloy"}` > 0 |
| Send failures | `rate(loki_write_dropped_entries_total[5m])` |
| Batch/retry pressure | `loki_write_batch_retries_total` |
| Tail health | `loki_source_file_read_lines_total` flat while pods are logging = stuck tailer |
| Alloy component health | `alloy_component_evaluation_seconds` / component `unhealthy` count |

Alert on **dropped entries** and on any node missing an Alloy pod — a single unscheduled
DaemonSet pod means that node's logs vanish silently.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No logs in Loki at all | Loki not Ready, or the push URL/tenant is wrong. Check Alloy logs for `429`/`connection refused`. |
| `429 Too Many Requests` | Loki per-tenant ingestion limits too low — raise them in `kubernetes/releases/observability/loki/values/config.yaml.gotmpl`, don't silence Alloy. |
| Logs from some nodes missing | Alloy pod not scheduled there (taint not tolerated / node pressure). `kubectl get pods -o wide -l app.kubernetes.io/name=alloy`. |
| Labels missing or wrong | The `discovery.relabel` rules in `values.yaml.gotmpl` — that is where namespace/pod/container labels are mapped. |
| Huge Loki cardinality | A relabel rule promoted a high-cardinality field (pod name suffix, request id) to a label. Fix the rule. |
| PSA denies the pod | `observability` namespace must be `privileged`; re-apply `environments/<env>/kubernetes/namespace/namespaces.yaml`. |

---

## 7. Notes

- The River pipeline lives inline in `values.yaml.gotmpl`. Treat it as code: review relabel
  changes carefully, since they directly determine Loki's cardinality and cost.
- Alloy can also scrape metrics and receive OTLP. Keep it single-purpose here — the
  collector owns app telemetry, Alloy owns node logs.
