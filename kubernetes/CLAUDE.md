# CLAUDE.md — k8s

The platform rules (architecture, environment mapping, workflow, risk levels, deployment and
verification) are in the root `CLAUDE.md`; global policy in `~/Dylan/.claude/CLAUDE.md`.
This file adds what is specific to `kubernetes/`. `README.md`, `docs/DEPLOY.md` (platform tier) and
`releases/<group>/<tool>/README.md` hold the detail; the step-by-step deploy is
`../docs/20-runbooks/kubernetes-manual.md`. Commands below run from `kubernetes/`.

Environments here are `dev | staging | prod` — never `production`.

## Layout

Layers (root `CLAUDE.md` §2): **L1** `charts/application` → **L2** platform tools
(`layer: platform`, in `platform/` and `releases/observability/`) → **L3** apps (`layer: app`,
`../environments/<env>/kubernetes/`, `../kubernetes/argocd/`). The layer is the label, not the path.

**Templates here, values in `../environments/<env>/kubernetes/`.** This folder holds what renders (charts, each tool's
release definition, deploy order, kubectl manifests). Every value a tool is configured with lives in
`../environments/<env>/kubernetes/{tools,ingress,monitoring}/<tool>/values.yaml.gotmpl` for every environment
(+ `files/` for readFile'd config) and `../environments/<env>/kubernetes/{tools,ingress,monitoring}/<tool>/` for
what differs. A key lives
in exactly one of the two; environment logic (`$size` tables, `if $isProd`) is not written any more —
each environment states its values. See `../environments/README.md`.

- `helmfile.yaml.gotmpl` holds no releases, only `helmfiles:` — one state per folder.
  **That list is the deploy order**; `needs:` cannot cross folders. Do not reorder it without a
  reason: prometheus-operator-crds first (CRDs), kube-prometheus-stack, then networking (cert-manager, kong — before every
  tool with an Ingress, which uses class kong and Kong's plugins), minio before data and
  observability backends, backends before alloy/otel/grafana, harbor last of infra, apps last.
- One folder per tool in `releases/{platform,observability}/<tool>/`:
  `helmfile.yaml.gotmpl` (release, pinned chart `version`, labels `name/layer/tier/component/env`,
  and its `values:` list pointing at `../../../environments/<env>/kubernetes/tools/<tool>/`), `README.md`,
  `manifests/` (kubectl-applied, not rendered by helm). `readFile` in a values file resolves against
  that values file's own directory.
- `releases/platform/gateway-api/`, every `manifests/` and the namespaces + NetworkPolicies in
  `../environments/<env>/kubernetes/{namespace,network}/` are kubectl-only and out of band of every
  pipeline.
- Every sub-helmfile repeats `bases:` (`../../../environments/<env>/kubernetes/state.yaml`,
  `repositories.yaml`) and its own `secrets: [../../../environments/<env>/kubernetes/secrets.enc.yaml]`;
  SOPS paths resolve per evaluating helmfile.
- App values layers: `../environments/<env>/kubernetes/app-values.yaml.gotmpl`
  → the app's own values. Argo CD reads the same files as plain YAML.
- Observability releases live in `../kubernetes/releases/observability/<tool>/` (same layout, values in
  `../environments/<env>/kubernetes/monitoring/<tool>/`, `bases:` at `../../environments/<env>/kubernetes/`) and are
  listed in `helmfile.yaml.gotmpl` as `../kubernetes/releases/observability/<tool>`. Platform alert rules live in
  `../environments/<env>/kubernetes/monitoring/prometheus-rules/` and are rendered by the kube-prometheus-stack
  release (`additionalPrometheusRulesMap`).
- `charts/application` is the in-house chart for every EKS app; `values.schema.json` gates its
  values; `ci/*-values.yaml` is its test matrix.
- **No app release lives in `kubernetes/`.** `apps/` is absent and the `# ── applications` block at
  the end of `helmfile.yaml.gotmpl` lists nothing, so `helmfile -l layer=app …` here (and CI
  `deploy:apply`, `--selector layer=app,name=<svc>`) matches no release. The apps are
  `../applications/<app>` (frontend-html, test-app, devops-platform), one values file per
  dev/staging/prod, released by `../applications/helmfile.yaml.gotmpl`.
- App tier owner: manual Helmfile today (`delivery.owner: helmfile` in the target's cluster file;
  `APP_TIER_OWNER` overrides). Argo CD (`../kubernetes/argocd/bootstrap/applicationset-apps.yaml`) reads the same
  files; `../scripts/deploy/release-guard.sh` refuses a helmfile sync once an Argo Application
  `<app>-<env>` exists. Keep both paths rendering the same values when changing an app.
- `helmDefaults`: `atomic: false`, `cleanupOnFail: false`, `historyMax: 5` — failed releases are
  kept for inspection and nothing rolls back on its own.

### Where things live — chart, values, upstream tools

| What | Where |
|---|---|
| app values (data only) | `../applications/<app>/k8s/<env>/values.yaml` — one complete file per environment, no shared app file |
| the in-house chart | `charts/application` |
| upstream charts (cloned modules) | `releases/platform/<tool>/helmfile.yaml.gotmpl` (chart + version), values in `../environments/<env>/kubernetes/tools/<tool>/` |
| values → chart mapping | `../applications/helmfile.yaml.gotmpl` — one release per `<app>/k8s/<env>/values.yaml`, generated, none declared by hand (same layers as the ApplicationSet) |
| app deploy | dev/staging/prod only, from the repo root: `helmfile -e <env> -l name=<app> diff|sync`; the cluster (EKS, Docker Desktop, K3s…) is the target in `../environments/<env>/kubernetes/cluster/target(.local).yaml`; Argo CD later |

There is one app model only. Do not add a second values location or a second chart for apps.

## Rules

- **Ambient kube context (platform helmfiles).** `environments.yaml` sets no `kubeContext`, so
  `helmfile -e <env> diff|sync` in `kubernetes/` or `releases/observability/` acts on whatever
  `kubectl config current-context` is (pass `--kube-context`). `-e dev` with a prod context applies
  dev values to prod. Before any cluster-touching platform helmfile command, verify the context is
  that environment's cluster and say so; otherwise use `template` only. App releases are pinned:
  their context comes from `../environments/<env>/kubernetes/cluster/target(.local).yaml`.
- **Pin everything.** Chart `version:` in every release, image tags never `latest` (Kyverno
  `disallow-latest-tag`), CI tool images by version, crane by SHA-256.
- **Secrets.** `../environments/<env>/kubernetes/secrets.enc.yaml` stay SOPS-encrypted, one recipient set per env
  in the root `.sops.yaml`. Never decrypt to inspect; never add a plaintext secret to values,
  `files/` or `config/`. Staging/prod recipients may still be `REPLACE_WITH_*` — do not fill them
  by guess.
- **Platform IDs come from environments.yaml.** IRSA ARNs, bucket names and ECR hosts are built
  from `eksClusterName`/`platformName` and CI's `AWS_ACCOUNT_ID`; never a literal ARN or account.
- A change to `charts/application` affects every app: bump `Chart.yaml` `version`, render the
  whole `ci/` matrix and every app in every environment (`make argocd-render`).

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
- A new app is `../applications/<app>/` (`make new-app`); the app helmfile picks it up from the
  folder tree — nothing to add to `helmfiles:`.

## Validate

Offline, no cluster — `make k8s-validate` from the repository root, or:

```bash
for f in charts/application/ci/*-values.yaml; do
  helm lint charts/application -f "$f" && helm template ci charts/application -f "$f" >/dev/null
done

helm template <app> charts/application -f ../environments/<env>/kubernetes/app-values.yaml.gotmpl \
  -f ../environments/<env>/kubernetes/app-values.yaml.gotmpl \
  -f ../applications/<app>/k8s/<env>/values.yaml >/dev/null   # no secrets (or: make app-render APP=<app> ENV=<env>)

helmfile -e <env> -f releases/platform/<tool>/helmfile.yaml.gotmpl template >/dev/null   # needs that env's age key
helmfile -e <env> -f ../kubernetes/releases/observability/<tool>/helmfile.yaml.gotmpl template >/dev/null
```

Root `Makefile` targets (run from the repository root; none syncs, plans or applies):

| Target | Does |
|---|---|
| `make k8s-validate` | `chart-lint` + `argocd-render` + `sops-check` |
| `make chart-lint` | lint + render every `charts/application/ci/*-values.yaml` |
| `make argocd-render` | render every app in dev/staging/prod through `../applications/helmfile.yaml.gotmpl`, then check the ApplicationSet's copy of the layers |
| `make app-render APP=<app> ENV=<env>` | print one app's manifests (same helmfile) |
| `make app-values APP=<app> ENV=<env>\|all` | one app's final merged values |
| `make platform-template ENV=<env>` | `helmfile -e ENV -l layer=platform template` (needs that env's age key) |
| `make docs-check` / `docs-reference` | generated chart docs under `../docs/` are stale / regenerate them — run after any `charts/application` change |

Single case: `helm lint charts/application -f charts/application/ci/<name>-values.yaml`; single
tool: `helmfile -e <env> -f releases/platform/<tool>/helmfile.yaml.gotmpl template`.

Render each affected environment: `dev`, `staging`, `prod`. Without an environment's SOPS key a
`helmfile template` for it cannot run — say so instead of skipping silently. `helmfile diff`
needs the cluster and the context check above.
