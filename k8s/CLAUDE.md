# CLAUDE.md — k8s

The platform rules (architecture, environment mapping, workflow, risk levels, deployment and
verification) are in the root `CLAUDE.md`; global policy in `~/Dylan/.claude/CLAUDE.md`.
This file adds what is specific to `k8s/`. `README.md`, `docs/DEPLOY.md`, `docs/APPS.md` and
`platform/<tool>/README.md` hold the detail. Commands below run from `k8s/`.

Environments here are `dev | staging | prod` — never `production`.

## Layout

Layers (root `CLAUDE.md` §2): **L1** `charts/application` → **L2** platform tools
(`layer: platform`, in `platform/` and `../monitoring/`) → **L3** apps (`layer: app`,
`../infra-base/k8s/env-values/`, `../argocd/`). The layer is the label, not the path.

**Templates here, values in `../infra-base/`.** This folder holds what renders (charts, each tool's
release definition, deploy order, kubectl manifests). Every value a tool is configured with lives in
`../infra-base/k8s/platform/<tool>/` (or `monitoring/<tool>/`): `values.yaml.gotmpl` for every
environment, `<env>/values.yaml.gotmpl` for what differs, `files/` for readFile'd config. A key lives
in exactly one of the two; environment logic (`$size` tables, `if $isProd`) is not written any more —
each environment states its values. See `../infra-base/README.md`.

- `helmfile.yaml.gotmpl` holds no releases, only `helmfiles:` — one state per folder.
  **That list is the deploy order**; `needs:` cannot cross folders. Do not reorder it without a
  reason: kube-prometheus-stack first (CRDs), minio before data and observability backends,
  backends before alloy/otel/grafana, cert-manager before vault, harbor last of infra, apps last.
- One folder per tool in `platform/<tool>/`, per helmfile-owned app in `apps/<app>/`:
  `helmfile.yaml.gotmpl` (release, pinned chart `version`, labels `name/layer/tier/component/env`,
  and its `values:` list pointing at `../../../infra-base/k8s/platform/<tool>/`), `README.md`,
  `manifests/` (kubectl-applied, not rendered by helm). `readFile` in a values file resolves against
  that values file's own directory.
- `platform/bootstrap/`, `platform/gateway-api/`, `platform/network-policies/` and every
  `manifests/` are kubectl-only and out of band of every pipeline.
- Every sub-helmfile repeats `bases:` (`../../../infra-base/k8s/env-values/environments.yaml`,
  `repositories.yaml`) and its own `secrets: [../../../infra-base/k8s/env-values/<env>/secrets.enc.yaml]`;
  SOPS paths resolve per evaluating helmfile.
- App values layers: `../infra-base/k8s/env-values/app-values.yaml.gotmpl` → `../infra-base/k8s/env-values/<env>/app-values.yaml.gotmpl`
  → the app's own values. Argo CD reads the same files as plain YAML.
- Observability releases live in `../monitoring/<tool>/` (same layout, values in
  `../infra-base/k8s/monitoring/<tool>/`, `bases:` at `../../infra-base/k8s/env-values/`) and are
  listed in `helmfile.yaml.gotmpl` as `../monitoring/<tool>`. Platform alert rules live in
  `../infra-base/k8s/monitoring/prometheus-rules/` and are rendered by the kube-prometheus-stack
  release (`additionalPrometheusRulesMap`).
- `charts/application` is the in-house chart for every EKS app; `values.schema.json` gates its
  values; `ci/*-values.yaml` is its test matrix.
- App tier: Helmfile by default; `APP_TIER_OWNER=argocd` hands it to
  `../argocd/bootstrap/applicationset-apps.yaml` + `../applications/<app>/k8s/{values.yaml,<env>/values.yaml}`. Keep both
  paths rendering the same values when changing an app.
- `helmDefaults`: `atomic: false`, `cleanupOnFail: false`, `historyMax: 5` — failed releases are
  kept for inspection and nothing rolls back on its own.

## Rules

- **Ambient kube context.** `environments.yaml` sets no `kubeContext`, so
  `helmfile -e <env> diff|sync` acts on whatever `kubectl config current-context` is. `-e dev`
  with a prod context applies dev values to prod. Before any cluster-touching helmfile command,
  verify the current context is that environment's cluster (`platform-<env>-eks`) and say so;
  otherwise use `template` only.
- **Pin everything.** Chart `version:` in every release, image tags never `latest` (Kyverno
  `disallow-latest-tag`), CI tool images by version, crane by SHA-256.
- **Secrets.** `../infra-base/k8s/env-values/<env>/secrets.enc.yaml` stay SOPS-encrypted, one recipient set per env
  in the root `.sops.yaml`. Never decrypt to inspect; never add a plaintext secret to values,
  `files/` or `config/`. Staging/prod recipients may still be `REPLACE_WITH_*` — do not fill them
  by guess.
- **Platform IDs come from environments.yaml.** IRSA ARNs, bucket names and ECR hosts are built
  from `eksClusterName`/`platformName` and CI's `AWS_ACCOUNT_ID`; never a literal ARN or account.
- A change to `charts/application` affects every app: bump `Chart.yaml` `version`, render the
  whole `ci/` matrix and every app in every environment.

## GitLab CI

All jobs by part, with their gates: `../ci/README.md`. Three deploy paths share the anchors in
`ci/k8s/main.yml` (`.ci-env-select`, `.ci-aws-auth`, `.ci-sops-setup`, `.ci-config-complete`, …):

| Path | File | Deploys |
|---|---|---|
| app deploy | `ci/k8s/main.yml` | trigger with `SERVICE_NAME`/`DEPLOY_ENV`/`IMAGE_TAG` → `helmfile sync -l name=<svc>`; prod `when: manual` |
| platform tools | `ci/k8s/helmfile.yml` | `-l layer=platform`; branch `dev`/`develop` → dev, `staging` → staging, `main`/`master` → prod (manual) |
| app tier via Argo | `ci/k8s/argocd.yml` | validate, diff, bootstrap the App-of-Apps |

- **A merge is a deploy.** Pushing to `dev`/`develop` or `staging` syncs that environment's
  platform tier automatically; merging to `main` queues prod. Treat a merge or push to those
  branches at the risk level of the environment it deploys.
- Keep every gate: `when: manual` on prod, `resource_group`, protected-ref rules for staging/prod
  keys, `DEPLOY_ENV`/`SERVICE_NAME`/`IMAGE_TAG` validation, the `REPLACE_WITH_` guard, gitleaks,
  `security:sops-encrypted`, hadolint, trivy `--exit-code 1`, cosign signing, `.k8s-guard`.
- A new app folder `apps/<app>/` must also be added to the `helmfiles:` list, `.chart-changes`,
  and the `.chart-render` service loop in `ci/k8s/main.yml`.

## Validate

Offline, no cluster — `make k8s-validate` from the repository root, or:

```bash
for f in charts/application/ci/*-values.yaml; do
  helm lint charts/application -f "$f" && helm template ci charts/application -f "$f" >/dev/null
done

helm template <app> charts/application -f ../infra-base/k8s/env-values/app-values.yaml.gotmpl \
  -f ../infra-base/k8s/env-values/<env>/app-values.yaml.gotmpl \
  -f ../applications/<app>/k8s/values.yaml -f ../applications/<app>/k8s/<env>/values.yaml >/dev/null   # no secrets (or: make app-render APP=<app> ENV=<env>)

helmfile -e <env> -f platform/<tool>/helmfile.yaml.gotmpl template >/dev/null   # needs that env's age key
helmfile -e <env> -f ../monitoring/<tool>/helmfile.yaml.gotmpl template >/dev/null
```

Render each affected environment: `dev`, `staging`, `prod`. Without an environment's SOPS key a
`helmfile template` for it cannot run — say so instead of skipping silently. `helmfile diff`
needs the cluster and the context check above.
