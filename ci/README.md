# CI/CD index

| | |
|---|---|
| **What it holds** | Pipeline parts (`kubernetes/`, `terraform/`), `deploy-template.gitlab-ci.yml` (included by app repos), CI images, runner config. |
| **Owner** | platform team + security team (gates) |
| **How to change** | keep every gate (manual prod, protected refs, scans, signatures, pins); a deploy-template change reaches every app repo on its next pipeline |
| **Validate** | pipeline lint in an MR; `make validate` for what the jobs check |

One pipeline: the root `.gitlab-ci.yml` holds `workflow:`, `stages:`, `variables:` and `default:`,
and includes the part files below. Every job `cd`s into its part (`kubernetes/` or `terraform/`) before
it runs; artifact paths stay repository-relative.

| Layer | Terraform modules | Terraform stacks | Kubernetes (Helm) |
|---|---|---|---|
| **L1 validate** | `modules:fmt`, `modules:typed-inputs-only`, `modules:validate`, `modules:contract-tests` | `check-inputs`, `config`, `validate` | `chart:lint`, `chart:render:<env>`, `helmfile:lint:<env>`, `argocd:validate`, `security:{gitleaks,sops-encrypted,hadolint}`, `k8s-env:{schema,test}` |
| **L2 build / plan** | — | `plan:core`, `plan:registry`, `promote:image` → `plan:service` | `chart:package` → `chart:scan` → `chart:publish`, `image:*`, `helmfile:diff:<env>`, `argocd:diff` |
| **L3 apply / deploy** | — (stacks source `../../modules/<name>` directly) | `apply:core`, `apply:registry`, `apply:service` | `deploy:setup` → `deploy:apply` → `deploy:rollback`, `helmfile:sync:<env>`, `argocd:bootstrap:<env>` |

## Files

| File | Purpose |
|---|---|
| `.gitlab-ci.yml` | `workflow:` sets `PIPELINE_PART`; stages, variables, `default:` (k8s image + OIDC token) |
| `ci/terraform/modules.yml` | module checks on MR, default branch and tags; no deploy |
| `ci/terraform/platform.yml` | config validation, plan → apply of the three stacks, image promotion |
| `ci/k8s/main.yml` | tool images (`ci/images/`), chart lint/render/scan/publish, triggered app deploy + rollback; `k8s-env:*` offline checks of `environments/<env>/kubernetes/cluster/` + `scripts/cluster/` (no OIDC token) |
| `ci/k8s/helmfile.yml` | platform tools (`-l layer=platform`) by branch |
| `ci/k8s/argocd.yml` | App-of-Apps validate, diff, bootstrap |
| `ci/deploy-template.gitlab-ci.yml` | template that application repos include by `project:` — build, scan, promote, migrate, deploy |
| `ci/terraform/requirements.{in,txt}` | hash-pinned validators for the `config` job |

## Which part runs

| Pipeline source | `PIPELINE_PART` | Runs |
|---|---|---|
| `trigger` (deploy-template `deploy:<env>`) | `k8s` | `deploy:*` only, and only on a protected ref; terraform jobs also refuse `trigger` |
| `pipeline` (ECS app `trigger: project:`) | `terraform` | terraform stack jobs only; k8s and module jobs also refuse `pipeline` |
| `web` with `SERVICE_NAME` or `BUILD_IMAGES=true` | `k8s` | `deploy:*` on a protected ref; `image:*` on the protected default branch |
| `web` otherwise | `terraform` | terraform stack jobs only |
| push, merge request, tag | `all` | each part's jobs, filtered by its own `changes:` (`kubernetes/**`, `kubernetes/releases/observability/**`, `kubernetes/argocd/**`, `applications/**`, `terraform/**`, `ci/terraform/**`, …) |

## Gates (what triggers L3, and what waits for a human)

| Job | dev | staging | prod / production |
|---|---|---|---|
| `apply:core` | manual | manual | manual |
| `apply:registry` | automatic on push (refuses deletions), else manual | manual | manual |
| `apply:service` | automatic | manual | manual |
| `deploy:apply` (trigger, protected ref only) | automatic | automatic | **manual** |
| `helmfile:sync:<env>` | push to `dev`/`develop` | push to `staging` | `main`/`master`, **manual** |
| `argocd:bootstrap:<env>` | manual | manual | manual |
| app repos via `deploy-template` | push to `dev`/`develop`/`feature/*` | push to `staging`/`release/*` | `main`/`master`, **manual** |

Terraform applies run only on the default branch (`main`). A merge or push to a branch in the
automatic column is a deployment. Treat it at that environment's risk level (`../CLAUDE.md`).

Source guards (`ci/k8s/main.yml`):

- `.k8s-push-mr-only` — `helmfile:*`, `argocd:*` and `chart:*` run only in push and merge-request
  pipelines. `changes:` is always true for trigger, web, api and schedule sources, so it is not a guard.
- `.k8s-protected-ref` — `deploy:setup`, `deploy:apply` and `deploy:rollback` need
  `CI_COMMIT_REF_PROTECTED == "true"` (the deploy-template triggers `ref=main`).
- `deploy:*` accepts only a `SERVICE_NAME` with an `applications/<name>/k8s` folder, and selects
  `layer=app,name=<name>`. Known blocker: `kubernetes/` holds no `layer=app` release, so `deploy:setup`
  fails with an explicit error. The app tier is delivered by Argo CD
  (`kubernetes/argocd/bootstrap/applicationset-apps.yaml`).

These are pipeline rules. What they protect also depends on GitLab settings outside this
repository: protected branches, protected variables (deploy roles, `SOPS_AGE_PRIVATE_KEY_*`,
`HELM_TRIGGER_TOKEN`), and OIDC trust conditions on `ref_protected`.

## Tool images

`image:deploy-tools`, `image:ci` and `image:runner` publish only from the protected default
branch (push with a `ci/images/` change, or a web run with `BUILD_IMAGES=true`). A release tag
that already exists is never overwritten, so a Dockerfile change needs a bump of
`DEPLOY_TOOLS_VERSION` / `CI_IMAGE_VERSION` / `RUNNER_VERSION`. Each job keeps
`image-digests/<name>.txt` (`<image>@sha256:…`) as an artifact.

Not enforced from this repository. These still need to be done and checked in GitLab:

1. Pin consumers by digest: `DEPLOY_TOOLS_IMAGE` and `CI_IMAGE` in `.gitlab-ci.yml` and the group
   variables that application repos read, set to the `@sha256:` value from `image-digests/`.
2. Protected container tags (or registry push restricted to Maintainers) for `deploy-tools`, `ci`
   and `runner`. Any job's `CI_JOB_TOKEN` can push to this project's registry, so the pipeline
   rules alone do not stop an overwrite.
3. Verify: from a merge-request pipeline, a push of `deploy-tools:<existing tag>` is refused.

## Runners

`ci/runner/config.toml` is the build runner. Its job containers mount the host Docker socket,
which is root on that host. `ci/runner/config.deploy.toml` is a template for a protected deploy
runner on a separate host, with no socket, `--access-level ref_protected` and tag
`deploy-protected`. Deploy jobs do not need a Docker daemon: `.ecr-login` logs in to the chart
registry with helm only.

No job carries runner tags yet. Adding them before the runner exists leaves those jobs pending.
Cutover order:

1. Provision a separate host. Register it with `config.deploy.toml`. Run `gitlab-runner verify`.
2. In one merge request, add `tags: [deploy-protected]` to `deploy:*`, `helmfile:sync:*`,
   `argocd:bootstrap:*` and the terraform `plan:*` / `apply:*` / `promote:image` jobs. Run it
   once in dev.
3. Register the build runner (`config.toml`) with `--access-level not_protected`. Give it its
   own tag for `image:*` and the application repos' `build:image`. Move protected image builds
   to a separate protected build host if MR jobs share the socket host.
4. Confirm that no protected job ran on the socket host, using the runner's job history.

BuildKit rootless or kaniko would remove the socket from build jobs too. They are not evaluated
for compatibility here.
