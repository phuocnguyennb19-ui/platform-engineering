# kube-prometheus-stack — Deploy

> **Values live in [`infra-base/k8s/monitoring/kube-prometheus-stack/`](../../infra-base/k8s/monitoring/kube-prometheus-stack/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Monitoring engine of the platform: Prometheus Operator, Prometheus server, Alertmanager,
node-exporter and kube-state-metrics. **Deploy this first** — it owns the
`ServiceMonitor` / `PodMonitor` / `PrometheusRule` CRDs that almost every other
release in this repo references.

| | |
|---|---|
| Chart | `prometheus-community/kube-prometheus-stack` |
| Version | `87.19.1` (pinned in `monitoring/kube-prometheus-stack/helmfile.yaml.gotmpl`) |
| Release / Namespace | `kube-prometheus-stack` / `observability` |
| Selector | `-l name=kube-prometheus-stack` |
| Labels | `layer=platform, tier=infra, component=metrics` |
| Values | `values.yaml.gotmpl`, `prometheus.yaml.gotmpl`, `scrape-configs.yaml.gotmpl`, `alertmanager.yaml.gotmpl` |
| Blast radius | **Cluster-wide.** CRD removal breaks every ServiceMonitor in the cluster. |

---

## 1. Prerequisites

| Requirement | Check |
|---|---|
| Namespaces + PSA labels applied | `kubectl get ns observability -o jsonpath='{.metadata.labels}'` |
| `SOPS_AGE_KEY_FILE` exported | `sops -d env-values/$ENV/secrets.enc.yaml \| head -3` |
| StorageClass available (Prometheus/Alertmanager PVCs) | `kubectl get sc` |
| Chart repos cached | `helmfile -e $ENV deps` |

```bash
kubectl apply -f platform/bootstrap/manifests/namespaces.yaml     # ALWAYS first on a new cluster
```

Nothing else must be installed before this release. Grafana is **not** part of it
(`grafana.enabled: false`) — it is a standalone release in `grafana`.

---

## 2. Configuration map

| File | Owns |
|---|---|
| `values.yaml.gotmpl` | CRDs, Operator sizing, exporters, control-plane scrape toggles |
| `prometheus.yaml.gotmpl` | Prometheus server: retention, storage, remote_write → Mimir |
| `scrape-configs.yaml.gotmpl` | additional scrape jobs |
| `alertmanager.yaml.gotmpl` | Alertmanager sizing, storage, routing tree |

Env-specific behaviour worth knowing before you sync:

- **dev**: `prometheusOperator.admissionWebhooks.enabled: false` — the cert-gen hook image
  on `ghcr.io` is unreachable from local clusters. Server-side CR validation is skipped;
  staging/prod keep it on.
- **dev/staging**: `kubeControllerManager` / `kubeScheduler` / `kubeEtcd` scraping is
  disabled because managed control planes (EKS/GKE/AKS) do not expose those endpoints.
  Enable only on self-managed clusters.

---

## 3. Deploy

```bash
export ENV=dev                                     # dev | staging | prod
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# 1. Always diff first — CRD churn shows up here
helmfile -e $ENV -f ../monitoring/kube-prometheus-stack/helmfile.yaml.gotmpl diff

# 2. Sync
helmfile -e $ENV -f ../monitoring/kube-prometheus-stack/helmfile.yaml.gotmpl sync
```

Render-only (no cluster contact) when reviewing a change:

```bash
helmfile -e $ENV -f ../monitoring/kube-prometheus-stack/helmfile.yaml.gotmpl template | less
```

> **Upgrades across chart major versions:** Helm does **not** upgrade CRDs. Apply the
> new CRDs from the chart release before syncing, otherwise the Operator silently runs
> against an old schema:
> ```bash
> kubectl apply --server-side --force-conflicts \
>   -f https://raw.githubusercontent.com/prometheus-community/helm-charts/kube-prometheus-stack-87.19.1/charts/kube-prometheus-stack/charts/crds/crds/
> ```

---

## 4. Verify

```bash
kubectl -n observability rollout status deploy/kube-prometheus-stack-operator --timeout=300s
kubectl -n observability get pods -l app.kubernetes.io/part-of=kube-prometheus-stack

# CRDs the rest of the platform depends on
kubectl get crd | grep -E 'servicemonitors|podmonitors|prometheusrules|alertmanagers'

# Prometheus healthy + all targets up
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s localhost:9090/-/healthy
curl -s localhost:9090/api/v1/targets | jq '[.data.activeTargets[] | select(.health!="up")] | length'
```

Expected: operator `Available`, Prometheus StatefulSet `Ready`, `0` unhealthy targets
(a few are normal right after a fresh install while other releases come up).

---

## 5. Rollback

`helmDefaults` sets `atomic: false` and `cleanupOnFail: false` on purpose — a failed
release is left in place so you can inspect it. **Nothing rolls back automatically.**

```bash
helm history kube-prometheus-stack -n observability
helm rollback kube-prometheus-stack <REVISION> -n observability --wait --timeout 10m
```

`crds.keep` behaviour: the CRDs are **not** deleted by a rollback or an uninstall.
That is intentional — deleting them would cascade-delete every ServiceMonitor and
PrometheusRule object in the cluster.

---

## 6. Monitoring & alerting

| Signal | Where |
|---|---|
| Operator/Prometheus health | Prometheus `up{job=~"kube-prometheus-stack.*"}` |
| Rule evaluation failures | `prometheus_rule_evaluation_failures_total` |
| TSDB pressure | `prometheus_tsdb_head_series`, PVC usage |
| remote_write to Mimir | `prometheus_remote_storage_samples_failed_total` |

Self-monitoring rules (`Watchdog`, `PrometheusDown`, `TargetDown`) ship with the chart.
Confirm the `Watchdog` alert is permanently firing — if it is not, alerting itself is broken.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Other releases fail with `no matches for kind "ServiceMonitor"` | This release was not synced first. Sync it, then retry. |
| Pre-install hook `admission-create` stuck (dev) | ghcr.io unreachable — expected; dev disables the webhook. Verify `$ENV=dev`. |
| Prometheus pod `Pending` | No PVC binding — check `storageClass` in `env-values/environments.yaml` and `kubectl get pvc -n observability`. |
| `TargetDown` for kube-scheduler/controller-manager | Managed control plane. Keep those scrapers disabled outside self-managed prod. |
| OOMKilled Prometheus | Raise limits in `prometheus.yaml.gotmpl` or reduce retention/cardinality. |

---

## 8. Notes / risks

- This release is **first in the dependency chain**; every other domain assumes its CRDs
  exist. The include order in the root `helmfile.yaml.gotmpl` enforces that, not `needs`.
- Long-term metrics live in **Mimir** (`mimir`) via remote_write; local
  Prometheus retention is deliberately short.
- Grafana dashboards are still emitted here (`forceDeployDashboards: true`) for the
  standalone Grafana sidecar to pick up.
