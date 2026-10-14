# Reloader — Deploy

> **Values live in [`infra-base/k8s/platform/reloader/`](../../../infra-base/k8s/platform/reloader/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Watches ConfigMaps and Secrets and rolls the workloads that consume them. Without it a
config change is written but never picked up until someone manually restarts the
Deployment.

| | |
|---|---|
| Chart | `stakater/reloader` |
| Version | `2.2.14` |
| Release / Namespace | `reloader` / `kube-system` |
| Selector | `-l name=reloader` |
| Labels | `layer=platform, tier=infra, component=platform` |
| Values | `values.yaml.gotmpl` |
| Needs | `observability/kube-prometheus-stack` |

---

## 1. Prerequisites

- `kube-prometheus-stack` (for the ServiceMonitor CRD).
- `watchGlobally: true` — the controller gets cluster-wide read on ConfigMaps/Secrets.
  Confirm that is acceptable for your cluster's RBAC posture before syncing.

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f platform/reloader/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/reloader/helmfile.yaml.gotmpl sync
```

---

## 3. Usage (how workloads opt in)

`reloadStrategy: annotations` — Reloader patches a pod-template annotation, which
triggers a normal rolling update (no pod deletion, PDB and surge settings respected).

```yaml
# opt in to everything this workload mounts
metadata:
  annotations:
    reloader.stakater.com/auto: "true"

# or scope it to specific objects
    configmap.reloader.stakater.com/reload: "be-payment-config"
    secret.reloader.stakater.com/reload: "be-payment"
```

`charts/application` workloads should carry `reloader.stakater.com/auto: "true"` so that
a SOPS/ESO-driven Secret change actually reaches the running pods.

---

## 4. Verify

```bash
kubectl -n kube-system rollout status deploy/reloader-reloader --timeout=120s

# functional test
kubectl -n dev annotate deploy be-user reloader.stakater.com/auto=true --overwrite
kubectl -n dev patch cm be-user-config --type merge -p '{"data":{"CANARY":"1"}}'
kubectl -n dev rollout status deploy/be-user      # should show a new rollout
kubectl -n kube-system logs deploy/reloader-reloader --tail=20 | grep -i changes
```

---

## 5. Rollback

```bash
helm history reloader -n kube-system
helm rollback reloader <REVISION> -n kube-system --wait
```

Impact while down: config changes stop propagating silently — pods keep the old values.
There is no traffic impact, which is exactly why this failure mode goes unnoticed;
alert on it (below).

---

## 6. Monitoring

`serviceMonitor.enabled: true`.

| Signal | Metric |
|---|---|
| Up | `up{job=~".*reloader.*"}` |
| Reloads performed | `reloader_reload_executed_total{success="true"}` |
| Failed reloads | `reloader_reload_executed_total{success="false"}` — alert on any increase |

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Config changed, no rollout | Workload missing the `reloader.stakater.com/auto` annotation, or the ConfigMap is mounted by a name Reloader does not see (e.g. referenced only via `envFrom` in an initContainer). |
| Rollout loops | Something rewrites the ConfigMap continuously (a controller or a `helmfile sync` in a loop). Find the writer before blaming Reloader. |
| RBAC `forbidden` on secrets | `watchGlobally` requires cluster-scoped read; check the ClusterRole was installed. |

---

## 8. Notes

- Reloader restarts workloads. In prod that means the change lands during business hours
  unless you gate it — prefer rolling config changes through the normal deploy pipeline.
- It does not validate config content. A bad ConfigMap will be rolled out just as fast as
  a good one; keep readiness probes strict (`charts/application` sets them per service).
