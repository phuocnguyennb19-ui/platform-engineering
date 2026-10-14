# DEPLOY — platform runbook

The single deploy document for this repo. Covers prerequisites, deploy order, both delivery
paths (helmfile and Argo CD), per-component reference, day-2 operations, rollback and the
common traps.

Per-component detail (prereqs, verify, rollback, alerts for one tool) lives in a `README.md`
next to that tool's values file — indexed in [§10](#10-component-index).
Incident history: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**Layout note:** commands run from `k8s/`. One folder per tool under `platform/`
and per application under `apps/`, named after the thing it deploys (`platform/postgresql/`,
`../monitoring/loki/`, `apps/be-payment/` …), each holding its own
`helmfile.yaml.gotmpl`. The root `helmfile.yaml.gotmpl` includes every folder and
**that include order is the deploy order**. Groupings like "data" or "observability" below are ordering
groups in this document, not directories. Argo CD runs in namespace **`infra`**,
not `argocd`.

---

## Contents

| § | |
|---|---|
| [1](#1-what-gets-deployed) | What gets deployed |
| [2](#2-prerequisites) | Prerequisites — tools, keys, env vars |
| [3](#3-approval-gates-ai-driven-runs) | Approval gates (AI-driven runs) |
| [4](#4-target-matrix--local--onprem--cloud) | Target matrix: local / onprem / cloud |
| [5](#5-deploy-order) | Deploy order |
| [6](#6-path-a--helmfile) | **Path A — helmfile** |
| [7](#7-path-b--argo-cd) | **Path B — Argo CD** |
| [8](#8-selector-reference) | Selector reference |
| [9](#9-day-2-operations) | Day-2 operations |
| [10](#10-component-index) | Component index (39 per-tool docs) |
| [11](#11-common-traps) | Common traps |
| [12](#12-quick-reference) | Quick reference |

---

## 1. What gets deployed

**36 releases** = 32 platform (`layer=platform`) + 4 app (`layer=app`).
`cluster-autoscaler` is declared but `installed: false` by default.

Two independent delivery paths:

| | Manages | Tool | Pipeline |
|---|---|---|---|
| **A. Helmfile** | the 32 platform releases | `helmfile sync` | `ci/k8s/helmfile.yml` |
| **B. App-tier** | the 4 app releases | helmfile **or** Argo CD | `ci/k8s/main.yml` / `ci/k8s/argocd.yml` |

> ⚠ The app tier must have **exactly one owner**. See [§6.0](#60-choose-the-app-tier-owner).

Two manifest sets are applied with `kubectl`, not helmfile, because helmfile ordering
cannot express them: `platform/bootstrap/manifests/namespaces.yaml` (**first**) and
`platform/network-policies/manifests/` (**last**).

---

## 2. Prerequisites

### 2.1 Tools

Use the `deploy-tools` image so versions match CI exactly:

```bash
docker run --rm -it \
  -v "$PWD":/w -w /w \
  -v ~/.kube:/home/deploy/.kube \
  -v ~/.config/sops/age/keys.txt:/keys.txt:ro \
  -e SOPS_AGE_KEY_FILE=/keys.txt \
  "$CI_REGISTRY_IMAGE/deploy-tools:1.2.0"
```

Installing locally instead — these exact versions (see `ci/images/Dockerfile`):

```
helm 3.20.1 · helmfile 1.4.2 · sops 3.13.3 · kubectl 1.34.1 · aws-cli 2.31.19
helm plugins: secrets 4.7.7, diff 3.15.10
```

> `helmfile` **must** be 1.4.2 — it matches the `version:` pinned in every `*/helmfile.lock`.
> A different version re-resolves chart versions and makes the lock files meaningless.

```bash
# macOS
brew install helm helmfile sops age kubectl awscli kind
helm plugin install https://github.com/jkroepke/helm-secrets

# Windows (PowerShell)
winget install Helm.Helm Mozilla.SOPS FiloSottile.age Kubernetes.kubectl Amazon.AWSCLI
scoop install helmfile kind
helm plugin install https://github.com/jkroepke/helm-secrets
```

Verify: `helm version && helmfile version && sops --version && kubectl version --client`

### 2.2 SOPS key

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d env-values/prod/secrets.enc.yaml | head -3     # must decrypt → key is correct
```

The public key must match the `age:` recipient in `.sops.yaml`. In CI the group variable
`SOPS_AGE_PRIVATE_KEY` is written to a file by the `.sops-setup` anchor.

### 2.3 Kubeconfig

```bash
aws eks update-kubeconfig --name "$PROD_EKS_CLUSTER" --region ap-southeast-1
kubectl config current-context          # confirm you are on the intended cluster
```

### 2.4 Environment variables

| Variable | Required when | Notes |
|---|---|---|
| `SOPS_AGE_KEY_FILE` | **always** | missing → helmfile fails while reading the environment |
| `APP_TIER_OWNER` | **always** | `helmfile` (default) or `argocd` |
| `CHART_PATH` | dev / local | point at `charts/application` to use the local chart instead of OCI |
| `HELM_CHART_ACCOUNT_ID` | app tier via helmfile | default `339713046864` |
| `AWS_REGION` | app tier via helmfile | default `ap-southeast-1` |
| `CHART_VERSION` | app tier via OCI | default `1.1.0` |
| `IMAGE_TAG` | app tier | image tag; default `1.0.0` |
| `VAULT_KMS_KEY_ID` | prod | missing → Vault starts **sealed** |
| `AWS_ACCOUNT_ID` | prod | IRSA role for Vault auto-unseal |
| `ACME_EMAIL` | optional | default `platform@example.com` |
| `ENABLE_CLUSTER_AUTOSCALER` | non-EKS only | `true` enables it; **never** together with Karpenter |

### 2.5 Cloud prerequisites (onprem/cloud targets)

- S3 buckets: `velero-backups-<env>` (Velero creates nothing itself); Loki/Tempo/Mimir use
  MinIO buckets provisioned by `minio`.
- IRSA roles — the values files ship `<ACCOUNT_ID>` **placeholders** that must be replaced:
  `external-dns-<env>`, `velero-<env>`, `karpenter-<env>`, `cluster-autoscaler-<env>`.
- Karpenter also needs a real cluster name, an SQS interruption queue, and
  `karpenter.sh/discovery=<clusterName>` tags on subnets/security groups.
- A DNS zone matching `ingressDomain` in `env-values/environments.yaml`.

---

## 3. Approval gates (AI-driven runs)

Both humans and AI agents can follow this document. The difference: **an AI must request
human approval at every gated step.**

| Label | Meaning | AI allowed? |
|---|---|---|
| 🟢 **AUTO** | read-only / render-only / local, never touches a real cluster | ✅ runs on its own |
| 🟡 **APPROVE** | writes to a cluster, creates secrets, encrypts | ⚠️ must ask a human **before each run** |
| 🔴 **PROD / DESTRUCTIVE** | touches `prod`, `destroy`, `rollback`, DNS changes | ⛔ human only, or approve command by command |

Rules for AI:

1. Always run the 🟢 `diff` / `template` step first and show the output to the human.
2. Only run 🟡/🔴 after an explicit `APPROVE`.
3. Never invent or change real secret values. Never change DNS. Never `destroy`.
4. Each 🟡/🔴 command needs its **own** approval — approving one does not imply the next.

Gate lookup:

| Command | Gate |
|---|---|
| `helmfile deps / build / template / diff / lint / list`, `helm search`, `kubectl get/top/describe/logs` | 🟢 |
| `kind create/delete`, anything on a `local` cluster | 🟢 |
| `helmfile -e dev\|staging sync`, `kubectl apply`, `sops -e/-d` | 🟡 |
| anything `-e prod`, `rollback`, `destroy`, `kubectl delete`, DNS changes, filling real secrets | 🔴 |

Humans: ignore the labels and run the steps in order.

---

## 4. Target matrix — local / onprem / cloud

| | `local` (kind) | `onprem` | `cloud` (EKS) |
|---|---|---|---|
| LoadBalancer | NodePort / port-forward | MetalLB | AWS NLB (default) |
| StorageClass | `standard` (kind) | Ceph / NFS / local-path | `gp3` (EBS) |
| TLS | self-signed / skipped | LE DNS-01 or internal CA | LE HTTP-01 (default) |
| Secrets backend | SOPS | SOPS / Vault | IRSA + AWS SM (ESO) |
| Velero / Karpenter | **off** | Velero (MinIO), **no Karpenter** | both on |
| Releases installed | light subset | most | all |

Non-AWS clusters: deselect Karpenter on every command with `-l 'name!=karpenter'`.

### Local smoke test (kind — ephemeral, all 🟢)

```bash
cat <<'EOF' | kind create cluster --name htest --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - { containerPort: 30080, hostPort: 80,  protocol: TCP }
      - { containerPort: 30443, hostPort: 443, protocol: TCP }
EOF

kubectl apply -f platform/bootstrap/manifests/namespaces.yaml
helmfile -e dev deps

# light subset for a laptop
helmfile -e dev \
  -l name=kube-prometheus-stack -l name=metrics-server \
  -l name=cert-manager -l name=ingress-nginx \
  template                                            # review first
helmfile -e dev \
  -l name=kube-prometheus-stack -l name=metrics-server \
  -l name=cert-manager -l name=ingress-nginx sync

CHART_PATH=charts/application helmfile -e dev -l name=be-user sync

kind delete cluster --name htest
```

---

## 5. Deploy order

The root `helmfile.yaml.gotmpl` includes each domain as a **separate state**, so `needs` does
**not** work across domains — the include order *is* the dependency order:

```
cluster base  →  data  →  observability  →  networking  →  security  →  delivery  →  apps
```

| # | Step | Command | Required |
|---|---|---|---|
| 1 | Namespaces + PSA | `kubectl apply -f platform/bootstrap/manifests/namespaces.yaml` | ✅ |
| 2 | Deps + render check | `helmfile -e $ENV deps && … template` | ✅ |
| 3 | cluster base | `helmfile -e $ENV -f platform/<tool>/helmfile.yaml.gotmpl sync` (§6.4) | ✅ |
| 4 | data | `helmfile -e $ENV -f platform/<tool>/helmfile.yaml.gotmpl sync` (§6.4) | ✅ |
| 5 | observability | `helmfile -e $ENV -f platform/<tool>/helmfile.yaml.gotmpl sync` (§6.4) | ✅ |
| 6 | networking | `helmfile -e $ENV -f platform/<tool>/helmfile.yaml.gotmpl sync` (§6.4) | ✅ |
| 7 | Vault TLS cert | `kubectl apply -f platform/vault/manifests/certificate.yaml` | ✅ (staging/prod) |
| 8 | security | `helmfile -e $ENV -f platform/<tool>/helmfile.yaml.gotmpl sync` (§6.4) | ✅ |
| 9 | delivery | `helmfile -e $ENV -f platform/<tool>/helmfile.yaml.gotmpl sync` (§6.4) | ✅ |
| 10 | Kyverno policies | `kubectl apply -f platform/kyverno/manifests/` | recommended |
| 11 | NetworkPolicies | `kubectl apply -f platform/network-policies/manifests/` | recommended |
| 12a | Apps via helmfile | `helmfile -e $ENV -l layer=app sync` | pick one |
| 12b | Apps via Argo CD | `kubectl apply -f ../argocd/root-app.yaml` | pick one |

Why this order: `kube-prometheus-stack` ships the ServiceMonitor/PrometheusRule CRDs everything else needs;
`minio` must exist before Mimir/Loki/Tempo; Harbor needs Postgres/Redis/MinIO + ingress;
apps need ingress-nginx and metrics-server.

---

## 6. Path A — helmfile

### 6.0 Choose the app-tier owner

```bash
export APP_TIER_OWNER=helmfile   # helmfile installs the 4 app releases; Argo ApplicationSet stays off
# or
export APP_TIER_OWNER=argocd     # app releases become installed:false; Argo owns the app tier
```

Enabling both means Argo's `selfHeal` + `prune` reverts every `helmfile sync` and helmfile
reverts Argo — an infinite loop.

### 6.1 Namespaces first  🟡

```bash
kubectl apply -f platform/bootstrap/manifests/namespaces.yaml
kubectl get ns -L pod-security.kubernetes.io/enforce
```

Creates the namespaces with Pod Security Admission labels. Helm's `--create-namespace` does
**not** label namespaces, so skipping this means PSA is enforced nowhere.

### 6.2 Pull charts + check the render  🟢

```bash
export ENV=prod
helmfile -e $ENV deps                                  # honours */helmfile.lock
helmfile -e $ENV -l layer=platform template > /dev/null && echo OK
```

This is exactly what the CI job `helmfile:lint` does. Do not continue on a dirty render.

### 6.3 Diff before touching the cluster  🟢

```bash
helmfile -e $ENV -l layer=platform diff
```

### 6.4 Sync group by group (first install)  🟡/🔴

The first install **must** be staged — two manifests have to be applied part-way
through. Each folder is its own helmfile state, so a group is just a list of
folders synced in the order the root `helmfile.yaml.gotmpl` lists them.

```bash
sync_group() { for t in "$@"; do helmfile -e "$ENV" -f "platform/$t/helmfile.yaml.gotmpl" sync; done; }

# 1. cluster base — kube-prometheus-stack FIRST: it ships the CRDs everything
#    later references. cluster-autoscaler is off unless ENABLE_CLUSTER_AUTOSCALER=true.
sync_group kube-prometheus-stack metrics-server karpenter cluster-autoscaler reloader keda

# 2. data — minio must exist before mimir/loki/tempo/velero/harbor
sync_group minio postgresql redis kafka clickhouse

# 3. observability — backends before their clients
sync_group loki tempo mimir opensearch opensearch-dashboards \
           opentelemetry-collector alloy grafana

# 4. networking — cert-manager ships the ClusterIssuers via extraObjects
sync_group cert-manager ingress-nginx kong external-dns
kubectl wait --for=condition=Available deploy/cert-manager-webhook -n infra --timeout=180s

#    ⚠ INSERT HERE: Vault's TLS cert. vault mounts the Secret `vault-tls`;
#      without it the Vault pod hangs in ContainerCreating.
kubectl apply -f platform/vault/manifests/certificate.yaml
kubectl wait --for=condition=Ready certificate/vault-tls -n vault --timeout=180s

# 5. security
sync_group vault external-secrets sealed-secrets kyverno trivy-operator falco

# 6. delivery — harbor needs postgres/redis/minio + ingress
sync_group argocd velero harbor
```

On an existing cluster, one command is enough:

```bash
helmfile -e $ENV -l layer=platform sync
```

### 6.5 Policies + NetworkPolicies (after the stack is healthy)  🟡

```bash
kubectl wait --for=condition=Available deploy/kyverno-admission-controller -n infra --timeout=300s
kubectl apply -f platform/kyverno/manifests/policies.yaml
kubectl apply -f platform/kyverno/manifests/policies-supplychain.yaml

kubectl apply -f platform/network-policies/manifests/                   # LAST
```

Most policies are `failureAction: Audit`. Read the reports before enforcing anything:

```bash
kubectl get cpolr        # cluster-scoped
kubectl get polr -A      # namespaced
```

Flip to `Enforce` one rule at a time, starting with the app namespaces.

> **Exception:** `require-trusted-registry` is already **Enforce** for `dev/staging/prod` —
> app images must come from `harbor.*.example.com/*` or `registry.gitlab.com/myorg/*`.

### 6.6 Optional manifests  🟡

```bash
kubectl apply -f platform/karpenter/manifests/nodepool.yaml                      # if using Karpenter
kubectl apply -f platform/external-secrets/manifests/example-secretstore.yaml
helmfile -e $ENV -f platform/kong/helmfile.yaml.gotmpl \
  template --include-crds | kubectl apply -f -                    # Gateway API objects
```

### 6.7 DNS + TLS  🔴

```bash
kubectl -n infra get svc ingress-nginx-controller     # 🟢 get the LB address
# 🔴 point DNS (grafana/argocd/harbor/dashboards/payment/user.<domain>) at it
kubectl get certificate -A                             # 🟢 wait for READY=True
```

ExternalDNS automates this for annotated Ingress/Service objects — see
[platform/external-dns/README.md](../platform/external-dns/README.md).

### 6.8 App tier via helmfile  🟡/🔴

```bash
export APP_TIER_OWNER=helmfile
export IMAGE_TAG=abc1234                 # real image tag
export CHART_PATH=charts/application     # dev only; omit to pull the OCI chart

helmfile -e $ENV -l layer=app diff
helmfile -e $ENV -l layer=app sync

helmfile -e $ENV -l name=be-payment sync   # or a single service
```

### 6.9 Verify  🟢

```bash
helmfile -e $ENV -l layer=platform list
kubectl get pods -A | grep -vE 'Running|Completed'      # should be empty
kubectl get certificate -A
kubectl top nodes                                        # metrics-server alive → HPAs work
kubectl -n $ENV get pods,hpa,ingress,certificate
kubectl -n $ENV rollout status deploy -l app.kubernetes.io/instance=be-payment
```

---

## 7. Path B — Argo CD

Pull model: git is the source of truth and Argo reconciles. CI only (1) validates and
(2) ensures the root Application exists.

### 7.1 Preconditions

Argo CD is installed by the **helmfile path** (release `argocd`, namespace `infra`,
`layer=platform`), so steps 6.1–6.4 in [§6](#6-path-a--helmfile) must be done first.

```bash
kubectl -n infra get deploy argocd-server
```

### 7.2 Hand over the app tier

```bash
export APP_TIER_OWNER=argocd
helmfile -e $ENV -l layer=app sync      # → installed:false, removes the 4 helmfile releases
```

Skipping this makes helmfile and Argo fight over the same Deployments.

### 7.3 Log in

```bash
# dev/staging — the local admin is still enabled
kubectl -n infra get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
argocd login argocd.$INGRESS_DOMAIN --username admin
```

> 🔴 **prod: the local admin is DISABLED** (`admin.enabled: "false"`) and
> `policy.default: role:readonly`. Configure SSO (`dex.config` / `oidc.config`) and map your
> IdP groups in `rbac.policy.csv` **before the first prod sync**, or nobody can log in.
> Recovery: set `admin.enabled: "true"` in `platform/argocd/values.yaml.gotmpl`, re-sync,
> restart `argocd-server`.

### 7.4 Register the repository

```bash
argocd repo add https://gitlab.com/myorg/helm-project-v3.git \
  --username <gitlab-user> --password <deploy-token>
```

Or as a Secret (more GitOps-friendly):

```bash
kubectl -n infra create secret generic gitlab-repo \
  --from-literal=type=git \
  --from-literal=url=https://gitlab.com/myorg/helm-project-v3.git \
  --from-literal=username=<user> \
  --from-literal=password=<token>
kubectl -n infra label secret gitlab-repo argocd.argoproj.io/secret-type=repository
```

### 7.5 Bootstrap the App-of-Apps

```bash
kubectl apply -f ../argocd/bootstrap/appproject-platform.yaml
kubectl apply -f ../argocd/root-app.yaml
kubectl -n infra get applications.argoproj.io
```

`root-app` pulls `bootstrap/` → creates the `platform-apps` ApplicationSet → one Application
per app × env:

```
be-payment-dev  be-payment-staging  be-payment-prod
be-user-dev     be-user-staging     be-user-prod
```

> ❌ Do **not** run `argocd app create <tool> --path release …`. `release/` no longer exists,
> and the platform tools are upstream charts with `.gotmpl` + SOPS values that Argo CD core
> cannot render. Argo CD manages only the **app tier** (`charts/application` + plain values);
> platform tools stay on helmfile.

### 7.6 Sync

```bash
# dev/staging: automated (prune + selfHeal) — nothing to do
argocd app list
argocd app get be-payment-dev

# prod: NOT automated — review, then sync by hand
argocd app diff be-payment-prod
argocd app sync <app>-prod
```

### 7.7 Deploy a new version

Argo cannot read CI variables, so **the image tag is committed to git** — that commit is the
deploy:

```bash
# edit ../applications/<app>/k8s/prod/values.yaml → image.tag: "abc1234"
git commit -am "deploy: <app> abc1234 → prod" && git push
argocd app sync <app>-prod        # prod needs a manual sync
```

---

## 8. Selector reference

Selectors work from `k8s/` across every folder, or scope to a single folder
with `-f platform/<tool>/helmfile.yaml.gotmpl`.

```bash
export ENV=dev
helmfile -e $ENV deps                                                  # once

helmfile -e $ENV -l name=<x> diff        # 🟢 preview            ← ALWAYS first
helmfile -e $ENV -l name=<x> template    # 🟢 render, no cluster
helmfile -e $ENV -l name=<x> sync        # 🟡 install/upgrade
helmfile -e $ENV -l name=<x> apply       # 🟡 sync only if changed
helmfile -e $ENV -l name=<x> status      # 🟢
helmfile -e $ENV -l name=<x> destroy     # 🔴 remove
```

> ⚠ **Do not use `-n <ns>`** to "choose the deploy namespace" — that is a different flag and
> easy to misuse. Namespaces are declared per release. Filter with `-l` only.

`-l name=X sync` installs **only** X. Its dependencies must already exist, or pull them in:

```bash
helmfile -e $ENV -l name=opentelemetry-collector sync --include-needs
```

Group selectors:

```bash
helmfile -e $ENV -l layer=platform sync      # 32 platform releases
helmfile -e $ENV -l layer=app sync           # 4 app releases
helmfile -e $ENV -l tier=backend sync        # be-payment, be-user
helmfile -e $ENV -l component=logs sync      # loki + alloy
helmfile -e $ENV -l component=traces sync    # tempo + opentelemetry-collector
helmfile -e $ENV -l component=metrics sync   # kps + mimir + grafana + metrics-server
helmfile -e $ENV -l component=secrets sync   # vault + external-secrets + sealed-secrets
helmfile -e $ENV -l component=search sync    # opensearch + dashboards

helmfile -e $ENV -l name=loki -l name=tempo sync    # multiple selectors = OR
helmfile -e $ENV -l 'name!=karpenter' sync          # exclusion (on-prem)
```

Available `component` labels: `metrics, logs, traces, search, storage, database, cache,
streaming, analytics, tls, ingress, gateway, dns, secrets, policy, security, delivery,
backup, registry, autoscaling, platform`.

---

## 9. Day-2 operations

**Upgrade one tool**

```bash
# bump `version:` for that release in <domain>/helmfile.yaml.gotmpl, then:
helmfile -e $ENV -l name=<tool> diff
helmfile -e $ENV -l name=<tool> apply
```

Read the tool's own `README.md` first — several have CRD or topology caveats
(kube-prometheus-stack, Loki, Mimir, OpenSearch, Harbor).

**Deploy a new app version**

```bash
IMAGE_TAG=<new> helmfile -e $ENV -l name=be-payment apply
```

**Rotate a secret**

```bash
sops secrets/$ENV.yaml                       # edit → saved re-encrypted
helmfile -e $ENV -l name=be-payment apply    # Reloader rolls the pods when the Secret changes
```

**Add a new service**

```bash
cp -r be-user be-order                       # skeleton: helmfile + values
# edit apps/be-order/helmfile.yaml.gotmpl (name + labels) and apps/be-order/values.yaml.gotmpl
# optional: apps/be-order/config/{common,dev,staging,prod}.yaml, apps/be-order/secrets.yaml.gotmpl
# then add `- path: apps/be-order/helmfile.yaml.gotmpl` to the root helmfile include list
helmfile -e $ENV -l name=be-order sync
```

> ⚠ App releases use `missingFileHandler: Error`, and `charts/application` has no default
> for `image.repository` — a missing or mistyped values file fails the render instead of
> deploying something unintended. Tool releases still use `Warn`, so for those the values
> file must exist **before** you add the release.

**Rollback**  🔴

`helmDefaults` sets `atomic: false` and `cleanupOnFail: false` deliberately, so a failed
release is left in place for inspection — **nothing rolls back automatically.**

```bash
helm history be-payment -n $ENV
helm rollback be-payment <REVISION> -n $ENV --wait --timeout 5m
```

Under Argo CD:

```bash
argocd app history be-payment-prod
argocd app rollback be-payment-prod <ID>
# or, more GitOps-correct: git revert the tag commit, then sync
```

In CI there is a manual `deploy:rollback` job (optional `ROLLBACK_REVISION`).

Stateful releases have extra rollback constraints (PVCs, schema migrations, ring topology) —
always read that component's `README.md` before rolling back
`postgresql`, `kafka`, `clickhouse`, `opensearch`, `loki`, `mimir`, `vault` or `harbor`.

**Argo CD operations**

```bash
kubectl -n infra port-forward svc/argocd-server 8080:443     # UI → https://localhost:8080
argocd login localhost:8080 --username admin --insecure
kubectl -n infra exec -it deploy/argocd-server -- /bin/sh    # distroless → sh, not bash
helm uninstall argocd -n infra                               # clean removal incl. cluster RBAC
```

---

## 10. Component index

Every component has a `README.md` next to its values file: prerequisites, configuration map,
deploy, verify, rollback, monitoring/alerting, troubleshooting.

### Cluster base

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| bootstrap (namespaces + netpol) | raw manifests | — | [bootstrap](../platform/bootstrap/README.md) |
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` 87.19.1 | `observability` | [kube-prometheus-stack](../../monitoring/kube-prometheus-stack/README.md) |
| metrics-server | `metrics-server/metrics-server` 3.13.1 | `kube-system` | [metrics-server](../platform/metrics-server/README.md) |
| karpenter | `oci://public.ecr.aws/karpenter/karpenter` 1.14.0 | `kube-system` | [karpenter](../platform/karpenter/README.md) |
| cluster-autoscaler | `autoscaler/cluster-autoscaler` 9.46.6 | `kube-system` | [cluster-autoscaler](../platform/cluster-autoscaler/README.md) |
| reloader | `stakater/reloader` 2.2.14 | `kube-system` | [reloader](../platform/reloader/README.md) |
| keda | `kedacore/keda` 2.17.0 | `keda` | [keda](../platform/keda/README.md) |

### Data — stateful stores

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| minio | `minio/minio` 5.4.0 | `database` | [minio](../platform/minio/README.md) |
| postgresql | `bitnami/postgresql` 16.7.4 | `database` | [postgresql](../platform/postgresql/README.md) |
| redis | `bitnami/redis` 20.11.3 | `database` | [redis](../platform/redis/README.md) |
| kafka | `bitnami/kafka` 32.2.10 | `database` | [kafka](../platform/kafka/README.md) |
| clickhouse | `bitnami/clickhouse` 9.4.4 | `database` | [clickhouse](../platform/clickhouse/README.md) |

### Observability — logs, traces, dashboards

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| loki | `grafana/loki` 7.1.0 | `observability` | [loki](../../monitoring/loki/README.md) |
| tempo | `grafana/tempo` 1.24.4 | `observability` | [tempo](../../monitoring/tempo/README.md) |
| mimir | `grafana/mimir-distributed` 5.7.0 | `observability` | [mimir](../../monitoring/mimir/README.md) |
| opentelemetry-collector | `open-telemetry/opentelemetry-collector` 0.165.0 | `observability` | [opentelemetry-collector](../../monitoring/opentelemetry-collector/README.md) |
| alloy | `grafana/alloy` 1.11.0 | `observability` | [alloy](../../monitoring/alloy/README.md) |
| opensearch | `opensearch/opensearch` 3.7.0 | `observability` | [opensearch](../platform/opensearch/README.md) |
| opensearch-dashboards | `opensearch/opensearch-dashboards` 3.7.0 | `observability` | [opensearch-dashboards](../platform/opensearch-dashboards/README.md) |
| grafana | `grafana/grafana` 8.15.0 | `observability` | [grafana](../../monitoring/grafana/README.md) |

### Networking — ingress, TLS, DNS, gateway

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| cert-manager | `jetstack/cert-manager` v1.21.0 | `infra` | [cert-manager](../platform/cert-manager/README.md) |
| ingress-nginx | `ingress-nginx/ingress-nginx` 4.15.1 | `infra` | [ingress-nginx](../platform/ingress-nginx/README.md) |
| kong | `kong/kong` 2.51.0 | `infra` | [kong](../platform/kong/README.md) |
| external-dns | `external-dns/external-dns` 1.16.1 | `infra` | [external-dns](../platform/external-dns/README.md) |
| gateway-api | raw manifest (no chart) | `infra` | [gateway-api](../platform/gateway-api/README.md) |

### Security

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| vault | `hashicorp/vault` 0.30.0 | `vault` | [vault](../platform/vault/README.md) |
| external-secrets | `external-secrets/external-secrets` 2.8.0 | `infra` | [external-secrets](../platform/external-secrets/README.md) |
| sealed-secrets | `sealed-secrets/sealed-secrets` 2.17.0 | `infra` | [sealed-secrets](../platform/sealed-secrets/README.md) |
| kyverno | `kyverno/kyverno` 3.8.2 | `infra` | [kyverno](../platform/kyverno/README.md) |
| trivy-operator | `aqua/trivy-operator` 0.34.0 | `trivy-system` | [trivy-operator](../platform/trivy-operator/README.md) |
| falco | `falcosecurity/falco` 6.0.0 | `falco` | [falco](../platform/falco/README.md) |

### Delivery

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| argocd | `argo/argo-cd` 7.8.0 | `infra` | [argocd](../platform/argocd/README.md) |
| velero | `vmware-tanzu/velero` 12.1.0 | `velero` | [velero](../platform/velero/README.md) |
| harbor | `harbor/harbor` 1.17.0 | `harbor` | [harbor](../platform/harbor/README.md) |

### Applications (`charts/application`)

| Component | Ingress | Namespace | Doc |
|---|---|---|---|
| **overview / ownership switch** | — | — | [APPS.md](APPS.md) |
| be-payment | `payment.<domain>` | `<env>` | [be-payment](../apps/be-payment/README.md) |
| be-user | `user.<domain>` | `<env>` | [be-user](../apps/be-user/README.md) |

### Decisions to make once per cluster

| Decision | Controlled by | Detail |
|---|---|---|
| App-tier owner: helmfile **or** Argo CD | `APP_TIER_OWNER` | [APPS.md](APPS.md) |
| Node autoscaler: Karpenter **or** cluster-autoscaler | `ENABLE_CLUSTER_AUTOSCALER` | [karpenter](../platform/karpenter/README.md) |
| Bitnami images: docker.io **or** Harbor mirror | `global.imageRegistry` | [postgresql](../platform/postgresql/README.md) |
| Secrets: SOPS / Sealed Secrets / ESO+Vault | per secret | [sealed-secrets](../platform/sealed-secrets/README.md) |
| Argo CD prod access: SSO **before** first sync | `platform/argocd/values.yaml.gotmpl` | [argocd](../platform/argocd/README.md) |

### Known gaps

- **Mimir has no Grafana datasource** — metrics are written but not queryable.
- **Kafka listeners are `SASL_PLAINTEXT`** — authenticated, not encrypted.
- **OpenSearch ships demo TLS certs + default admin password** — replace for staging/prod.
- **`<ACCOUNT_ID>` / `my-eks-<env>` placeholders** in karpenter, cluster-autoscaler,
  external-dns and velero must be replaced before those releases work.

---

## 11. Common traps

| Symptom | Cause |
|---|---|
| `[helm-secrets] File is not encrypted` | `env-values/<env>/secrets.enc.yaml` is not SOPS-encrypted |
| `no identity matched any of the recipients` | `SOPS_AGE_KEY_FILE` wrong or unset |
| `403 denied` pulling the OCI chart | no `helm registry login` to ECR, or wrong `HELM_CHART_ACCOUNT_ID` |
| `no matches for kind "ServiceMonitor"` | `kube-prometheus-stack` not synced first (CRDs missing) |
| Vault pod stuck `ContainerCreating` | step 7 skipped — `vault-tls` Secret missing |
| Vault running but `sealed` | `VAULT_KMS_KEY_ID` unset → no seal stanza rendered |
| Harbor core `CrashLoopBackOff` on the DB | step 11 skipped, or the `database` NetworkPolicy blocks ns `harbor` |
| App cannot reach DB/Redis | missing `allow-apps-ingress` (step 11) or egress rules in `env-values/<env>/app-values.yaml.gotmpl` |
| Ingress returns an SSL error | the service declares `hosts` but no `tls` block in `<svc>/values.yaml.gotmpl` |
| ACME challenge stuck `pending` | ClusterIssuer solver ingress class does not match the env |
| Pod rejected: untrusted registry | `require-trusted-registry` is **Enforce** — push the image to Harbor |
| Argo reverts a helmfile change | both owners active — see [§6.0](#60-choose-the-app-tier-owner) |
| `helmfile sync` hangs on one release | `wait: true` waiting for pods; `kubectl -n <ns> get pods` → find the Pending pod (PVC/quota/image) |
| HPA shows `unknown/<target>` | metrics-server down, or the workload declares no resource requests |
| Webhook timeout on `kubectl apply` | a default-deny NetworkPolicy was applied to `infra` (never do this) |

Deeper diagnosis and past incidents: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 12. Quick reference

```bash
# state
helmfile -e $ENV list                                    # all releases + labels
helmfile -e $ENV -l name=<x> template                    # render without touching the cluster
kubectl get pods -A | grep -vE 'Running|Completed'       # should be empty
kubectl get certificate,ingress -A
kubectl top nodes && kubectl top pods -A --sort-by=memory | head

# environment differences
```

| | dev | staging | prod |
|---|---|---|---|
| Scale | 1 replica | 2 replicas + persistence | HA + HPA + PDB |
| TLS | LE staging / self-signed | LE staging | **LE prod** |
| Secrets | SOPS | SOPS / ESO | **ESO (Vault / AWS SM)** |
| Policy | Audit | Audit | Audit → **Enforce** once reports are clean |
| Ingress class | `nginx-dev` | `nginx-staging` | `nginx-prod` |
| Argo sync | automated | automated | **manual** |

Handy aliases (`~/.zshrc`):

```bash
alias k='kubectl'
alias kga='kubectl get pod -A'
alias kli='kubectl logs -n infra'            # argocd, cert-manager, ingress, vault...
alias klo='kubectl logs -n observability'    # grafana, loki, tempo, prometheus...
alias kdi='kubectl describe -n infra'
alias kdo='kubectl describe -n observability'
```
