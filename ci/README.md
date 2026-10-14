# CI/CD index

One pipeline: the root `.gitlab-ci.yml` holds `workflow:`, `stages:`, `variables:` and `default:`,
and includes the part files below. Every job `cd`s into its part (`k8s/` or `terraform/`) before
it runs; artifact paths stay repository-relative.

| Layer | Terraform modules | Terraform stacks | Kubernetes (Helm) |
|---|---|---|---|
| **L1 validate** | `modules:fmt`, `modules:typed-inputs-only`, `modules:validate`, `modules:contract-tests` | `check-inputs`, `config`, `validate` | `chart:lint`, `chart:render:<env>`, `helmfile:lint:<env>`, `argocd:validate`, `security:{gitleaks,sops-encrypted,hadolint}` |
| **L2 build / plan** | — | `plan:core`, `plan:registry`, `promote:image` → `plan:service` | `chart:package` → `chart:scan` → `chart:publish`, `image:*`, `helmfile:diff:<env>`, `argocd:diff` |
| **L3 apply / deploy** | — (stacks source `../../modules/<name>` directly) | `apply:core`, `apply:registry`, `apply:service` | `deploy:setup` → `deploy:apply` → `deploy:rollback`, `helmfile:sync:<env>`, `argocd:bootstrap:<env>` |

## Files

| File | Purpose |
|---|---|
| `.gitlab-ci.yml` | `workflow:` sets `PIPELINE_PART`; stages, variables, `default:` (k8s image + OIDC token) |
| `ci/terraform/modules.yml` | module checks on MR, default branch and tags; no deploy |
| `ci/terraform/platform.yml` | config validation, plan → apply of the three stacks, image promotion |
| `ci/k8s/main.yml` | tool images (`ci/images/`), chart lint/render/scan/publish, triggered app deploy + rollback |
| `ci/k8s/helmfile.yml` | platform tools (`-l layer=platform`) by branch |
| `ci/k8s/argocd.yml` | App-of-Apps validate, diff, bootstrap |
| `ci/deploy-template.gitlab-ci.yml` | template that application repos include by `project:` — build, scan, promote, migrate, deploy |
| `ci/terraform/requirements.{in,txt}` | hash-pinned validators for the `config` job |

## Which part runs

| Pipeline source | `PIPELINE_PART` | Runs |
|---|---|---|
| `trigger` (deploy-template `deploy:<env>`) | `k8s` | k8s jobs only; terraform jobs also refuse `trigger` |
| `pipeline` (ECS app `trigger: project:`) | `terraform` | terraform stack jobs only; k8s and module jobs also refuse `pipeline` |
| `web` with `SERVICE_NAME` or `BUILD_IMAGES=true` | `k8s` | k8s jobs only |
| `web` otherwise | `terraform` | terraform stack jobs only |
| push, merge request, tag | `all` | each part's jobs, filtered by its own `changes:` (`k8s/**`, `monitoring/**`, `argocd/**`, `applications/**`, `terraform/**`, `ci/terraform/**`, …) |

## Gates (what triggers L3, and what waits for a human)

| Job | dev | staging | prod / production |
|---|---|---|---|
| `apply:core` | manual | manual | manual |
| `apply:registry` | automatic on push (refuses deletions), else manual | manual | manual |
| `apply:service` | automatic | manual | manual |
| `deploy:apply` (trigger) | automatic | automatic | **manual** |
| `helmfile:sync:<env>` | push to `dev`/`develop` | push to `staging` | `main`/`master`, **manual** |
| `argocd:bootstrap:<env>` | manual | manual | manual |
| app repos via `deploy-template` | push to `dev`/`develop`/`feature/*` | push to `staging`/`release/*` | `main`/`master`, **manual** |

Terraform applies run only on the default branch (`main`). A merge or push to a branch in the
automatic column is a deployment. Treat it at that environment's risk level (`../CLAUDE.md`).
