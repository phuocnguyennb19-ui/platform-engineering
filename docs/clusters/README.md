# Clusters — preparing a Kubernetes cluster from zero

Four cluster targets — **Docker Desktop**, **K3s**, **self-managed Kubernetes**, **AWS EKS** —
and one question answered before anything is deployed onto them: *does this cluster really
provide what our workloads need?*

Nothing in this directory creates a cluster, installs a component or deploys a release.

## 1. Four responsibilities, kept apart

| Responsibility | Question it answers | Lives in | State |
|---|---|---|---|
| **Provisioning** | How is the cluster created? | EKS: `terraform/stacks/core` + CI (existing). Others: [`providers/<p>/README.md`](providers/) + reference configs | EKS **implemented** (existing Terraform). Docker Desktop / K3s / self-managed: **guides** — the repo has no installer for them, and none is added |
| **Cluster metadata** | What is this cluster and what must it offer? | [`<env>/cluster/<cluster>.yaml`](../../environments/dev/kubernetes/cluster/), schema [`schemas/cluster.schema.json`](../../scripts/cluster/schemas/cluster.schema.json) | **Implemented**; read by preflight. Describes, never provisions |
| **Environment configuration** | Namespaces, ingress, security, storage… per environment | Already owned by Helmfile / Argo CD / bootstrap manifests — mapped in [`environments.md`](environments.md). `<env>/cluster/environment.yaml` holds only name mapping, deploy policy and expected PSA level | **Not duplicated**; nothing new installed |
| **Preflight validation** | What does the live cluster actually provide? | [`scripts/cluster/preflight.sh`](../../scripts/cluster/preflight.sh) (`make k8s-preflight`) | **Implemented**, read-only, tested against a stub |

```text
environments/<env>/kubernetes/cluster/     <env> = dev | staging | prod (Helm names)
├── target.yaml                   the cluster this env's apps deploy to (+ gitignored target.local.yaml)
├── environment.yaml              name mapping, deploy policy, expected PSA of namespace <env>
└── <cluster>.yaml                metadata: dev: docker-desktop-dev · k3s-dev · self-managed-dev · eks-dev;
                                  staging: eks-staging; prod: eks-production
docs/clusters/                    this guide (the same for every env)
├── README.md                     this guide
├── environments.md               where each piece of environment configuration really lives
└── providers/<provider>/         README (provision → connect → check) + reference config (*.txt)
scripts/cluster/                  tooling
├── preflight.sh                  read-only live checks
├── check-metadata.sh             offline rules a schema cannot express
├── lib/metadata.sh               the YAML reader both scripts share (awk; no yq needed)
├── schemas/*.schema.json         JSON Schema of <cluster>.yaml and environment.yaml
└── tests/preflight-test.sh       preflight against a stub kubectl — no cluster
```

**Which files are read by a tool?** `<cluster>.yaml` and `environment.yaml` are read only
by `preflight.sh` and `check-metadata.sh`; `target.yaml` (+ `target.local.yaml`) and the
`context`/`delivery.owner` of the cluster file it names are also read by
`applications/helmfile.yaml.gotmpl`. Argo CD, Terraform and kubectl read nothing here. The `*.txt` reference configs are read by nobody until you copy them onto
a server. All YAML uses `schema:` instead of `apiVersion`/`kind`, so no manifest tool mistakes
it for a Kubernetes object, and no Argo CD source, kustomization or CI glob other than the
metadata jobs selects `environments/*/kubernetes/cluster/**`.

## 2. Quick start

1. **Get a cluster and a context** — follow your provider's guide:
   [Docker Desktop](providers/docker-desktop/README.md) ·
   [K3s](providers/k3s/README.md) ·
   [self-managed](providers/self-managed/README.md) ·
   [EKS](providers/eks/README.md).
2. **Name the context in the metadata** — replace the `<placeholder>` in
   `<env>/cluster/<name>.yaml` with your kubeconfig alias, or pass `CONTEXT=` each time.
3. **Run preflight** (read-only):
   ```bash
   make k8s-preflight CLUSTER=docker-desktop-dev
   ```
4. **Fix what FAILs** through the owning path (provider guide, `helmfile:sync`,
   Argo CD) — never from here — and run preflight again.
5. **Deploy** one app from the repository root: `helmfile -e <dev|staging|prod> -l name=<app> sync`
   (cluster from `target(.local).yaml`); CI for the platform layer.

## 3. Context safety

- A context **name** is not proof that a cluster exists; preflight checks the API.
- Preflight never runs `kubectl config use-context` or edits a kubeconfig. Every call carries
  `--context=<ctx>`, so the context cannot change mid-run.
- Context selection, in order: `--context` / `CONTEXT=` / `KUBE_CONTEXT` → the `context:` of
  the cluster metadata → the current-context (flagged `IMPLICITLY SELECTED`).
  An explicit context that differs from a concrete metadata context is refused (exit 2).
- Keep provider kubeconfigs in **separate files** (`chmod 600`) and pass them with
  `KUBECONFIG_FILE=` / `--kubeconfig`: preflight reads that file through kubectl and writes
  nothing. Never commit a kubeconfig (`.gitignore` already excludes `kubeconfig`, `*.kubeconfig`, `kubeconfig*.yaml` and `.kube/`).
- EKS: use a context **alias**, never the cluster ARN — it embeds the account ID.

## 3a. Deploy targets — no exports

`<env>/cluster/target.yaml` names the cluster each Helm environment deploys to; the cluster file
in the same folder gives
its kube context and `delivery.owner`. `applications/helmfile.yaml.gotmpl` reads both, so a
manual app deploy is only:

```bash
helmfile -e dev -l name=<app> diff      # from the repository root
helmfile -e dev -l name=<app> sync
```

| Source | Holds | Committed |
|---|---|---|
| `<env>/cluster/target.yaml` | team default: `dev → eks-dev`, `staging → eks-staging`, `prod → eks-production` | yes |
| `<env>/cluster/target.local.yaml` | your machine: e.g. `dev → docker-desktop-dev`, or `context:` = your EKS alias | no (gitignored) |
| `<env>/cluster/<cluster>.yaml` | `context`, `delivery.owner` | yes |
| `KUBE_CONTEXT_<ENV>` (`_DEV`, `_STAGING`, `_PROD`), `APP_TIER_OWNER` | one-command override (plain `KUBE_CONTEXT` is preflight-only; the release guard refuses it) | — |

```yaml
# environments/dev/kubernetes/cluster/target.local.yaml
schema: kubernetes-target/v1alpha1
cluster: docker-desktop-dev          # or: cluster: eks-dev + context: my-eks-dev-alias
```

The release guard refuses when an environment has no target, the context is still a
`<placeholder>` or missing from kubeconfig, or the owner is not `helmfile`.
`check-metadata.sh` checks that every target names a cluster file of its own folder serving that
environment.

## 4. Preflight

```bash
# Docker Desktop (context `docker-desktop` comes from dev/cluster/docker-desktop-dev.yaml)
make k8s-preflight CLUSTER=docker-desktop-dev

# K3s, kubeconfig kept in its own file
make k8s-preflight CLUSTER=k3s-dev CONTEXT=k3s-dev KUBECONFIG_FILE=$HOME/.kube/k3s-dev.yaml

# self-managed
make k8s-preflight CLUSTER=self-managed-dev CONTEXT=self-managed-dev KUBECONFIG_FILE=$HOME/.kube/self-managed-dev.yaml

# EKS dev (private endpoint: run from inside the VPC / over VPN)
make k8s-preflight CLUSTER=eks-dev CONTEXT=<eks-dev-context-alias> KUBECONFIG_FILE=$HOME/.kube/eks-dev.yaml

# Without metadata: inventory only, no capability verdicts
bash scripts/cluster/preflight.sh --context docker-desktop
```

`make k8s-preflight` is `bash scripts/cluster/preflight.sh --cluster <CLUSTER>
[--context <CONTEXT>] [--kubeconfig <KUBECONFIG_FILE>]`. `PREFLIGHT_TIMEOUT` (default `10s`)
bounds every request. Dependencies: bash ≥ 3.2, kubectl, awk, grep, sed, sort, mktemp.

### Results and exit codes

| Result | Meaning |
|---|---|
| `PASS` | verified on the live cluster |
| `WARN` | optional, and verifiably absent or degraded |
| `UNKNOWN` | optional, and could not be checked (permission, API error, partial discovery) |
| `FAIL` | required, and failed **or could not be verified** |

| Exit | Meaning |
|---|---|
| `0` | no `FAIL` (WARN/UNKNOWN allowed) |
| `1` | at least one `FAIL` — do not deploy |
| `2` | usage error, missing dependency, unknown cluster file, context missing/mismatched/placeholder |

*Absent* is reported only on a confirmed `NotFound`, an empty list, or absence from API
discovery. `Forbidden`, `Unauthorized`, timeouts and connection errors are *could not verify*,
and permission denials are listed again in the summary.

### What is checked

**Required — must PASS before any deployment:** 1 dependencies · 2 context exists ·
3 API reachable · 4 at least one node `Ready` · 5 cluster DNS (`k8s-app=kube-dns`, ≥ 1 available).

**Inventory — PASS / WARN / UNKNOWN:** 6 version skew · 7 nodes (version, OS, arch) ·
8 namespaces (with metadata: the app namespace = Helm env name, and its live PSA `enforce` label vs `<env>/cluster/environment.yaml`) · 9 CNI DaemonSets (absence
is *not* a CNI failure) · 10 StorageClasses + default · 11 IngressClasses + default ·
12 Gateway API CRDs + GatewayClasses · 13 Prometheus Operator CRDs · 14 controller workloads
(by name or `app.kubernetes.io/name`/`app` label) · 15 API discovery · 16 `auth can-i`.

**Capabilities — only with `--cluster`.** For every capability the metadata marks `required`
or `optional`, preflight looks at the **live cluster**; the metadata only decides how much a
miss matters. `requires: api` is satisfied by the API types; `requires: controller` (the
default) also needs a running controller, because **a CRD alone does nothing**:

| Capability | API evidence | Controller evidence |
|---|---|---|
| `ingress` | an IngressClass | an available Deployment/DaemonSet matching that class's `spec.controller` (e.g. `ingress-controllers.konghq.com/kong` → `kong`, `k8s.io/ingress-nginx` → `ingress-nginx`) |
| `gatewayAPI` | `gateway.networking.k8s.io` CRDs served | a GatewayClass with `Accepted=True` |
| `prometheusOperator` | `PrometheusRule` CRD `Established` | an available Prometheus Operator workload — a stored `PrometheusRule` is never evaluated without it |
| `persistentStorage` | exactly one default StorageClass | its provisioner: a CSI controller workload, `local-path-provisioner`, or the Docker Desktop/minikube provisioner pod |

| expected \ live | verified | absent / degraded | could not verify |
|---|---|---|---|
| `required` | PASS | **FAIL** | **FAIL** |
| `optional` | PASS | WARN | UNKNOWN |
| `not-used` | not evaluated | not evaluated | not evaluated |

`verified:` in the metadata is a past manual record (with `verifiedOn` / `verifiedBy`); it
never makes a check PASS. When it disagrees with the live result, preflight says it is stale.

### Permissions

Read-only, but cluster-wide: `get/list` on nodes, namespaces, StorageClasses, IngressClasses,
CRDs, GatewayClasses, Deployments and DaemonSets in all namespaces, and pods in `kube-system`
(Docker Desktop storage only). The built-in `view` ClusterRole is **not** enough (no nodes,
StorageClasses or CRDs). Missing permissions turn checks into UNKNOWN — or FAIL for required
ones — never into *absent*. `kubectl auth can-i` submits a `SelfSubjectAccessReview`: it
persists nothing, but audit logs record it as a `create`. Secrets are never read.

## 5. When something fails

| Symptom | Meaning | What to do |
|---|---|---|
| exit 2 `context '…' is not in kubeconfig` | no kubeconfig entry with that name (or wrong file) | create the cluster/entry per provider guide; `kubectl config get-contexts -o name`; pass `KUBECONFIG_FILE=` if it lives in its own file |
| exit 2 `still has context <…>` | metadata placeholder not replaced | pass `CONTEXT=<alias>` or edit `<env>/cluster/<name>.yaml` |
| exit 2 `is not the context of …` | explicit context ≠ metadata context | decide which is right; preflight never guesses |
| FAIL 3 `unreachable` / `timeout` | API not answering from here | cluster stopped? Docker Desktop Kubernetes off? EKS private endpoint → VPN/bastion |
| FAIL 3 `unauthorized` | credentials rejected or `aws eks get-token` failed | refresh your login/SSO; check the access entry — do not widen policies |
| FAIL 4 nodes `0/N Ready` | kubelet/CNI not healthy | `kubectl --context=<ctx> describe node <node>` (read); fix on the node |
| FAIL 5 cluster DNS | no CoreDNS or no available replica | `kubectl --context=<ctx> -n kube-system get pods -l k8s-app=kube-dns` (read) |
| FAIL `C <capability>` | workloads need something the cluster lacks | install it through its owner (table in [`environments.md`](environments.md)), or change `expected` if workloads truly do not need it |
| many UNKNOWN + check 16 `no` | identity lacks read permissions | ask for a read-only ClusterRole binding; results are not evidence of absence |

## 6. Read-only vs state-changing commands

| Read-only (safe to run anywhere you are allowed to) | Changes state (deliberate, owner's decision) |
|---|---|
| `make k8s-preflight`, `make k8s-env-test`, `make k8s-env-schema` | `helmfile … sync/apply/destroy` |
| `kubectl get/describe/api-resources/version/auth can-i` | `kubectl apply/create/delete/patch/edit/label/annotate/scale` |
| `aws eks describe-*/list-*` | `aws eks update-kubeconfig` (your local file), `terraform apply` (CI `apply:*` only) |
| `make app-render`, `make argocd-render`, `helmfile template/diff` | Docker Desktop "Enable Kubernetes", `k3s` installer, `kubeadm init/join` |

## 7. CI/CD

| Job / path | What it does | Cluster access |
|---|---|---|
| `k8s-env:schema` (`ci/k8s/main.yml`, stage `lint`) | yamllint (repo config `terraform/.yamllint.yml`) + check-jsonschema, same pinned requirements as Terraform `config` | none — `inherit: default: false` drops the OIDC token |
| `k8s-env:test` (same file) | `check-metadata.sh` + `tests/preflight-test.sh` | none (stub kubectl) |
| Live preflight | operator runs `make k8s-preflight` | the operator's own read identity |

Both jobs run on push/MR when `environments/*/kubernetes/cluster/**` changes, behind `.k8s-guard` and
`.k8s-push-mr-only` like the other k8s jobs. Rendering (`chart:render:*`, `argocd-render`)
already needs no cluster.

**Single owner per release.** Every Helm release or Argo CD Application has exactly one owner
that applies it — `argocd`, `helmfile` or `ci` — and `delivery.owner` records it per cluster:

| Releases | Owner | Enforced by |
|---|---|---|
| Apps on dev/staging/prod | Helmfile, manually, while `APP_TIER_OWNER=helmfile`; otherwise Argo CD (`kubernetes/argocd/bootstrap/applicationset-apps.yaml`) | `scripts/deploy/release-guard.sh`: refuses without owner `helmfile`, a configured kube context, `-l name=<app>`, when plain `KUBE_CONTEXT` is set, when an Argo CD Application `<app>-<env>` exists, or when that check cannot run |
| Platform + monitoring (`layer=platform`) | Helmfile, via `helmfile:sync:<env>` | jobs select `-l layer=platform` only |
| Apps on Docker Desktop / K3s / self-managed | Helmfile, manually: that cluster is the target of `dev` in `dev/cluster/target.local.yaml` | `scripts/deploy/release-guard.sh` |

**`ciDeployAllowed` and `autoDeploy` are metadata, not CI switches.** Every file sets both to
`false`, and the schema forbids `true` for staging/production, but no pipeline reads
them. See *Open items* for the existing jobs this matters for.

## 8. Extending

**A new cluster** (e.g. a second K3s): copy the closest `<env>/cluster/<name>.yaml` to a new name;
set `name` = file name, `context` (or a `<placeholder>`), `environment`, `provisioning`,
`delivery`, and each capability's `expected` with a comment citing the values that need it.
Then `make k8s-env-test` and `make k8s-env-schema`.

**A new provider** (e.g. kind, GKE): add it to the `provider` enum in
`schemas/cluster.schema.json` (the only place enums live), add a provisioning method if
needed, write `providers/<provider>/README.md` (provision → connect → check, commands marked
read / changes state), and add a cluster file. If its storage provisioner or ingress controller
is unknown to preflight, add it to the mapping in `eval_persistentStorage` / `eval_ingress`
and a scenario to `tests/preflight-test.sh`.

**A new environment**: it must first exist where environments are really defined
(`environments/<env>/kubernetes/state.yaml`, namespaces, Argo CD, Terraform). Then add
`<env>/cluster/environment.yaml` with its `names` and the PSA level its namespace manifest enforces,
and extend the `environment`/`name` enums and the name mapping in the two schemas.

## 9. Validation

```bash
make k8s-env-test     # bash -n, shellcheck if installed, cross-file metadata rules, 42 stub-kubectl assertions
make k8s-env-schema   # yamllint + check-jsonschema (pip install -r ci/terraform/requirements.txt)
make validate         # now includes k8s-env-test
```

## 10. Open items (not changed here)

- **CI deploys the platform layer automatically to staging.** `helmfile:sync:staging` runs on
  every push to `staging` without `when: manual` (dev too; prod is manual). That predates this
  directory and contradicts "no automatic deployment to staging/production"; changing it is a
  CI gate decision (HIGH risk) left to the platform owners.
- **No live preflight in CI.** It would need a read-only Kubernetes identity per cluster (the
  existing `gitlab-deploy-<env>` roles can deploy and must not be reused for checks).
- **No ResourceQuota / LimitRange** anywhere in the repository.
- **No ingress controller for laptop clusters** in the repository (use `port-forward`).
- **App tier is deployed manually with Helmfile for now** (`delivery.owner: helmfile`). When
  Argo CD takes over, unset `APP_TIER_OWNER` and switch `delivery.owner` back; the guard refuses
  Helmfile once an Argo CD Application `<app>-<env>` exists.
- **No StorageClass is defined** for any environment; each provider's default is whatever the
  cluster ships — preflight shows it.
- The metadata lives in `environments/<env>/kubernetes/cluster/` (it used to be the top-level `infras/kubernetes/`); it
  holds cluster targets only and duplicates none of the `environments/<env>/kubernetes/` values.

### Placeholders

`<k3s-dev-context>`, `<self-managed-dev-context>`, `<eks-{dev,staging,production}-context-alias>`
in `<env>/cluster/`; `<api-address>`, `<pod-cidr>`, `<v1.32.x>`, `<v1.32.x+k3s1>`, `<join-token>`,
`<aws-region>`, `<principal-arn>`, `<namespace>`, `<name>` in `providers/` — replaced locally,
never with a secret in git.
