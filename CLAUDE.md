# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Layering.** `~/Dylan/.claude/CLAUDE.md` is the global policy: security, permissions,
environment gates (§1–§2), risk levels (§12), destructive operations (§3), secrets (§5), git
safety (§17), approval (§21). This file covers the platform's three parts — **Terraform,
Kubernetes (Helm), CI/CD** — each by layer, the end-to-end flow that joins them (§4), plus the
rules that cross them. Implementation rules live in each part's `CLAUDE.md`
(`terraform/CLAUDE.md`, `terraform/modules/CLAUDE.md`, `k8s/CLAUDE.md`). Where a lower layer seems
to allow what a higher one gates, the higher one wins.

```text
.                      one git repository
├── .gitlab-ci.yml     root pipeline: workflow (PIPELINE_PART), stages, variables, includes
├── ci/                pipeline parts, deploy-template, CI images and runner
│   ├── k8s/           main.yml · helmfile.yml · argocd.yml
│   ├── terraform/     modules.yml · platform.yml · requirements.*
│   ├── deploy-template.gitlab-ci.yml   included by application repos
│   ├── images/        deploy-tools · ci · runner Dockerfiles
│   └── runner/
├── infra-base/        VALUES of the base (no templates), mapped into terraform/, k8s/, monitoring/:
│   ├── terraform/environments/<env>/{environment,core,backend}.yaml
│   └── k8s/
│       ├── env-values/           environments.yaml · repositories.yaml · app-values.yaml.gotmpl
│       │                         <env>/{app-values.yaml.gotmpl, secrets.enc.yaml} · onprem-<env>/app-values.yaml.gotmpl
│       ├── platform/<tool>/      values.yaml.gotmpl (every env) + <env>/values.yaml.gotmpl + files/
│       └── monitoring/<tool>/    same per observability release; prometheus-rules/
├── terraform/         TEMPLATES
│   ├── modules/       L1 reusable modules (typed inputs, contract tests)
│   ├── examples/      module examples
│   ├── schema/        JSON schemas for infra-base/terraform/environments/ and applications/*/terraform/
│   ├── stacks/        L2 roots: core → registry → service
│   ├── shared/        stack-internal modules (config, deep-merge)
│   └── tests/
├── k8s/               TEMPLATES
│   ├── charts/application/   L1 chart
│   ├── platform/<tool>/      L2 platform tools: helmfile.yaml.gotmpl (chart, version, labels) — values in infra-base;
│   │                         bootstrap/, gateway-api/, network-policies/ (kubectl manifests)
│   ├── apps/<app>/           L3 helmfile-owned apps (layer=app) — none today
│   └── helmfile.yaml.gotmpl  deploy order (includes ../monitoring/<tool>)
├── applications/<app>/  everything one application owns, split by tool:
│   ├── terraform/     app.yaml, <env>.yaml — ECR repository (EKS) or ECS service, read by terraform/stacks
│   └── k8s/           values.yaml + <env>/values.yaml (dev, staging, prod, local) — Helm values,
│                      read by Argo CD and local/ (EKS only); example: applications/frontend-html
├── argocd/            Argo CD only: root-app.yaml, bootstrap/ (AppProject, ApplicationSet)
├── local/             laptop cluster, `helmfile -e local` (pinned kube context): helmfile.yaml.gotmpl order,
│                      defaults.yaml.gotmpl, values/ env layer, platform/ (CRDs, namespace),
│                      apps/helmfile.yaml.gotmpl (a release for every applications/<app>/k8s/local/, -l name=<app>)
├── monitoring/        TEMPLATES: observability releases (kube-prometheus-stack, grafana, loki, tempo,
│                      mimir, alloy, opentelemetry-collector) — values in infra-base/k8s/monitoring/
└── Makefile           offline validation for every part
```

Commands for a part run from that part's directory (`cd k8s`, `cd terraform`); CI does the same.

## 1. Terraform

```text
L1 terraform/modules ──relative path──► L2 terraform/stacks ──► AWS
```

| Layer | Path | Owns | Never |
|---|---|---|---|
| **L1 module** | `terraform/modules/<name>/` | typed inputs, contract tests | YAML, environment names, state |
| **L2 stacks** | `terraform/stacks/`, `../infra-base/terraform/environments/`, `../applications/*/terraform/`, `schema/`, `shared/` | YAML config, roots `core/` → `registry/` → `service/`, state, environment policy | a reusable module |

- Two layers, never a third. Stacks source modules as `../../modules/<name>` — there are no
  release tags or `?ref=` pins: **a module change reaches every stack and every environment on
  its next plan**. Classify a module change by the highest environment it reaches.
- ECS applications are YAML in `applications/<app>/terraform/`, deployed by `stacks/service`.
- Stack order is `core` → `registry` → `service`. `core` is shared by every app and by Helm.
- State keys are `<env>/core/core.tfstate`, `<env>/registry/registry.tfstate`,
  `<env>/services/<app>.tfstate` — independent of directory names.

## 2. Kubernetes (Helm)

```text
L1 k8s/charts/application ──► L2 k8s/platform/<tool> (layer=platform) ──► L3 apps (layer=app)
```

| Layer | Path | Owns |
|---|---|---|
| **L1 chart** | `k8s/charts/application/` | the in-house chart every EKS app uses; `values.schema.json`, `ci/*-values.yaml` matrix |
| **L2 platform** | `k8s/platform/<tool>/`; `bootstrap/`, `gateway-api/`, `network-policies/` (kubectl-only) | cluster tools, in the `k8s/helmfile.yaml.gotmpl` order |
| **L2 monitoring** | `monitoring/<tool>/` (`layer: platform`), values `infra-base/k8s/monitoring/<tool>/`, rules `infra-base/k8s/monitoring/prometheus-rules/` | observability releases, same helmfile order and env-values |
| **L3 apps** | `k8s/apps/<app>/` (Helmfile) or `applications/<app>/k8s/` (Argo CD with `APP_TIER_OWNER=argocd`) | EKS application releases |
| shared | `infra-base/k8s/env-values/` | env values, chart repos + `helmDefaults`, SOPS secrets |

- A folder's layer is its `layer` label. Deploy order is the `helmfiles:` list in
  `k8s/helmfile.yaml.gotmpl`, which also lists `../monitoring/<tool>`; `needs:` cannot cross
  folders. `argocd/` holds only Argo CD manifests, `applications/<app>/k8s/` the app values; the chart it renders is
  `k8s/charts/application`.
- Helm needs Terraform `core` first: `infra-base/k8s/env-values/environments.yaml` mirrors `platformName`
  and `eksClusterName`, and IRSA ARNs are built as `<eksClusterName>-irsa-<addon>`. Renaming
  either in `infra-base/terraform/environments/` breaks Helm.
- Guide: `k8s/CLAUDE.md`, `k8s/README.md`, `k8s/docs/`.

## 3. CI/CD

One pipeline, `.gitlab-ci.yml`, including `ci/k8s/*.yml` and `ci/terraform/*.yml`.
`ci/README.md` maps every job by part and lists every gate.

| Layer | Terraform | Helm |
|---|---|---|
| **L1 validate** | `modules:*` fmt/validate/test, `config` schema, `validate` | chart lint/render matrix, helmfile lint, gitleaks, SOPS check |
| **L2 build / plan** | `plan:*` saves `tfplan`; `promote:image` | chart package/scan/sign/publish; `helmfile diff`; `argocd:diff` |
| **L3 apply / deploy** | `apply:*` applies exactly the saved plan | `deploy:apply`, `helmfile:sync:<env>`, `argocd:bootstrap:<env>`; `deploy:rollback` |

- `PIPELINE_PART` (root `workflow:`) keeps the two trigger contracts apart: `trigger` pipelines
  and web runs with `SERVICE_NAME`/`BUILD_IMAGES` run only k8s jobs; `pipeline` (ECS trigger) and
  other web runs only terraform jobs; push/MR/tag run both, each filtered by its `changes:`.
- **A merge is a deploy** where L3 runs on push. Classify a merge at the risk level of the
  environment it reaches.
- Keep every gate: `when: manual` on prod, `resource_group`, protected variables and refs, OIDC
  role split, input validation, `REPLACE_WITH_` guard, gitleaks, SOPS check, trivy
  `--exit-code 1`, cosign, digest/version pins, `DESTROY_GUARD`.
- `ci/deploy-template.gitlab-ci.yml` is included by application repos by `project:`: a change
  there reaches every app repo on its next pipeline.

## 4. Platform architecture — end-to-end deployment flow

### Base infrastructure and application are separate layers

Before touching an application, establish what the platform already provides, then what the
application consumes, then what it creates itself. An application is a consumer of the base,
never its own infrastructure stack.

| Layer | In this platform | Path |
|---|---|---|
| **Base infrastructure** | `stacks/core` (VPC, EKS, ECS cluster, SGs, IRSA, ALB/DNS/ACM when enabled), `stacks/registry` (ECR per `image.repository`) | `terraform/` |
| **Platform** | L2 tools (`layer: platform`: ingress-nginx, external-dns, cert-manager, ESO, Kyverno…), `bootstrap/` namespaces + PSA, `network-policies/`; observability releases | `k8s/platform/`, `monitoring/` |
| **Base chart / shared defaults** | `charts/application` (L1), `infra-base/k8s/env-values/app-values.yaml.gotmpl` + `infra-base/k8s/env-values/<env>/app-values.yaml.gotmpl` | `k8s/` |
| **Shared CI** | `ci/deploy-template.gitlab-ci.yml` (app repos include it), `deploy:*` jobs, `promote:image` / `plan:service` / `apply:service` | `ci/` |
| **Application** | `applications/<app>/terraform/` (ECS service or EKS ECR), `k8s/apps/<app>/` or `applications/<app>/k8s/`, the app repo's `.gitlab-ci.yml` and `Dockerfile` | app team |

For every application trace: base resource → shared platform resource/default → application
config → deployment → runtime. Report an application that recreates something the base
already provides (IAM, ServiceAccount, ingress controller, LB, SG, NetworkPolicy, monitoring)
as **Base Infrastructure Duplication** with location, existing base resource, duplicate,
impact and evidence. Do not remove it unasked.

### The flow, as implemented

Mechanism only — job and file names drift, so verify them (Runtime discovery) before relying
on them.

```text
EKS  push to app repo → deploy-template (include: project) : scan → build:image → test:unit
     → promote:<env> (crane, by digest) → migrate:<env> → deploy:<env> trigger (curl, ref=main)
     → this repo, PIPELINE_PART=k8s : deploy:setup → deploy:apply : cd k8s; helmfile -e <DEPLOY_ENV> sync -l name=<SERVICE_NAME>
     → charts/application release in ns <DEPLOY_ENV> on platform-<env>-eks
     → Ingress (class nginx-<env>) → ingress-nginx Service type LoadBalancer (NLB) → external-dns

ECS  push to app repo → build + push to dev ECR → trigger this repo (APP_NAME, ENVIRONMENT, IMAGE_TAG)
     → PIPELINE_PART=terraform : check-inputs · config · validate → promote:image → plan:service → apply:service
     → ECS service <name_prefix>-<environment>-<app> on <name_prefix>-<environment>-ecs
     → ALB listener rule + Route53 record only when core alb/dns are enabled
```

| Variable | Source | Transformation | Consumer | Runtime effect |
|---|---|---|---|---|
| `SERVICE_NAME` | deploy-template, default `$CI_PROJECT_NAME` | validated `^[a-z0-9][a-z0-9-]{0,52}$` in `ci/k8s/main.yml` | `helmfile -l name=`, ECR path, `resource_group` | release `<svc>`, objects `<svc>-application` (chart fullname), ECR repo `<svc>` |
| `DEPLOY_ENV` | the `deploy:<env>` / `promote:<env>` job | `.env-select` → account ID, `EKS_CLUSTER` | `helmfile -e`, OIDC role `gitlab-deploy-<env>` | namespace, `infra-base/k8s/env-values/<env>` + `infra-base/k8s/*/<tool>/<env>/`, cluster |
| `IMAGE_TAG` | `$CI_COMMIT_SHORT_SHA` (build:image dotenv) | — | app values `env "IMAGE_TAG"`; `TF_VAR_image_tag` | image `<global.imageRegistry>/<repo>:<tag>` |
| `APP_NAME` | trigger variable | — | `applications/<app>/terraform/`, `STATE_KEY` | ECS service name, state `<env>/services/<app>.tfstate` |
| `ENVIRONMENT` | trigger variable, default `dev` | — | `infra-base/terraform/environments/<env>/`, `TF_VAR_environment` | account, backend, tag source (`pipeline` vs pinned `config`) |
| `PIPELINE_PART` | root `workflow:rules` | from `CI_PIPELINE_SOURCE` + `SERVICE_NAME`/`BUILD_IMAGES` | every job's first rule | which part's jobs may run |

Trace each hop from the repository, not from convention:

- **CI** — `workflow:rules`, `include` → file → `extends` → job; anchors (`<<:`/`*ref`) do not
  cross files, `!reference` does — state whether `script` is inherited, overridden or merged.
  For each job: stage, rules (auto / manual / never), variables, needs, artifacts, runner tags,
  `environment`, `resource_group`, working directory (`cd k8s` / `cd terraform`).
- **Build / image** — Dockerfile, context, build args, registry, tag, and whether staging/prod
  get the same digest (promotion) or a rebuild.
- **Environment / name mapping** — git ref → env → variables → values → namespace → cluster;
  every `sed`/`envsubst`/template transformation as input → output → consumer.
- **Base consumption** — Terraform outputs (remote state) and `infra-base/k8s/env-values/environments.yaml`
  values each application reads; which `env-values` layer and chart version it renders with.
- **Kubernetes** — objects rendered per release, and scheduling: requests/limits, replicas/HPA,
  PDB, `topologySpreadConstraints`, affinity, taints/tolerations.
- **AWS** — classify each resource as Terraform-managed, controller-managed (ingress-nginx NLB,
  external-dns records) or application-managed.
- **Production coupling** — which templates, scripts and values prod shares with lower
  environments. Document it; do not recommend separation unasked.

### Shared components and their consumers

A change here has the blast radius of all its consumers, not of the file. Find every consumer
before editing, and classify by the highest environment reached.

| Component | Consumers |
|---|---|
| `terraform/modules/<name>` | every stack that sources it, every environment, on the next plan |
| `terraform/stacks/core` outputs | `registry`, `service` (remote state); `infra-base/k8s/env-values/environments.yaml` and IRSA role names mirror them by name |
| `terraform/shared/config` | all three stacks |
| `k8s/charts/application` | every EKS app, Helmfile and Argo paths, every environment |
| `infra-base/k8s/env-values/app-values.yaml.gotmpl`, `infra-base/k8s/env-values/<env>/` | every app release in that scope |
| `infra-base/k8s/platform/<tool>/`, `infra-base/k8s/monitoring/<tool>/` (`values.yaml.gotmpl` = every environment) | that tool in every environment (or the one `<env>/`) |
| `k8s/helmfile.yaml.gotmpl` `helmfiles:` order | every platform tool and app, deploy order |
| `monitoring/prometheus-rules/`, `monitoring/<tool>/` | kube-prometheus-stack / the observability stack in every environment |
| `argocd/bootstrap/` | every Argo-owned app in every cluster that runs the App-of-Apps |
| `ci/deploy-template.gitlab-ci.yml` | every app repo on its next pipeline |
| `.gitlab-ci.yml`, `ci/**` | every job of every part — the root workflow decides what runs |

### Audit evidence and output

- Label every conclusion **FACT** (file + line or command output), **INFERENCE** or **POTENTIAL
  RISK**, and write what was not checked as *Not verified from repository*. These map onto the
  global §7 states; they do not replace them.
- Finding severity: CRITICAL · HIGH · MEDIUM · LOW · INFO, each with component, location, issue,
  impact, evidence, mitigation. Change risk stays on the Risk levels table below.
- A full platform audit returns: executive summary · end-to-end flow with real names · Mermaid
  diagram · pipeline flow table (step, component, config, input, output, consumer) · base
  infrastructure table (component, technology, created by, used by, environment) · application
  dependency table (app, base consumed, CI template, Helm/Helmfile, namespace, cluster) ·
  variable mapping table · resource ownership table (source, tool, resource, name, namespace,
  owner) · risk register · failure points (failure, cause, detection, impact, recovery).
- A change proposal adds Current behavior → Problem → Root cause → Affected components to the
  global Change → Impact → Risk → Rollback → Verification.

## Environment mapping

| | dev | staging | production |
|---|---|---|---|
| App repo branch (deploy-template) | `dev`, `develop`, `feature/*` | `staging`, `release/*` | `main`, `master` — manual |
| Terraform (`ENVIRONMENT`, `infra-base/terraform/environments/`) | `dev` | `staging` | `production` |
| Helm (`-e`, `DEPLOY_ENV`, `infra-base/k8s/env-values/<env>`, namespace) | `dev` | `staging` | `prod` |
| EKS cluster | `platform-dev-eks` | `platform-staging-eks` | `platform-production-eks` |
| Image tag source (`release.image_tag_source`) | pipeline `IMAGE_TAG` | pinned `image.tag` | pinned `image.tag` |

Not interchangeable. Translate at the boundary; never rename either side, never pass
`production` to helmfile or `prod` to Terraform.

## Workflow

Every platform change runs this sequence. Depth scales with risk; no step is skipped and a
request never goes straight to a deploy.

1. **Discover** — branch, `git status`, unrelated uncommitted changes, the files and their
   callers; the base layer the change sits on or is consumed by (§4).
2. **Classify** — part and layer, risk level (below), target environment (global §1).
3. **Impact** — what consumes it: the next layer up, the other part, CI jobs, state addresses;
   for a shared component, every consumer in §4.
4. **Modify** — the minimum change, in the part that owns it.
5. **Validate** — `make validate` and the part's checks in its `CLAUDE.md`, for every affected
   environment.
6. **Plan / diff** — only where the environment gate allows it; otherwise rendered output
   (`template`, `terraform test`) stands in and is labelled as such.
7. **Approval gate** — HIGH/CRITICAL: Change → Impact → Risk → Rollback → Verification, with the
   plan/diff, then wait (global §12, §3).
8. **Deploy** — through the L3 pipeline. A local `helmfile sync` is dev-only and needs the
   context check in `k8s/CLAUDE.md`; Terraform is never applied from here.
9. **Verify** — below. Exit code 0 is not evidence.
10. **Report** — global §19, per part, including what was not verified.

### Risk levels

| Level | Terraform | Helm | CI/CD |
|---|---|---|---|
| **LOW** | docs, `fmt`, offline `validate`/`test` | docs, chart refactor with identical render | docs, comments |
| **MEDIUM** | new optional module input; dev-only `infra-base/terraform/environments/`/`applications/*/terraform/` YAML | `infra-base/k8s/env-values/dev`, dev-only tool values, `charts/application` templates (render the whole matrix) | job changes that keep every gate |
| **HIGH** | `stacks/core`, IAM/IRSA, SG, VPC/route, ALB/DNS/ACM, `production` config, **any `terraform/modules` change that a stack uses**, a major module change | `infra-base/k8s/env-values/prod`, any `infra-base/k8s/*/<tool>/prod/` or shared `<tool>/values.yaml.gotmpl`, NetworkPolicy, RBAC, Kyverno/Falco, `helmfiles:` order, `monitoring/` rules | `deploy-template`, root `workflow:`/`PIPELINE_PART`, branch → environment rules, role ARNs |
| **CRITICAL** | production apply, destroy, state surgery, removing a resource, KMS, `allowed_account_ids` | `helmfile -e prod sync/apply`, `.sops.yaml`, secret files | removing or weakening any gate, scan, signature or pin |

LOW/MEDIUM proceed after validation; execution against an environment still follows global §2
(staging and prod mutations ask). Writing and validating HIGH/CRITICAL locally is allowed;
applying, syncing or merging it is what waits.

### Security-sensitive surfaces

`.sops.yaml`, `infra-base/k8s/env-values/*/secrets.enc.yaml`, `*.agekey`/`keys.txt`/kubeconfig, GitLab CI
variables and their `protected` scope, OIDC roles (`gitlab-deploy-<env>`, `TF_PLAN_ROLE_ARN`,
`TF_APPLY_ROLE_ARN`, `CHART_PUBLISH_ROLE_ARN`), IRSA and EKS access entries, security groups,
NetworkPolicies, Kyverno and Falco policy, `allowed_account_ids`.

- Never decrypt, print or commit a SOPS file or CI variable; check encryption by shape
  (`grep -c '^sops:'`).
- On AccessDenied, report the missing action and principal. Never widen a policy, trust, SG or
  NetworkPolicy to make a run pass.
- Treat as CRITICAL until shown otherwise any diff adding `*` actions, `Principal: "*"`,
  `0.0.0.0/0`, `privileged`, `hostNetwork`, or dropping `allowed_account_ids`.
- In CI, audit as well: runner Docker socket and `sudo`, `eval`/`sed`/`envsubst` on CI
  variables (injection), jobs reachable from unprotected branches or tags that assume a deploy
  role, protected-tag rules, and that `PIPELINE_PART` cannot be set to reach the other part's
  deploy jobs.

## Deploy and verify

Before a deploy, state: environment (in that part's naming), commit, layer and affected
releases/resources, dependency impact, validation result, plan/diff, rollback command, risk
level. Anything missing blocks it.

After it, with bounded reads against the named context:

- Helm: `helm --kube-context=<ctx> status|history`, `kubectl --context=<ctx> rollout status …
  --timeout=…`, pods Ready and restarts, `events` and recent logs, Service endpoints,
  Ingress/Gateway responding; for an L2 tool, its own health signal (targets up, CRDs present).
- Terraform: applied counts match the plan; outputs consumed by the next layer and by Helm
  unchanged unless intended; ECS services stable.

Rollback: Helm `deploy:rollback` or `helm --kube-context=<ctx> rollback <release> <rev>`
(`atomic: false`, nothing rolls back on its own); Terraform reverts the commit and runs plan →
apply again — state is never edited by hand.

## Runtime discovery

At the start of platform work check, rather than trust:

- `git status --short` and branch; leave unrelated changes alone (no reset, restore, stash,
  clean, checkout).
- Every path named by `helmfiles:`, CI `changes:`, module `source`, `STACK_DIR` or a doc exists.
- Environment and cluster names still agree with the table above.
- Secret files are encrypted (shape only); no plaintext secret file is tracked.

Report mismatches as observed inconsistencies. Fix one only when the task needs it.
