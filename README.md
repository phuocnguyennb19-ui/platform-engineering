# Platform

One repository for the AWS platform: infrastructure (Terraform), Kubernetes delivery (Helm,
Helmfile, Argo CD), observability and CI/CD.

**New here? Read [`docs/00-start-here.md`](docs/00-start-here.md) first** (10 minutes), then follow
the numbered pages in [`docs/`](docs/README.md).

```text
.
├── README.md · CODEOWNERS · Makefile · .gitlab-ci.yml · .sops.yaml
├── docs/                   START HERE — numbered reading order, cluster guides, ADRs, generated reference
├── applications/           VALUES of each app (app teams): <app>/k8s/<env>/values.yaml + terraform/; _template/
├── environments/           VALUES of the base, one COMPLETE folder per environment
│   └── <dev|staging|prod>/
│       ├── kubernetes/     state.yaml · cluster/ · namespace/ · network/ · ingress|tools|monitoring/<tool>/
│       │                   · app-values.yaml.gotmpl · secrets.enc.yaml
│       └── terraform/      environment.yaml · core.yaml · backend.yaml (Terraform name of prod: production)
├── terraform/              TEMPLATES (AWS): modules/ → stacks/ (core → registry → service), shared/, schema/, tests/
├── kubernetes/             TEMPLATES (Kubernetes): charts/application/, releases/{platform,observability}/<tool>/,
│                           argocd/, helmfile.yaml.gotmpl (install order), repositories.yaml, docs/
├── ci/                     pipeline parts, deploy-template for app repos, CI images, runner
├── scripts/                tooling: cluster/ (read-only preflight), deploy/ (release guard), docs/ (generators)
└── helmfile.yaml.gotmpl    app entry point: `helmfile -e <env> -l name=<app> diff|sync`
```

**Templates** say *how* things are built; **values** say *what* each environment or app gets. Changing a
template reaches everything that uses it; changing a value reaches one environment or one app
([ADR 0001](docs/adr/0001-template-value-split.md)).

## I want to…

| I want to… | Go to |
|---|---|
| understand the repo | [`docs/00-start-here.md`](docs/00-start-here.md) |
| set up my machine / a local cluster | [`docs/02-local-setup.md`](docs/02-local-setup.md) |
| add a new application | `make new-app APP=<name> RUNTIME=eks\|ecs` → [`docs/10-onboard-app.md`](docs/10-onboard-app.md) |
| change an app's config in one environment | `applications/<app>/k8s/<env>/values.yaml` |
| change a platform tool (sizing, retention…) in one environment | `environments/<env>/kubernetes/{tools,ingress,monitoring}/<tool>/` |
| change a tool's chart or version | `kubernetes/releases/platform/<tool>/helmfile.yaml.gotmpl` or `kubernetes/releases/observability/<tool>/helmfile.yaml.gotmpl` |
| change AWS (VPC, EKS, IAM…) for an environment | `environments/<env>/terraform/` → [`terraform/README.md`](terraform/README.md) |
| deploy / roll back | [`docs/20-runbooks/platform.md`](docs/20-runbooks/platform.md), [`kubernetes/docs/DEPLOY.md`](kubernetes/docs/DEPLOY.md) |
| know which CI job runs and which gate applies | [`ci/README.md`](ci/README.md) |
| know why the repo is laid out like this | [`docs/adr/`](docs/adr/README.md) |

```bash
make help        # every target
make validate    # chart matrix, app renders, SOPS shape, cluster metadata, terraform fmt — no cloud access
```

Environment names differ by part: Terraform uses `dev | staging | production`, Helm uses
`dev | staging | prod`. Never pass one where the other is expected.
