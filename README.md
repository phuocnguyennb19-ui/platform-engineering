# Platform

One repository for the AWS platform: infrastructure (Terraform), Kubernetes delivery (Helm,
Helmfile, Argo CD), observability rules and CI/CD.

```text
.
├── .gitlab-ci.yml          root pipeline — includes ci/k8s/*.yml and ci/terraform/*.yml
├── infra-base/             VALUES of the base the applications run on (no templates)
│   ├── terraform/environments/<env>/   environment.yaml · core.yaml · backend.yaml
│   └── k8s/
│       ├── env-values/                 per-environment state, app defaults, SOPS secrets
│       ├── platform/<tool>/            values.yaml.gotmpl + <env>/values.yaml.gotmpl (+ files/)
│       └── monitoring/<tool>/          same, for observability (+ prometheus-rules/)
├── terraform/              TEMPLATES: modules/ → stacks/ (core → registry → service), schema/, tests/
├── k8s/                    TEMPLATES: charts/application/, platform/<tool>/helmfile (chart + version), helmfile order
├── monitoring/             TEMPLATES: <tool>/helmfile for kube-prometheus-stack, grafana, loki, tempo, mimir, alloy, otel
├── applications/<app>/     VALUES of one app: terraform/ (ECR repo / ECS service) + k8s/ (per environment)
├── argocd/                 Argo CD only: App-of-Apps root, AppProject, ApplicationSet
├── local/                  laptop cluster: `helmfile -e local`
├── ci/                     pipeline parts, deploy-template for app repos, CI images, runner
├── docs/                   start here: base infra + outputs, app onboarding, value references, app templates
└── Makefile                offline validation, `make new-app`, `make app-render`, `make docs-reference`
```

Templates and values are kept apart: `infra-base/` and `applications/` hold values only, mapped into the
templates in `terraform/`, `k8s/` and `monitoring/` ([`infra-base/README.md`](infra-base/README.md)).

**Start with [`docs/README.md`](docs/README.md)** — what the base provides and outputs, how to
add an application, and every value you can set (chart and ECS).

| Part | Guide |
|---|---|
| Applications: onboarding, base outputs, value reference | `docs/README.md` |
| Terraform stacks and configuration | `terraform/README.md`, `terraform/CLAUDE.md` |
| Terraform modules | `terraform/MODULES.md`, `terraform/modules/CLAUDE.md` |
| Kubernetes | `k8s/README.md`, `k8s/docs/`, `k8s/CLAUDE.md` |
| GitOps (Argo CD) | `argocd/README.md` |
| Monitoring | `monitoring/<tool>/README.md` |
| CI/CD jobs and gates | `ci/README.md` |

```bash
make help        # every target
make validate    # chart matrix, app renders, SOPS shape, terraform fmt — no cloud access
```

Environment names differ by part: Terraform uses `dev | staging | production`, Helm uses
`dev | staging | prod`.
