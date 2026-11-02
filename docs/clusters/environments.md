# Environment configuration — where each piece already lives

The files next to this README (`dev.yaml`, `staging.yaml`, `production.yaml`)
hold only the environment's **name mapping**, its **deploy policy** and the **expected PSA level**. Everything
that actually configures an environment already has an owner in the repository, listed
below. This directory does not copy it, and installs nothing that Helmfile or Argo CD
manages. Application-specific values stay in `applications/<app>/k8s/<env>/values.yaml`.

| Area | Shared (every env) | Per environment | Applied by |
|---|---|---|---|
| **Namespaces** | — | `dev` / `staging` / `prod`: `environments/<env>/kubernetes/namespace/namespaces.yaml`; app namespace = Helm env name (`applications/helmfile.yaml.gotmpl`) | bootstrap: kubectl (`kubernetes/docs/NAMESPACES.md`); Argo CD `CreateNamespace=true` |
| **Pod Security Admission** | — | labels on the namespaces above: apps `restricted` everywhere, platform namespaces `baseline`/`privileged` | same as namespaces |
| **Ingress** | controller release `kubernetes/releases/platform/kong/` (Kong Ingress Controller, namespace `infra`; ingress-nginx is legacy, `ingressNginx` in `state.yaml`); app defaults `environments/<env>/kubernetes/app-values.yaml.gotmpl` | class + domain: `environments/<env>/kubernetes/state.yaml` (`ingressClass`, `ingressDomain`) and `<env>/app-values.yaml.gotmpl` (`kong`) | `helmfile:sync:<env>` (platform), Argo CD (apps) |
| **Gateway API** | `kubernetes/releases/platform/gateway-api/` (CRDs + GatewayClass `kong`, Gateway `platform`), controller `kubernetes/releases/platform/kong/` | listeners differ outside dev (HTTPS) | kubectl manifest + helmfile |
| **DNS / TLS** | `kubernetes/releases/platform/external-dns/`, `kubernetes/releases/platform/cert-manager/` | `environments/<env>/kubernetes/tools/<tool>/` | `helmfile:sync:<env>` |
| **RBAC** | chart `kubernetes/charts/application/templates/rbac/`; Argo CD `kubernetes/argocd/bootstrap/appproject-platform.yaml` | — | Argo CD / helmfile |
| **NetworkPolicy** | `environments/<env>/kubernetes/network/` (baseline, monitoring, database, application, platform, security); chart `templates/networking/networkpolicy.yaml` | `networkPolicy.*` in `<env>/app-values.yaml.gotmpl` | kubectl manifests; chart |
| **ResourceQuota / LimitRange** | **none in the repository** | **none** | — (open item, not added here) |
| **Requests / limits, replicas** | `app-values.yaml.gotmpl` | `<env>/app-values.yaml.gotmpl` (`replicaCount` 1 / 2 / 3, autoscaling in prod) | Argo CD (apps) |
| **StorageClass** | **no StorageClass is defined in the repository**; `storageClass: ""` in `environments.yaml` means "cluster default" | — | provider (EBS CSI add-on on EKS, `local-path` on K3s, `hostpath` on Docker Desktop) — preflight checks it |
| **Monitoring CRDs / operator** | `kubernetes/releases/observability/kube-prometheus-stack/` | `environments/<env>/kubernetes/monitoring/<tool>/` | `helmfile:sync:<env>`; local helmfile |
| **Secrets** | ESO / SealedSecrets / Vault releases under `kubernetes/releases/platform/` | `environments/<env>/kubernetes/secrets.enc.yaml` (SOPS) | helmfile (never this directory) |

There is no `local` or `onprem-*` app environment: a laptop, K3s or self-managed cluster is a
deploy target of `dev` (or another environment) in `../targets(.local).yaml`.

## The files here

| Field | Meaning | Consumed by |
|---|---|---|
| `names.helmfile` | `helmfile -e`, `DEPLOY_ENV`, and the app namespace | `preflight.sh` (check 8) |
| `names.terraform` | `ENVIRONMENT`, `environments/<dir>/terraform/ (dir = Helm name)` | schema (mapping `prod` ↔ `production`) |
| `delivery.autoDeploy` | policy: may a pipeline deploy unattended — `false` everywhere; the schema forbids `true` for staging/production | schema; no pipeline reads it |
| `security.podSecurityStandard` | expected PSA `enforce` level of the app namespace; applies nothing | `check-metadata.sh` (must equal the namespace manifest) · `preflight.sh` (compared with the live label) |

Every field has a reader; a field nobody reads or checks does not belong here.
