# kubernetes

| | |
|---|---|
| **What it holds** | Kubernetes templates: `charts/application/` (chart of every app), `releases/{platform,observability}/<tool>/` (one helmfile per tool: chart + version), `helmfile.yaml.gotmpl` (install order), `repositories.yaml`, `argocd/`, `docs/`. No values. |
| **Owner** | platform team |
| **How to change** | tool values in `environments/<env>/kubernetes/`; app values in `applications/`; a chart change reaches every app — render the whole matrix |
| **Validate** | chart: `helm lint charts/application -f charts/application/ci/<case>-values.yaml` · one tool: `helmfile -e <env> -f releases/<group>/<tool>/helmfile.yaml.gotmpl template` (needs that env's age key) |

Step-by-step deploy (namespace → platform → app, verify, rollback):
**[docs/20-runbooks/kubernetes-manual.md](../docs/20-runbooks/kubernetes-manual.md)**.
How values are layered: [docs/03-values-mapping.md](../docs/03-values-mapping.md).
Per-tool detail: [docs/DEPLOY.md](docs/DEPLOY.md) and each `releases/<group>/<tool>/README.md`.

---

## Prerequisites

### Local

| Tool | Version (as in CI, `ci/images/Dockerfile`) |
|---|---|
| helm | 3.20.1 |
| helmfile | 1.4.2 |
| helm-diff plugin | 3.15.10 |
| helm-secrets plugin | 4.7.7 |
| sops | 3.13.3 |
| kubectl | 1.34.1 (at most one minor away from the cluster) |

### CI/CD

GitLab Runner jobs use the pre-built `deploy-tools` image ([`../ci/images/Dockerfile`](../ci/images/Dockerfile)),
so no job installs tools at runtime. Jobs and gates: [`../ci/README.md`](../ci/README.md).

---

## Layout

A folder's role is read off its `layer` label. Paths are relative to the repository root.

```
kubernetes/                       # TEMPLATES only — values live in environments/<env>/kubernetes/
├── helmfile.yaml.gotmpl          # platform install order: includes every release folder (ORDER = DEPLOY ORDER)
├── repositories.yaml             # chart repos + helmDefaults (bases: of every helmfile state)
├── charts/application/           # in-house chart of every app (values.schema.json, ci/ values matrix)
├── releases/
│   ├── platform/<tool>/          # one helm release (layer=platform): helmfile.yaml.gotmpl + README.md (+ manifests/)
│   │   ├── metrics-server/  karpenter/  cluster-autoscaler/  reloader/  keda/
│   │   ├── minio/  postgresql/  redis/  kafka/  clickhouse/  opensearch/  opensearch-dashboards/
│   │   ├── cert-manager/  ingress-nginx/  kong/  external-dns/
│   │   ├── vault/  external-secrets/  sealed-secrets/  kyverno/  trivy-operator/  falco/
│   │   ├── argocd/  velero/  harbor/
│   │   └── gateway-api/          # kubectl-only: Gateway API CRDs + the Gateway object
│   └── observability/<tool>/     # kube-prometheus-stack (FIRST: CRDs), loki, tempo, mimir,
│                                 # opentelemetry-collector, alloy, grafana
├── argocd/                       # Argo CD App-of-Apps — the OTHER possible owner of the app tier
│   ├── root-app.yaml
│   └── bootstrap/                # AppProject + ApplicationSet
└── docs/                         # DEPLOY · NAMESPACES · NETWORK-POLICIES · TROUBLESHOOTING

environments/<env>/kubernetes/    # VALUES of one environment: state.yaml, cluster/, namespace/, network/,
                                  # tools|ingress|monitoring/<tool>/ (+ files/), app-values.yaml.gotmpl, secrets.enc.yaml
applications/<app>/k8s/<env>/     # VALUES of one app (read by applications/helmfile.yaml.gotmpl and Argo CD)
ci/k8s/                           # main.yml (chart + deploy) · helmfile.yml · argocd.yml
```

Inside a tool folder:

| Path | Role |
|---|---|
| `helmfile.yaml.gotmpl` | the release: chart, version, namespace, labels, values list |
| `manifests/` | raw k8s manifests — `kubectl apply`, **never** rendered by helm |
| `README.md` | the runbook for that one component |

Its values are `environments/<env>/kubernetes/{tools,ingress,monitoring}/<tool>/values.yaml.gotmpl`
(+ `files/` read with `readFile`).

> Every folder is its own **helmfile state**, so `needs` cannot cross a folder
> boundary. The include order in `helmfile.yaml.gotmpl` **is** the deploy
> order — reordering that list changes what installs first. `kube-prometheus-stack`
> must stay at the top: it ships the ServiceMonitor/PrometheusRule CRDs that nearly
> every other tool's values reference.
>
> No release here pins a kube context: always pass `--kube-context <ctx>`.
> One tool: `helmfile -e <env> --kube-context <ctx> -f kubernetes/releases/<group>/<tool>/helmfile.yaml.gotmpl diff|sync`.
> Whole layer: `helmfile -e <env> --kube-context <ctx> -f kubernetes/helmfile.yaml.gotmpl -l layer=platform diff|sync`.
> Apps are **not** here — from the repo root: `helmfile -e <env> -l name=<app> diff|sync`.

## The application chart

Every EKS app renders `charts/application`. Every key, its default and what it does:
[`../docs/reference/application-chart.md`](../docs/reference/application-chart.md) (generated from
`values.yaml` / `values.schema.json`). Test matrix: `charts/application/ci/*-values.yaml`
([`charts/application/ci/README.md`](charts/application/ci/README.md)). Upgrade notes:
[`charts/application/UPGRADING.md`](charts/application/UPGRADING.md).
