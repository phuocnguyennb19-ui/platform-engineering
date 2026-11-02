# GitOps with Argo CD — App-of-Apps (app-tier)

| | |
|---|---|
| **What it holds** | Argo CD only: `root-app.yaml`, `bootstrap/` (AppProject, ApplicationSet that generates one Application per app × environment). |
| **Owner** | platform team |
| **How to change** | the ApplicationSet repeats the app value layers of `applications/helmfile.yaml.gotmpl` — change both |
| **Validate** | `make argocd-manifests` · `bash scripts/docs/check-argocd-layers.sh` |

The **optimal** model for this repo: a **clear boundary between the two tools**,
never letting both manage the same release (avoids ownership conflicts with the
Helm release secret).

| Tier | Tool | Why |
|---|---|---|
| **Infrastructure** (domains: observability, security, data stores, ingress…) | **helmfile** | Installed once / rarely changed, cross-namespace `needs`, uses gotmpl + SOPS which Argo CD core cannot render. |
| **App-tier** (`charts/application`: be-payment, be-user…) | **Argo CD** | Deployed frequently, needs rollback/auto-sync/drift-detection — Argo's CD sweet spot. |

> Why NOT let Argo CD manage infra too: infra values are `*.yaml.gotmpl` + SOPS —
> Argo CD only understands plain Helm/Kustomize/YAML, it does **not run
> `helmfile` or `.gotmpl`**. To make Argo manage infra you need a **helmfile CMP**
> (see the end of this file) — more risk/effort, not recommended as a first step.

## Layout

```
kubernetes/argocd/
├── root-app.yaml                       # App-of-Apps ROOT — apply once
├── bootstrap/                          # root-app syncs this dir
│   ├── appproject-platform.yaml        # AppProject "platform" (guardrail)
│   └── applicationset-apps.yaml        # one Application per applications/<app>/k8s × cluster
../applications/<app>/k8s/              # app values (not Argo-specific; also read by applications/helmfile)
└── dev/values.yaml  staging/values.yaml  prod/values.yaml   # one complete file per environment
```

**Add a new app** = `make new-app APP=<name>` (or create one complete `applications/<name>/k8s/<env>/values.yaml` per environment — there is no shared app file) and commit. Example: `applications/frontend-html`. The
ApplicationSet generates the matching Application automatically. No need to edit
bootstrap.

## How it works

```
git push ──► Argo CD
              │  root-app (App-of-Apps) syncs bootstrap/
              │     ├─ AppProject "platform"  (limits repo/ns/resources)
              │     └─ ApplicationSet         (git directory generator: *)
              │            └─ generates Applications: be-payment, be-user, …
              └─ each Application = MULTI-SOURCE (same git repo):
                   (1) charts/application chart      (path)
                   (2) <app>/values.yaml        (ref: values)
```

- **Plain values** (no gotmpl) → Argo renders natively, no CMP needed.
- **App secrets are NOT in the values** — use ESO / SealedSecrets to create the
  Secret in the target ns, the app loads it via `extraEnvFrom` (see `be-payment/values.yaml`).

## Bootstrap (run once)

```bash
# 0. Fill the REMAINING placeholders in */values.yaml: image repo, host.
#    (the git repoURL is already set: gitlab.com/myorg/helm-project-v3 @ main)

# 1. (ONLY for a private repo) register the repo with Argo CD:
argocd repo add https://gitlab.com/myorg/helm-project-v3.git \
  --username <user> --password <token>
#    Public repo → skip. The charts/application chart is read STRAIGHT from the repo (no OCI).

# 2. Apply the ROOT (self-managing from here):
kubectl apply -f kubernetes/argocd/root-app.yaml

# 3. Verify:
argocd app list
argocd app get platform-bootstrap
argocd cluster get https://kubernetes.default.svc     # → status Successful (has an app now)
```

`root-app.yaml` also creates the AppProject `bootstrap` the root app runs in: it may only write
AppProjects and ApplicationSets in `infra`, from this repository. Because whatever lands in
`bootstrap/` is synced with that power, `scripts/deploy/check-argocd-bootstrap.sh` (`make argocd-guard`,
CI `argocd:validate`) refuses a merge that would widen Argo CD: any kind but AppProject `platform`
and ApplicationSets, a `platform` project with a cluster-scoped kind, a `*`, another source or a
namespace other than dev/staging/prod, or an ApplicationSet whose Applications are not in `platform`.
Change those limits only together with the guard. The live `default` AppProject is not managed
here — restrict it on each cluster (`argocd proj get default`).

## ⚠ Path cutover after the repository restructure

The App-of-Apps reads `targetRevision: main` in **every** cluster. The restructure moved what it points at:

| Object | Old path on `main` | New path |
|---|---|---|
| root app `platform-bootstrap` (`root-app.yaml`) | `argocd/bootstrap` | `kubernetes/argocd/bootstrap` |
| ApplicationSet chart source | `k8s/charts/application` | `kubernetes/charts/application` |
| ApplicationSet value files | `$values/infra-base/k8s/<env>/app-values.yaml.gotmpl` | `$values/environments/<env>/kubernetes/app-values.yaml.gotmpl` |

The root app is applied with `kubectl` (or the manual `argocd:bootstrap:<env>` job), not synced from git, so a
live root app keeps the **old** path after the merge and every Argo-managed app goes to `ComparisonError`
(path does not exist). Expected not to prune — that is an assumption to confirm on dev first.

**Before merging** — per cluster, read-only:

```bash
kubectl --context=<ctx> -n infra get applications.argoproj.io platform-bootstrap \
  -o jsonpath='{.spec.source.path}{"\n"}'        # NotFound → Argo CD is not live there: nothing to cut over
```

Today every cluster file says `delivery.owner: helmfile`, so normally nothing is live. If a cluster prints
`argocd/bootstrap`:

1. Merge. Then, **in this order — dev, staging, prod** — re-apply the root app **from a ref that contains the
   merge** (the manual `argocd:bootstrap:<env>` job only runs on `dev|develop` / `staging` / `main`; running it
   from a branch without the commit re-applies the old path):
   ```bash
   kubectl --context=<ctx> -n infra apply -f kubernetes/argocd/root-app.yaml     # or the argocd:bootstrap:<env> job
   ```
2. Verify on that cluster before moving to the next one:
   ```bash
   kubectl --context=<ctx> -n infra get applications.argoproj.io platform-bootstrap -o jsonpath='{.spec.source.path}{"\n"}'
   kubectl --context=<ctx> -n infra get applications.argoproj.io      # every app Synced/Healthy, none ComparisonError
   ```
3. Prod has `auto-sync=false`: review `argocd app diff` and sync by hand.

Rollback: revert the merge and re-apply `root-app.yaml` from the reverted `main`, cluster by cluster.

## ⚠ Ownership handover: remove the app-tier from helmfile

Once Argo CD manages the app-tier, you **must stop helmfile from installing the
same releases** so the two don't overwrite each other. Set `APP_TIER_OWNER=argocd`
— every app's `helmfile.yaml.gotmpl` then renders with `installed: false`. To make
it permanent instead, drop the app entries from the include list at the end of
[../helmfile.yaml.gotmpl](../helmfile.yaml.gotmpl). The tools stay managed by
helmfile either way.

> If a release was previously installed by helmfile, Argo will **adopt** it on
> the first sync (adds the `app.kubernetes.io/instance` label) rather than
> recreate it — as long as the manifests match. A stale Helm release Secret may
> remain (harmless) → clean up later with `helm uninstall --no-hooks` or delete
> the `sh.helm.release.*` secret manually.

## Multi-environment

This setup targets **in-cluster / ns `dev`**. For multiple envs, pick one of:

1. **Multiple clusters** (recommended for prod): add the staging/prod clusters to
   Argo (`argocd cluster add`), switch the generator to a **matrix** (git dirs ×
   cluster list), set `destination.server`/`namespace` per cluster.
2. **One cluster, many ns**: use a **list** generator for env, ns = `{{.env}}`,
   `className: nginx-{{.env}}`, and split into `<env>/<app>/values.yaml`.

## (Optional) Making Argo CD manage infra too → helmfile CMP

Plug a **Config Management Plugin** that runs `helmfile template` inside the
argocd repo-server (sidecar), mounting the age key (SOPS) via a Secret. Argo then
renders the existing gotmpl domains **without a rewrite**. Trade-offs:

- Security risk: the age key lives in the repo-server.
- Loses helmfile's `needs` ordering → you must use **argocd sync-waves**
  (annotation `argocd.argoproj.io/sync-wave`) instead.
- You must STOP `helmfile sync` from the CLI for those releases (Argo becomes the
  single applier).

→ Only do this if you truly need Argo to be the source of truth for infra too.
Default: **helmfile owns infra, Argo owns apps.**
