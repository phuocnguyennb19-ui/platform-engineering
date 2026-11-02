# KEDA — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/keda/`](../../../../environments/dev/kubernetes/tools/keda/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Event-driven autoscaling on top of HPA: scales workloads `0↔N` from Kafka lag, PromQL
queries, Redis depth, cron, SQS, etc. App teams create `ScaledObject` / `ScaledJob` CRs in
their own namespaces.

| | |
|---|---|
| Chart | `kedacore/keda` |
| Version | `2.17.0` |
| Release / Namespace | `keda` / `keda` (created by the release) |
| Selector | `-l name=keda` |
| Labels | `layer=platform, tier=infra, component=autoscaling` |
| Values | `values.yaml.gotmpl` |
| Needs | `observability/kube-prometheus-stack` |

---

## 1. Prerequisites

| Requirement | Why |
|---|---|
| `kube-prometheus-stack` | ServiceMonitor CRD + the Prometheus scaler endpoint |
| `metrics-server` | KEDA drives an HPA underneath; CPU/memory triggers still need it |
| Kafka reachable (`kafka`) | for the Kafka lag scaler used by `be-notification` |
| Namespace `keda` PSA labels | created by `environments/<env>/kubernetes/namespace/namespaces.yaml` |

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f releases/platform/keda/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/keda/helmfile.yaml.gotmpl sync
```

Ships three components: operator, metrics-apiserver (serves `external.metrics.k8s.io`),
and admission webhooks. Prod runs 2 replicas of operator + metrics server with PDBs and
pod anti-affinity.

---

## 3. Verify

```bash
kubectl -n keda get pods
kubectl -n keda rollout status deploy/keda-operator --timeout=180s

# The external metrics APIService must be Available — this is the usual failure point
kubectl get apiservice v1beta1.external.metrics.k8s.io \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'

kubectl get crd | grep keda.sh
kubectl get scaledobject -A
```

For a workload using KEDA, the truth is in the generated HPA:

```bash
kubectl -n dev get hpa            # keda-hpa-<scaledobject-name>
kubectl -n dev describe scaledobject be-notification-worker
```

---

## 4. Rollback

```bash
helm history keda -n keda
helm rollback keda <REVISION> -n keda --wait
```

While KEDA is down, the HPAs it generated remain but stop receiving external metrics —
workloads hold their current replica count. Scaled-to-zero workloads **stay at zero**;
scale them manually if the outage is long:

```bash
kubectl -n dev scale deploy be-notification-worker --replicas=2
```

---

## 5. Monitoring & alerting

| Signal | Metric |
|---|---|
| Operator up | `up{job=~"keda.*"}` |
| Trigger errors | `keda_scaler_errors_total` — alert on any sustained increase |
| Scaler latency | `keda_scaler_detail_errors_total`, `keda_internal_scale_loop_latency` |
| Effective scaling | `keda_scaler_metrics_value` vs the HPA target |
| APIService health | `kube_apiservice_status_condition{apiservice="v1beta1.external.metrics.k8s.io"}` |

`keda_scaler_errors_total` rising means the trigger source (Kafka/Prometheus/Redis) is
unreachable — the workload silently stops scaling.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| HPA shows `<unknown>` for the external metric | metrics-apiserver not Ready, or the APIService is not `Available`. |
| `error parsing Kafka metadata` | Wrong bootstrap servers / SASL auth in the `TriggerAuthentication`. Kafka here uses SASL — see `releases/platform/kafka/README.md`. |
| ScaledObject `Ready=False` | `kubectl describe scaledobject <name>` — the condition message names the failing trigger. |
| Workload never scales to zero | `minReplicaCount` > 0, or another HPA also targets the same Deployment. |
| Conflict: "the HPA is already owned" | The workload has both `autoscaling.enabled` and `keda.enabled` — they are mutually exclusive in `charts/application`. |

---

## 7. Notes

- Trigger credentials belong in a `TriggerAuthentication` owned by the app namespace, not
  in this release's values.
- KEDA only decides *replica counts*. Node capacity still comes from Karpenter — a
  ScaledObject that scales to 50 pods with no room simply produces pending pods.
- Prefer the Prometheus scaler for latency/RPS-based scaling so the scaling signal matches
  the SLO you alert on.
