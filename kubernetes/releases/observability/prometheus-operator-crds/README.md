# prometheus-operator-crds — Deploy

> **Values live in [`environments/<env>/kubernetes/monitoring/prometheus-operator-crds/`](../../../../environments/dev/kubernetes/monitoring/prometheus-operator-crds/)**
> (only `crds.annotations`). This folder keeps the release (`helmfile.yaml.gotmpl`) and this runbook.

The `monitoring.coreos.com` CRDs — `ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Probe`,
`Prometheus`, `Alertmanager`, `AlertmanagerConfig`, `PrometheusAgent`, `ScrapeConfig`,
`ThanosRuler` — and nothing else. **First in the deploy order.**

| | |
|---|---|
| Chart | `prometheus-community/prometheus-operator-crds` |
| Version | `30.0.1` = operator `v0.92.1` = kube-prometheus-stack `87.19.1` — bump together |
| Release / Namespace | `prometheus-operator-crds` / `kube-system` (CRDs are cluster-scoped; the namespace only holds the release) |
| Selector | `-l name=prometheus-operator-crds` |
| Labels | `layer=platform, tier=infra, component=metrics` |
| Secrets | none — renders without the SOPS age key |
| Blast radius | **Cluster-wide.** Every ServiceMonitor / PrometheusRule depends on these CRDs. |

Why a separate release, not kube-prometheus-stack's `crds.enabled: true`:

- ~19 tools (and apps with `serviceMonitor.enabled`) render a `ServiceMonitor`. With the CRDs in
  their own small release, any of those tools can be synced alone, without the monitoring stack.
- helm never upgrades CRDs from a chart's `crds/` directory (kube-prometheus-stack ships them
  there); this chart has them in `templates/`, so a version bump upgrades them.
- `helm.sh/resource-policy: keep` (values): an uninstall leaves the CRDs, and with them every
  ServiceMonitor / PrometheusRule in the cluster.

## Deploy

```bash
T=kubernetes/releases/observability/prometheus-operator-crds/helmfile.yaml.gotmpl   # from the repo root
helmfile -e <env> --kube-context <ctx> -f $T diff
helmfile -e <env> --kube-context <ctx> -f $T sync
kubectl --context=<ctx> get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
```

## Existing cluster whose CRDs came from kube-prometheus-stack

CRDs installed from a chart's `crds/` directory carry no helm ownership, so the first sync of this
release stops with `invalid ownership metadata`. Adopt them once **[CHANGES STATE]**, then sync:

```bash
for c in $(kubectl --context=<ctx> get crd -o name | grep monitoring.coreos.com); do
  kubectl --context=<ctx> label "$c" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl --context=<ctx> annotate "$c" meta.helm.sh/release-name=prometheus-operator-crds \
    meta.helm.sh/release-namespace=kube-system --overwrite
done
```

Nothing is deleted: kube-prometheus-stack with `crds.enabled: false` never removes CRDs it
installed from `crds/`.
