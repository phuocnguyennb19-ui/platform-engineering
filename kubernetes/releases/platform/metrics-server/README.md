# metrics-server — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/metrics-server/`](../../../../environments/dev/kubernetes/tools/metrics-server/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Implements the Kubernetes **resource metrics API** (`metrics.k8s.io`). Without it
`kubectl top` returns nothing and **every HPA in the cluster stops scaling** —
including the app-tier HPAs in `charts/application`.

| | |
|---|---|
| Chart | `metrics-server/metrics-server` |
| Version | `3.13.1` |
| Release / Namespace | `metrics-server` / `kube-system` |
| Selector | `-l name=metrics-server` |
| Labels | `layer=platform, tier=infra, component=metrics` |
| Values | `values.yaml.gotmpl` |
| Needs | `observability/kube-prometheus-stack` (intra-domain `needs`) |

---

## 1. Prerequisites

- `kube-prometheus-stack` deployed (declared as `needs`, so `--include-needs` can pull it).
- Kubelet serving certificates must be verifiable by the cluster CA. On kubeadm /
  on-prem clusters with self-signed kubelet certs, uncomment `--kubelet-insecure-tls`
  in `values.yaml.gotmpl` **before** the first sync.

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f releases/platform/metrics-server/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/metrics-server/helmfile.yaml.gotmpl sync

# with its dependency, on a fresh cluster
helmfile -e $ENV -f releases/platform/metrics-server/helmfile.yaml.gotmpl sync --include-needs
```

Sizing: 1 replica in dev/staging, 2 + PDB (`minAvailable: 1`) in prod.

---

## 3. Verify

```bash
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s

# The APIService must report Available=True
kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'

# Real data flowing
kubectl top nodes
kubectl top pods -A | head
```

Metrics take ~60s after startup to appear. `kubectl top` returning
`metrics not available yet` immediately after sync is normal.

---

## 4. Rollback

```bash
helm history metrics-server -n kube-system
helm rollback metrics-server <REVISION> -n kube-system --wait
```

Impact while rolled back / down: HPAs freeze at their current replica count (they do
not scale to zero), and `kubectl top` fails. No workload traffic impact.

---

## 5. Monitoring

`serviceMonitor.enabled: true` — scraped by Prometheus.

| Check | Query |
|---|---|
| Up | `up{job="metrics-server"}` |
| Scrape errors from kubelets | `metrics_server_kubelet_request_total{success="false"}` |
| HPA starvation | `kube_horizontalpodautoscaler_status_condition{condition="ScalingActive",status="false"}` |

Alert on `ScalingActive=false` — that is the symptom users actually feel.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `x509: certificate signed by unknown authority` in logs | Kubelet serving cert not signed by cluster CA → enable `--kubelet-insecure-tls` (non-prod) or fix kubelet serving certs (prod, preferred). |
| APIService `Available=False`, `FailedDiscoveryCheck` | Network policy or aggregation layer blocking the API server → metrics-server:443. Check `environments/<env>/kubernetes/network/` — note `kube-system` has no policy today, so look for a policy added elsewhere. |
| `unable to fully scrape metrics from node` | Node unreachable on `InternalIP` — verify `--kubelet-preferred-address-types` order matches your infra. |
| HPA shows `<unknown>/80%` | metrics-server not Ready, or the workload has no resource `requests` defined. |

---

## 7. Notes

- Do **not** use metrics-server as a monitoring source — it keeps only a short in-memory
  window. Historical resource usage comes from Prometheus/Mimir.
- Event-driven scaling (Kafka lag, PromQL, cron) is KEDA's job, not metrics-server's —
  see `releases/platform/keda/README.md`.
