# DEPLOY — platform tier reference

Reference for the **platform tier** (`layer=platform`, 32 releases under `kubernetes/releases/`):
prerequisites, deploy order, selectors, day-2 operations, the per-tool index and the common traps.

- Step by step for a whole cluster (namespaces → platform → apps), verify, rollback:
  [`docs/20-runbooks/kubernetes-manual.md`](../../docs/20-runbooks/kubernetes-manual.md).
- Applications are **not** here: they are `applications/<app>/k8s/<env>/values.yaml`, released from the
  repository root with `helmfile -e <env> -l name=<app> diff|sync` (guarded by `scripts/deploy/release-guard.sh`).
- Per-tool detail (prereqs, verify, rollback, alerts): the `README.md` in each tool folder — [§8](#8-component-index).
- Incident history: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**Commands below run from `kubernetes/`** and need `--kube-context <ctx>` on everything that touches a
cluster: no platform helmfile pins a context, so without it helm uses the kubeconfig current-context.
Groupings like "data" or "observability" are ordering groups, not directories. Argo CD runs in
namespace **`infra`**, not `argocd`.

---

## Contents

| § | |
|---|---|
| [1](#1-what-gets-deployed) | What gets deployed |
| [2](#2-prerequisites) | Prerequisites — tools, keys, env vars |
| [3](#3-approval-gates-ai-driven-runs) | Approval gates (AI-driven runs) |
| [4](#4-deploy-order) | Deploy order |
| [5](#5-helmfile-path) | Helmfile path — first install, policies, DNS/TLS, verify |
| [6](#6-selector-reference) | Selector reference |
| [7](#7-day-2-operations) | Day-2 operations |
| [8](#8-component-index) | Component index |
| [9](#9-common-traps) | Common traps |
| [10](#10-quick-reference) | Quick reference |

---

## 1. What gets deployed

**32 platform releases** (`layer=platform`), each its own helmfile state under
`releases/{platform,observability}/<tool>/`, listed in install order in `helmfile.yaml.gotmpl`.
`karpenter` / `cluster-autoscaler` follow `nodeAutoscaler`, `ingress-nginx` follows `ingressNginx`
in `environments/<env>/kubernetes/state.yaml` (`installed: false` otherwise — a sync uninstalls them).

Two manifest sets are applied with `kubectl`, not helmfile, because helmfile ordering
cannot express them: `environments/<env>/kubernetes/namespace/namespaces.yaml` (**first**) and
`environments/<env>/kubernetes/network/` (**last**).

The app tier (the in-house `charts/application`) has exactly one owner per cluster — manual
Helmfile from `applications/`, or Argo CD (`../argocd/`). Never both.

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

```bash
# macOS
brew install helm helmfile sops age kubectl awscli
helm plugin install https://github.com/jkroepke/helm-secrets
helm plugin install https://github.com/databus23/helm-diff
```

Verify: `helm version && helmfile --version && sops --version && kubectl version --client`

### 2.2 SOPS key

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt        # the key of THAT environment
sops filestatus ../environments/<env>/kubernetes/secrets.enc.yaml   # {"encrypted":true} — never print the plaintext
```

In CI the protected variable `SOPS_AGE_PRIVATE_KEY_<ENV>` is written to a file by the `.sops-setup` anchor.

### 2.3 Kubeconfig

```bash
aws eks update-kubeconfig --name platform-<env>-eks --region ap-southeast-1 --alias <alias>
kubectl --context=<alias> cluster-info          # confirm the intended cluster; pass --context everywhere
```

### 2.4 Environment variables

| Variable | Required when | Notes |
|---|---|---|
| `SOPS_AGE_KEY_FILE` | **always** | missing → helmfile fails while reading the environment |
| `AWS_ACCOUNT_ID` | postgresql, redis, kafka, clickhouse, velero, external-dns, karpenter, cluster-autoscaler | `requiredEnv` — ECR mirror host and IRSA ARNs |
| `AWS_REGION` | optional | default `ap-southeast-1` |
| `VAULT_KMS_KEY_ID` | prod | missing → Vault starts **sealed** |
| `ACME_EMAIL` | optional | default `platform@example.com` |

### 2.5 Cloud prerequisites

- S3 bucket for Velero: `<platformName>-velero-<account>` (created by `terraform/stacks/core`).
- IRSA roles `<eksClusterName>-irsa-<addon>` for external-dns, velero, karpenter, cluster-autoscaler
  (created by `terraform/stacks/core`).
- Karpenter also needs an SQS interruption queue and `karpenter.sh/discovery=<clusterName>` tags.
- A DNS zone matching `ingressDomain` in `environments/<env>/kubernetes/state.yaml`.

---

## 3. Approval gates (AI-driven runs)

Both humans and AI agents can follow this document. The difference: **an AI must request
human approval at every gated step.**

| Label | Meaning | AI allowed? |
|---|---|---|
| 🟢 **AUTO** | read-only / render-only, never touches a real cluster | ✅ runs on its own |
| 🟡 **APPROVE** | writes to a cluster, creates secrets, encrypts | ⚠️ must ask a human **before each run** |
| 🔴 **PROD / DESTRUCTIVE** | touches `prod`, `destroy`, `rollback`, DNS changes | ⛔ human only, or approve command by command |

Rules for AI:

1. Always run the 🟢 `diff` / `template` step first and show the output to the human.
2. Only run 🟡/🔴 after an explicit `APPROVE`.
3. Never invent or change real secret values. Never change DNS. Never `destroy`.
4. Each 🟡/🔴 command needs its **own** approval — approving one does not imply the next.

| Command | Gate |
|---|---|
| `helmfile repos / template / diff / lint / list`, `helm search`, `kubectl get/top/describe/logs` | 🟢 |
| `helmfile -e dev\|staging sync`, `kubectl apply`, `sops -e` | 🟡 |
| anything `-e prod`, `rollback`, `destroy`, `kubectl delete`, DNS changes, filling real secrets | 🔴 |

Humans: ignore the labels and run the steps in order.

---

## 4. Deploy order

Every tool is a **separate state**, so `needs` does **not** work across tools — the include order
in `helmfile.yaml.gotmpl` *is* the dependency order:

```
cluster base  →  networking  →  data  →  observability  →  security  →  delivery
```

| # | Step | Command | Required |
|---|---|---|---|
| 1 | Namespaces + PSA | `kubectl --context=<ctx> apply -f ../environments/<env>/kubernetes/namespace/` | ✅ |
| 2 | Repos + render check | `helmfile -e $ENV repos && helmfile -e $ENV -l layer=platform template` | ✅ |
| 3–8 | cluster base → networking → data → observability → security → delivery | §5.4 | ✅ |
| 6a | Vault TLS cert (before security) | `kubectl --context=<ctx> apply -f releases/platform/vault/manifests/certificate.yaml` | staging/prod |
| 9 | Kyverno policies | `kubectl --context=<ctx> apply -f releases/platform/kyverno/manifests/` | recommended |
| 10 | NetworkPolicies | `kubectl --context=<ctx> apply -f ../environments/<env>/kubernetes/network/` | recommended |

Why this order: `prometheus-operator-crds` ships the ServiceMonitor/PrometheusRule CRDs everything else needs
(kube-prometheus-stack runs with `crds.enabled: false`);
`kong` comes before every tool with an Ingress (class `kong`); `minio` before mimir and harbor;
Harbor needs Postgres/Redis/MinIO + ingress. Apps come after this list (Kong, metrics-server).

---

## 5. Helmfile path

### 5.1 Namespaces first  🟡

```bash
kubectl --context=<ctx> apply -f ../environments/<env>/kubernetes/namespace/
kubectl --context=<ctx> get ns -L pod-security.kubernetes.io/enforce
```

Helm's `--create-namespace` does **not** label namespaces, so skipping this means PSA is enforced nowhere.

### 5.2 Pull charts + check the render  🟢

```bash
export ENV=dev
helmfile -e $ENV repos
helmfile -e $ENV -l layer=platform template > /dev/null && echo OK
```

This is what the CI job `helmfile:lint` does. Do not continue on a dirty render. Do not run
`helmfile deps` locally: it writes a `helmfile.lock` into every tool folder.

### 5.3 Diff before touching the cluster  🟢

```bash
helmfile -e $ENV --kube-context <ctx> -l layer=platform diff
```

### 5.4 Sync group by group (first install)  🟡/🔴

The first install **must** be staged — one manifest has to be applied part-way through.
A group is a list of tool folders synced in the order `helmfile.yaml.gotmpl` lists them.

```bash
sync_tool() { helmfile -e "$ENV" --kube-context "$CTX" -f "releases/$1/helmfile.yaml.gotmpl" sync; }
sync_group() { g=$1; shift; for t in "$@"; do sync_tool "$g/$t"; done; }

# 1. cluster base — prometheus-operator-crds FIRST (CRDs). karpenter / cluster-autoscaler per nodeAutoscaler.
sync_group observability prometheus-operator-crds kube-prometheus-stack
sync_group platform metrics-server karpenter cluster-autoscaler reloader keda

# 2. networking — before every tool with an Ingress (class kong + Kong's KongClusterPlugins).
#    ingress-nginx is legacy: installed only while ingressNginx: true (releases/platform/kong/README.md §8).
sync_group platform cert-manager ingress-nginx kong external-dns
kubectl --context="$CTX" -n infra wait --for=condition=Available deploy/cert-manager-webhook --timeout=180s

# 3. data — minio before mimir/velero/harbor
sync_group platform minio postgresql redis kafka clickhouse

# 4. observability — backends before their clients
sync_group observability loki tempo mimir
sync_group platform opensearch opensearch-dashboards
sync_group observability opentelemetry-collector alloy grafana

#    ⚠ INSERT HERE (staging/prod): Vault's TLS cert. vault mounts the Secret `vault-tls`;
#      without it the Vault pod hangs in ContainerCreating.
kubectl --context="$CTX" apply -f releases/platform/vault/manifests/certificate.yaml
kubectl --context="$CTX" -n vault wait --for=condition=Ready certificate/vault-tls --timeout=180s

# 5. security
sync_group platform vault external-secrets sealed-secrets kyverno trivy-operator falco

# 6. delivery — harbor needs postgres/redis/minio + ingress
sync_group platform argocd velero harbor
```

On an existing cluster, one command is enough:

```bash
helmfile -e $ENV --kube-context <ctx> -l layer=platform sync
```

### 5.5 Policies + NetworkPolicies (after the stack is healthy)  🟡

```bash
kubectl --context=<ctx> -n infra wait --for=condition=Available deploy/kyverno-admission-controller --timeout=300s
kubectl --context=<ctx> apply -f releases/platform/kyverno/manifests/policies.yaml
kubectl --context=<ctx> apply -f releases/platform/kyverno/manifests/policies-supplychain.yaml

kubectl --context=<ctx> apply -f ../environments/<env>/kubernetes/network/                   # LAST
```

Most policies are `failureAction: Audit`. Read the reports before enforcing anything:

```bash
kubectl --context=<ctx> get cpolr        # cluster-scoped
kubectl --context=<ctx> get polr -A      # namespaced
```

Flip to `Enforce` one rule at a time, starting with the app namespaces.

> **Exception:** `require-trusted-registry` is already **Enforce** for `dev/staging/prod` —
> app images must come from `harbor.*.example.com/*` or `registry.gitlab.com/myorg/*`.

### 5.6 Optional manifests  🟡

```bash
kubectl --context=<ctx> apply -f releases/platform/karpenter/manifests/nodepool.yaml             # if using Karpenter
kubectl --context=<ctx> apply -f releases/platform/external-secrets/manifests/example-secretstore.yaml
# Gateway API objects: releases/platform/gateway-api/README.md
```

### 5.7 DNS + TLS  🔴

```bash
kubectl --context=<ctx> -n infra get svc kong-proxy        # 🟢 the LB address (Kong is the ingress)
# 🔴 point DNS (grafana/argocd/harbor/dashboards.<domain>) at it — or let external-dns do it
kubectl --context=<ctx> get certificate -A                  # 🟢 wait for READY=True
```

ExternalDNS automates this for annotated Ingress/Service objects — see
[releases/platform/external-dns/README.md](../releases/platform/external-dns/README.md).

### 5.8 Verify  🟢

```bash
helm --kube-context <ctx> list -A
kubectl --context=<ctx> get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded   # should be empty
kubectl --context=<ctx> get certificate -A
kubectl --context=<ctx> top nodes                            # metrics-server alive → HPAs work
```

### 5.9 Argo CD (app tier owner, optional)

Argo CD itself is a platform release (`argocd`, ns `infra`). Making it the owner of the app tier —
bootstrap, repository registration, SSO for prod, sync — is in
[`../argocd/README.md`](../argocd/README.md) and [releases/platform/argocd/README.md](../releases/platform/argocd/README.md).
Platform tools stay on helmfile: they are upstream charts with `.gotmpl` + SOPS values that Argo CD
core cannot render.

---

## 6. Selector reference

From `kubernetes/` across every tool, or scoped to one with `-f releases/<group>/<tool>/helmfile.yaml.gotmpl`.
Add `--kube-context <ctx>` to every command that reaches a cluster.

```bash
helmfile -e $ENV -l name=<x> diff        # 🟢 preview            ← ALWAYS first
helmfile -e $ENV -l name=<x> template    # 🟢 render, no cluster
helmfile -e $ENV -l name=<x> sync        # 🟡 install/upgrade
helmfile -e $ENV -l name=<x> apply       # 🟡 sync only if changed
helmfile -e $ENV -l name=<x> status      # 🟢
helmfile -e $ENV -l name=<x> destroy     # 🔴 remove
```

> ⚠ **Do not use `-n <ns>`** to "choose the deploy namespace" — namespaces are declared per release.
> Filter with `-l` only.

`-l name=X sync` installs **only** X; helmfile does not install what X depends on (no `needs:` across
tools). Prerequisites per tool: [kubernetes-manual.md P2](../../docs/20-runbooks/kubernetes-manual.md#p2-deploy-riêng-một-tool--cần-gì-trước).

Group selectors:

```bash
helmfile -e $ENV -l layer=platform sync      # all 32 platform releases
helmfile -e $ENV -l component=logs sync      # loki + alloy
helmfile -e $ENV -l component=traces sync    # tempo + opentelemetry-collector
helmfile -e $ENV -l component=metrics sync   # kps + mimir + grafana + metrics-server
helmfile -e $ENV -l component=secrets sync   # vault + external-secrets + sealed-secrets
helmfile -e $ENV -l component=search sync    # opensearch + dashboards

helmfile -e $ENV -l name=loki -l name=tempo sync    # multiple selectors = OR
helmfile -e $ENV -l 'name!=karpenter' sync          # exclusion
```

Available `component` labels: `metrics, logs, traces, search, storage, database, cache,
streaming, analytics, tls, ingress, gateway, dns, secrets, policy, security, delivery,
backup, registry, autoscaling, platform`.

---

## 7. Day-2 operations

**Upgrade one tool**

```bash
# bump `version:` in releases/<group>/<tool>/helmfile.yaml.gotmpl (reaches every environment), then:
helmfile -e $ENV --kube-context <ctx> -l name=<tool> diff
helmfile -e $ENV --kube-context <ctx> -l name=<tool> apply
```

Read the tool's own `README.md` first — several have CRD or topology caveats
(kube-prometheus-stack, Loki, Mimir, OpenSearch, Harbor).

**Change a tool's values** — edit `../environments/<env>/kubernetes/{tools,ingress,monitoring}/<tool>/`
of that environment, then diff → apply as above.

**Rollback**  🔴

`helmDefaults` sets `atomic: false` and `cleanupOnFail: false` deliberately, so a failed
release is left in place for inspection — **nothing rolls back automatically.**

```bash
helm --kube-context <ctx> -n <ns> history <tool>
helm --kube-context <ctx> -n <ns> rollback <tool> <REVISION> --wait --timeout 5m
```

Then revert the git change, or the next sync brings it back. Stateful releases have extra rollback
constraints (PVCs, schema migrations, ring topology) — always read that component's `README.md`
before rolling back `postgresql`, `kafka`, `clickhouse`, `opensearch`, `loki`, `mimir`, `vault` or `harbor`.

**Argo CD operations**

```bash
kubectl --context=<ctx> -n infra port-forward svc/argocd-server 8080:443     # UI → https://localhost:8080
argocd login localhost:8080 --username admin --insecure
```

---

## 8. Component index

Every component has a `README.md` in its tool folder: prerequisites, configuration map,
deploy, verify, rollback, monitoring/alerting, troubleshooting.

### Cluster base

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| namespaces + PSA, NetworkPolicies | raw manifests | — | [NAMESPACES](NAMESPACES.md), [NETWORK-POLICIES](NETWORK-POLICIES.md) |
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` 87.19.1 | `observability` | [kube-prometheus-stack](../releases/observability/kube-prometheus-stack/README.md) |
| metrics-server | `metrics-server/metrics-server` 3.13.1 | `kube-system` | [metrics-server](../releases/platform/metrics-server/README.md) |
| karpenter | `oci://public.ecr.aws/karpenter/karpenter` 1.14.0 | `kube-system` | [karpenter](../releases/platform/karpenter/README.md) |
| cluster-autoscaler | `autoscaler/cluster-autoscaler` 9.46.6 | `kube-system` | [cluster-autoscaler](../releases/platform/cluster-autoscaler/README.md) |
| reloader | `stakater/reloader` 2.2.14 | `kube-system` | [reloader](../releases/platform/reloader/README.md) |
| keda | `kedacore/keda` 2.17.0 | `keda` | [keda](../releases/platform/keda/README.md) |

### Data — stateful stores

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| minio | `minio/minio` 5.4.0 | `database` | [minio](../releases/platform/minio/README.md) |
| postgresql | `bitnami/postgresql` 16.7.4 | `database` | [postgresql](../releases/platform/postgresql/README.md) |
| redis | `bitnami/redis` 20.11.3 | `database` | [redis](../releases/platform/redis/README.md) |
| kafka | `bitnami/kafka` 32.2.10 | `database` | [kafka](../releases/platform/kafka/README.md) |
| clickhouse | `bitnami/clickhouse` 9.4.4 | `database` | [clickhouse](../releases/platform/clickhouse/README.md) |

### Observability — logs, traces, dashboards

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| loki | `grafana/loki` 7.1.0 | `observability` | [loki](../releases/observability/loki/README.md) |
| tempo | `grafana/tempo` 1.24.4 | `observability` | [tempo](../releases/observability/tempo/README.md) |
| mimir | `grafana/mimir-distributed` 5.7.0 | `observability` | [mimir](../releases/observability/mimir/README.md) |
| opentelemetry-collector | `open-telemetry/opentelemetry-collector` 0.165.0 | `observability` | [opentelemetry-collector](../releases/observability/opentelemetry-collector/README.md) |
| alloy | `grafana/alloy` 1.11.0 | `observability` | [alloy](../releases/observability/alloy/README.md) |
| opensearch | `opensearch/opensearch` 3.7.0 | `observability` | [opensearch](../releases/platform/opensearch/README.md) |
| opensearch-dashboards | `opensearch/opensearch-dashboards` 3.7.0 | `observability` | [opensearch-dashboards](../releases/platform/opensearch-dashboards/README.md) |
| grafana | `grafana/grafana` 8.15.0 | `observability` | [grafana](../releases/observability/grafana/README.md) |

### Networking — ingress, TLS, DNS, gateway

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| cert-manager | `jetstack/cert-manager` v1.21.0 | `infra` | [cert-manager](../releases/platform/cert-manager/README.md) |
| ingress-nginx (legacy, `ingressNginx` toggle) | `ingress-nginx/ingress-nginx` 4.15.1 | `infra` | [ingress-nginx](../releases/platform/ingress-nginx/README.md) |
| kong — the ingress controller (class `kong`) | `kong/kong` 2.51.0 | `infra` | [kong](../releases/platform/kong/README.md) |
| external-dns | `external-dns/external-dns` 1.16.1 | `infra` | [external-dns](../releases/platform/external-dns/README.md) |
| gateway-api | raw manifest (no chart) | `infra` | [gateway-api](../releases/platform/gateway-api/README.md) |

### Security

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| vault | `hashicorp/vault` 0.30.0 | `vault` | [vault](../releases/platform/vault/README.md) |
| external-secrets | `external-secrets/external-secrets` 2.8.0 | `infra` | [external-secrets](../releases/platform/external-secrets/README.md) |
| sealed-secrets | `sealed-secrets/sealed-secrets` 2.17.0 | `infra` | [sealed-secrets](../releases/platform/sealed-secrets/README.md) |
| kyverno | `kyverno/kyverno` 3.8.2 | `infra` | [kyverno](../releases/platform/kyverno/README.md) |
| trivy-operator | `aqua/trivy-operator` 0.34.0 | `trivy-system` | [trivy-operator](../releases/platform/trivy-operator/README.md) |
| falco | `falcosecurity/falco` 6.0.0 | `falco` | [falco](../releases/platform/falco/README.md) |

### Delivery

| Component | Chart / version | Namespace | Doc |
|---|---|---|---|
| argocd | `argo/argo-cd` 7.8.0 | `infra` | [argocd](../releases/platform/argocd/README.md) |
| velero | `vmware-tanzu/velero` 12.1.0 | `velero` | [velero](../releases/platform/velero/README.md) |
| harbor | `harbor/harbor` 1.17.0 | `harbor` | [harbor](../releases/platform/harbor/README.md) |

### Decisions to make once per cluster

| Decision | Controlled by | Detail |
|---|---|---|
| App-tier owner: helmfile **or** Argo CD | `delivery.owner` in `environments/<env>/kubernetes/cluster/<cluster>.yaml` | [kubernetes-manual.md B4](../../docs/20-runbooks/kubernetes-manual.md#b4-application) |
| Node autoscaler: Karpenter **or** cluster-autoscaler | `nodeAutoscaler` in `environments/<env>/kubernetes/state.yaml` | [karpenter](../releases/platform/karpenter/README.md) |
| Bitnami images: ECR mirror **or** Harbor | `global.imageRegistry` | [postgresql](../releases/platform/postgresql/README.md) |
| Secrets: SOPS / Sealed Secrets / ESO+Vault | per secret | [sealed-secrets](../releases/platform/sealed-secrets/README.md) |
| Argo CD prod access: SSO **before** first sync | `environments/prod/kubernetes/tools/argocd/values.yaml.gotmpl` | [argocd](../releases/platform/argocd/README.md) |

### Known gaps

- **Mimir has no Grafana datasource** — metrics are written but not queryable.
- **Kafka listeners are `SASL_PLAINTEXT`** — authenticated, not encrypted.
- **OpenSearch ships demo TLS certs + default admin password** — replace for staging/prod.

---

## 9. Common traps

| Symptom | Cause |
|---|---|
| `[helm-secrets] File is not encrypted` | `environments/<env>/kubernetes/secrets.enc.yaml` is not SOPS-encrypted |
| `no identity matched any of the recipients` | `SOPS_AGE_KEY_FILE` wrong or unset |
| `no matches for kind "ServiceMonitor"` | `prometheus-operator-crds` not synced first (CRDs missing) |
| first `diff` of kong: `no matches for kind "KongClusterPlugin"` | the chart's CRDs are not installed yet — `diff --diff-args '--disable-validation'` |
| Vault pod stuck `ContainerCreating` | the Vault TLS cert step was skipped — `vault-tls` Secret missing |
| Vault running but `sealed` | `VAULT_KMS_KEY_ID` unset → no seal stanza rendered |
| Harbor core `CrashLoopBackOff` on the DB | NetworkPolicies missing, or the `database` NetworkPolicy blocks ns `harbor` |
| ACME challenge stuck `pending` | ClusterIssuer solver ingress class does not match the env |
| Pod rejected: untrusted registry | `require-trusted-registry` is **Enforce** — push the image to Harbor |
| `helmfile sync` hangs on one release | `wait: true` waiting for pods or a LoadBalancer address; `kubectl -n <ns> get pods,svc` → find the Pending pod (PVC/quota/image) or `<pending>` Service |
| HPA shows `unknown/<target>` | metrics-server down, or the workload declares no resource requests |
| Webhook timeout on `kubectl apply` | a default-deny NetworkPolicy was applied to `infra` (never do this) |

More, including local clusters: [kubernetes-manual.md C8](../../docs/20-runbooks/kubernetes-manual.md#c8-lỗi-thường-gặp).
Deeper diagnosis and past incidents: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 10. Quick reference

```bash
helmfile -e $ENV -l layer=platform list                          # releases + labels
helmfile -e $ENV -l name=<x> template                            # render without touching the cluster
kubectl --context=<ctx> get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl --context=<ctx> get certificate,ingress -A
kubectl --context=<ctx> top nodes
```

| | dev | staging | prod |
|---|---|---|---|
| Scale | 1 replica | 2 replicas + persistence | HA + HPA + PDB |
| TLS | LE staging | LE staging | **LE prod** |
| Secrets | SOPS | SOPS / ESO | **ESO (Vault / AWS SM)** |
| Policy | Audit | Audit | Audit → **Enforce** once reports are clean |
| Ingress class | `kong` | `kong` | `kong` |
