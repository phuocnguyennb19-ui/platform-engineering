# k8s

A generic Helm chart + Helmfile setup for deploying microservices to Kubernetes.
One chart deploys **Application + Workers + CronJobs**, with environment variables managed via ConfigMap (plaintext) and Secret (SOPS encrypted).

Commands below run from `k8s/` unless a path starts at the repository root (`ci/`, `monitoring/`, `argocd/`).

---

## Prerequisites

### Local development

| Tool | Version | Install |
|---|---|---|
| helm | >= 3.15 | `brew install helm` |
| helmfile | >= 0.157 | `brew install helmfile` |
| helm-secrets | >= 4.5 | `helm plugin install https://github.com/jkroepke/helm-secrets` |
| sops | >= 3.8 | `brew install sops` |
| age | >= 1.1 | `brew install age` |

### CI/CD

GitLab Runner uses a **pre-built image** (`deploy-tools`) with all tools already installed.  
No per-job installation. See [ci/images/Dockerfile](../ci/images/Dockerfile) for the image definition.

Build and push the runner image once:

```bash
docker build -t $CI_REGISTRY_IMAGE/deploy-tools:$DEPLOY_TOOLS_VERSION -f ci/images/Dockerfile ci/images/
docker push $CI_REGISTRY_IMAGE/deploy-tools:$DEPLOY_TOOLS_VERSION
```

Register the runner with this image in GitLab Runner config (`config.toml`):

```toml
[[runners]]
  [runners.docker]
    image = "registry.gitlab.com/myorg/<platform-repo>/deploy-tools:latest"
```

---

## Project Structure

Tools and applications each get one folder, named after the thing they deploy; a
folder's role is read off its `layer` label. Paths are relative to the repository root.

```
k8s/
├── helmfile.yaml.gotmpl         # ROOT — includes every folder. INCLUDE ORDER = DEPLOY ORDER
│
│   # ── TOOLS — one folder = one helm release (layer=platform) ──
├── platform/
│   ├── metrics-server/  karpenter/  cluster-autoscaler/  reloader/  keda/
│   ├── minio/  postgresql/  redis/  kafka/  clickhouse/
│   ├── opensearch/  opensearch-dashboards/
│   ├── cert-manager/  ingress-nginx/  kong/  external-dns/
│   ├── vault/  external-secrets/  sealed-secrets/  kyverno/  trivy-operator/  falco/
│   ├── argocd/  velero/  harbor/
│   │   # ── KUBECTL-ONLY (no helm release) ──
│   ├── bootstrap/manifests/         # namespaces + PSA — apply FIRST
│   ├── network-policies/manifests/  # zero-trust ingress, per tier — apply LAST
│   └── gateway-api/manifests/       # Gateway API CRDs + the Gateway object
│
│   # ── APPLICATIONS — one folder = one charts/application release (layer=app) ──
├── apps/<app>/
│
├── charts/application/          # in-house Helm chart SOURCE (published to OCI)
│   ├── Chart.yaml · values.yaml #   generic microservice chart
│   ├── templates/               #   workload, worker, cronjob, service, ingress, hpa, pdb,
│   │                            #     networkpolicy, configmap, secret, sa
│   └── ci/                      #   chart-testing values matrix
│
├── env-values/                  # ── ENV CONFIG — shared by every helmfile state ──
│   ├── environments.yaml        #   env knobs (namespace/storageClass/ingress/domain)  [base]
│   ├── repositories.yaml        #   chart repos + helm defaults                        [base]
│   ├── app-values.yaml.gotmpl   #   values layer shared by every app
│   └── <env>/
│       ├── app-values.yaml.gotmpl   # per-env app values layer
│       └── secrets.enc.yaml         # SOPS-encrypted values
│
├── docs/                        # DEPLOY.md · APPS.md · TROUBLESHOOTING.md
└── README.md

monitoring/                      # ── OBSERVABILITY — same layout as platform/<tool>, listed in k8s/helmfile.yaml.gotmpl ──
├── kube-prometheus-stack/       # deploys FIRST: ships the ServiceMonitor/PrometheusRule CRDs
├── loki/  tempo/  mimir/  opentelemetry-collector/  alloy/  grafana/
└── prometheus-rules/            # platform PrometheusRules, merged into kube-prometheus-stack
argocd/                          # Argo CD App-of-Apps — the OTHER possible owner of the app tier
├── root-app.yaml                # App-of-Apps entrypoint
└── bootstrap/                   # AppProject + ApplicationSet
applications/<svc>/k8s/          # per-app values + per-env overlays (read by Argo CD and local/)
ci/
├── k8s/                         # main.yml (chart + deploy) · helmfile.yml · argocd.yml
├── deploy-template.gitlab-ci.yml # included by application repos
├── images/                      # Dockerfile (deploy-tools) · Dockerfile.ci · Dockerfile.runner
└── runner/                      # GitLab Runner: config.toml · docker-compose.yml
.gitlab-ci.yml · .sops.yaml · .gitignore   # root pipeline · SOPS config · ignore rules
```

**Inside every folder — the same five roles, always named the same way:**

| Path | Role |
|---|---|
| `helmfile.yaml.gotmpl` | the release: chart, version, namespace, labels |
| `values.yaml.gotmpl` | chart values |
| `values/` | extra values fragments, merged **after** `values.yaml.gotmpl` |
| `files/` | raw config pulled in verbatim via `readFile` (tools) |
| `config/` | ConfigMap **data** layered into the chart values (apps) |
| `manifests/` | raw k8s manifests — `kubectl apply`, **never** rendered by helm |
| `README.md` | the runbook for that one component |

> Every folder is its own **helmfile state**, so `needs` cannot cross a folder
> boundary. The include order in the root `helmfile.yaml.gotmpl` **is** the deploy
> order — reordering that list changes what installs first. `kube-prometheus-stack`
> must stay at the top: it ships the ServiceMonitor/PrometheusRule CRDs that nearly
> every other tool's values reference.
>
> Everything: `helmfile -e <env> sync`. One tool: `-f platform/<tool>/helmfile.yaml.gotmpl`
> (observability: `-f ../monitoring/<tool>/helmfile.yaml.gotmpl`).
> Infra only: `-l layer=platform`. Apps only: `-l layer=app`. One concern:
> `-l component=logs`. Full procedure: **[docs/DEPLOY.md](docs/DEPLOY.md)**.

---

## Deploy Architecture

Each service produces the following Kubernetes resources:

```
values.yaml.gotmpl ──► Deployment          (Application — HTTP server)
                   ──► Deployment × N      (Workers — background jobs)
                   ──► CronJob × N         (CronJobs — scheduled tasks)
                   ──► Service
                   ──► Ingress
                   ──► HPA                 (if enabled)
                   ──► PodDisruptionBudget (if enabled)
                   ──► NetworkPolicy       (if enabled)

env.yaml           ──► ConfigMap           (non-sensitive env vars)
env.secret.yaml    ──► Secret              (sensitive env vars, SOPS encrypted)
```

All Deployments and CronJobs mount the **same** ConfigMap and Secret via `envFrom`.

---

## Per-Service File Layout

Each service has three files with a clear separation of concerns:

| File | Purpose | Commit as |
|---|---|---|
| `values.yaml.gotmpl` | Deployment config — replicas, image, probes, workers, cronjobs | Plaintext |
| `env.yaml` | Non-sensitive env vars — hostnames, ports, feature flags | Plaintext |
| `env.secret.yaml` | Sensitive env vars — passwords, API keys, tokens | **SOPS encrypted** |

### `values.yaml.gotmpl` — deployment config

```yaml
# ─── Image ──────────────────────────────────────────────────
image:
  repository: myregistry/be-payment
  tag: "v2.0.1"

# ─── Application (HTTP server) ──────────────────────────────
replicaCount: 2
service:
  port: 80
  targetPort: 9090
ingress:
  enabled: true
  hosts:
    - host: be-payment.dev.example.com
      paths:
        - path: /
          pathType: Prefix
probes:
  liveness:
    httpGet:
      path: /healthz
      port: 9090
  readiness:
    httpGet:
      path: /ready
      port: 9090

# ─── Workers (list) ─────────────────────────────────────────
workers:
  - name: payment-event          # → Deployment: <release>-payment-event
    enabled: true
    replicaCount: 2
    command: ["./be-payment"]
    args: ["worker", "--queue=payment-events"]
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 300m, memory: 256Mi }
    probes:
      liveness:
        exec:
          command: ["/bin/sh", "-c", "pgrep -f 'payment-events' > /dev/null"]
    autoscaling:
      enabled: false

  - name: webhook                # → Deployment: <release>-webhook
    enabled: true
    replicaCount: 1
    command: ["./be-payment"]
    args: ["worker", "--queue=webhook-dispatch"]

# ─── CronJobs (list) ────────────────────────────────────────
cronjobs:
  - name: cleanup                # → CronJob: <release>-cleanup
    enabled: true
    schedule: "0 2 * * *"
    command: ["./be-payment"]
    args: ["cleanup", "--older-than=30d"]
    concurrencyPolicy: Forbid
    activeDeadlineSeconds: 1800

  - name: retry-failed-payments  # → CronJob: <release>-retry-failed-payments
    enabled: true
    schedule: "*/30 * * * *"
    command: ["./be-payment"]
    args: ["retry-payments", "--batch-size=100"]
    concurrencyPolicy: Forbid
    activeDeadlineSeconds: 600
```

### `env.yaml` — public env vars (committed as plaintext)

```yaml
configmap:
  enabled: true
  data:
    APP_ENV: "development"
    DB_HOST: "postgres.database.svc.cluster.local"
    DB_PORT: "5432"
    REDIS_HOST: "redis-master.cache.svc.cluster.local"
    KAFKA_BROKERS: "kafka.messaging.svc.cluster.local:9092"
    OTEL_EXPORTER_OTLP_ENDPOINT: "http://opentelemetry-collector.observability.svc.cluster.local:4318"
```

### `env.secret.yaml` — secret env vars (must be SOPS encrypted before committing)

```yaml
secret:
  enabled: true
  data:
    DB_PASSWORD: "change-me-before-encrypt"
    JWT_SECRET: "change-me-before-encrypt"
    PAYMENT_GATEWAY_API_KEY: "change-me-before-encrypt"
```

---

## Values Merge Order

Helmfile merges values in the order below. Later files override earlier ones.

```
1. env-values/app-values.yaml.gotmpl        # baseline security, volumes, service account
2. env-values/<env>/app-values.yaml.gotmpl  # env-specific: ingress class, network policy, scaling
3. <service>/values.yaml.gotmpl     # deployment config: replicas, probes, workers, cronjobs
4. <service>/env.yaml               # public env vars  →  configmap.data
5. <service>/env.secret.yaml        # secret env vars  →  secret.data  (auto-decrypted by SOPS)
6. <service>/<env>.yaml             # optional small per-env overrides
```

---

## Env Vars Flow in Pods

```
env.yaml           →  configmap.data  →  ConfigMap (K8s)  ─┐
                                                             ├─ envFrom in every pod
env.secret.yaml    →  secret.data     →  Secret (K8s)     ─┘
(SOPS decrypted)

Every container (Application, Worker, CronJob) receives:
  SERVICE_NAME=be-payment          ← from ConfigMap
  DB_HOST=postgres...              ← from ConfigMap
  DB_PASSWORD=actual-value         ← from Secret (base64-decoded automatically)
  JWT_SECRET=actual-value          ← from Secret
```

Kubernetes injects all keys as environment variables. If the same key exists in both ConfigMap and Secret, the Secret value takes precedence (loaded last in `envFrom`).

---

## Secret Management with SOPS

### Initial setup

```bash
# Generate an age key pair
age-keygen -o ~/.config/sops/age/keys.txt

# Print the public key — add it to .sops.yaml
cat ~/.config/sops/age/keys.txt | grep "public key"
# Public key: age1xxxxxxxxxx...

# Point SOPS to the private key
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

Update `.sops.yaml` with the team's public key:

```yaml
creation_rules:
  - path_regex: .*/env\.secret\.yaml$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Daily workflow

```bash
# First-time: fill in real values then encrypt in-place
sops -e -i release/be-payment/env.secret.yaml

# Edit an already-encrypted file (opens in $EDITOR, saves encrypted)
sops release/be-payment/env.secret.yaml

# Decrypt and print to stdout (read-only, nothing saved)
sops -d release/be-payment/env.secret.yaml

# Rotate key when a team member leaves
sops updatekeys release/be-payment/env.secret.yaml
```

> **Rule:** Only commit `env.secret.yaml` **after** encrypting. A plaintext secrets file must never enter git.

---

## Helmfile Commands

All commands run from the repo root.

```bash
cd release/
```

### Render templates

```bash
# Render a single service
helmfile -e dev -l name=be-payment template

# Render all services in an environment
helmfile -e dev template
```

### Preview changes before applying

```bash
helmfile -e dev -l name=be-payment diff
```

### Deploy

```bash
# Deploy all services in dev
helmfile -e dev sync

# Deploy a single service
helmfile -e dev -l name=be-payment sync

# Deploy to staging
helmfile -e staging sync

# Deploy to production
helmfile -e prod sync
```

### Rollback

```bash
# View release history
helm history be-payment -n dev

# Roll back to the previous revision
helm rollback be-payment -n dev

# Roll back to a specific revision
helm rollback be-payment 3 -n dev
```

---

## Deploying by Selector

Helmfile supports label selectors via `-l key=value` to target specific releases.  
Each release in this project has the following labels assigned automatically:

| Label | Values | Example |
|---|---|---|
| `name` | service folder name | `name=be-payment` |
| `env` | `dev` / `staging` / `prod` | `env=prod` |
| `tier` | `backend` (`be-*`) / `frontend` (`fe-*`) / `infra` | `tier=backend` |

Selector syntax: `-l key=value` — comma for AND, multiple `-l` flags for OR.

### By service name

```bash
# Single service
helmfile -e dev -l name=be-payment sync

# Two specific services (comma = AND is not useful here; use separate runs or tier)
helmfile -e dev -l name=be-payment diff
helmfile -e dev -l name=be-user diff
```

### By tier — deploy all backend services at once

```bash
# Diff all backend services
helmfile -e staging -l tier=backend diff

# Deploy all backend services
helmfile -e staging -l tier=backend sync

# Deploy all frontend services
helmfile -e staging -l tier=frontend sync

# Deploy all infra releases (ingress controllers, etc.)
helmfile -e prod -l tier=infra sync
```

### By environment label

```bash
# List all releases that would be selected
helmfile -e prod -l env=prod list
```

### Combining selectors (AND)

```bash
# Backend services in prod only
helmfile -e prod -l tier=backend,env=prod sync
```

### Useful one-liners

```bash
# List all releases with their labels
helmfile -e dev list

# Check what will be deployed before syncing
helmfile -e prod -l tier=backend diff

# Destroy a single service (careful in prod)
helmfile -e dev -l name=be-payment destroy

# Apply only if there are changes (skip unchanged)
helmfile -e dev -l name=be-payment apply
```

### `sync` vs `apply` vs `diff`

| Command | Behaviour |
|---|---|
| `diff` | Show what would change — no side effects |
| `apply` | Apply only releases that have a diff — skips unchanged |
| `sync` | Force reconcile all selected releases regardless of diff |
| `template` | Render manifests to stdout — useful for debugging |
| `destroy` | Delete all K8s resources for selected releases |

> Use `apply` in CI/CD pipelines to skip unchanged services and speed up deploys.  
> Use `sync` when you need to force a re-apply (e.g., after a manual cluster change).

---

## GitLab CI Integration

### Architecture

Two independent pipelines run in this repo:

| Pipeline | Trigger | What it does |
|---|---|---|
| **Chart pipeline** | Changes in `k8s/charts/**` | lint → package → publish chart to OCI registry |
| **Deploy pipeline** | Triggered by source repos | validate → deploy one service to one env |

Source repos never run helmfile directly. They only build the image and fire a trigger.

```
be-payment repo                     platform repository
───────────────────                 ────────────────────────────────────────
push to develop
  │
  ├─ build image
  ├─ push harbor/.../be-payment:abc1234
  └─ trigger ───────────────────────► deploy pipeline receives:
                                          SERVICE_NAME = be-payment   ← CI_PROJECT_NAME
                                          IMAGE_TAG    = abc1234      ← CI_COMMIT_SHORT_SHA
                                          DEPLOY_ENV   = dev          ← derived from branch
                                        │
                                        ├─ validate: helmfile template (dry-run)
                                        └─ deploy:
                                             IMAGE_TAG=abc1234 \
                                             helmfile -e dev -l name=be-payment apply
```

### Runner image — no per-job installs

The GitLab Runner uses a pre-built image with all tools installed (`ci/images/Dockerfile.runner`).  
Jobs only set up credentials — no `apk install` or `curl` downloads at runtime.

Build and register once:

```bash
# Build and push the runner image
docker build -t $CI_REGISTRY_IMAGE/deploy-tools:$DEPLOY_TOOLS_VERSION -f ci/images/Dockerfile ci/images/
docker push $CI_REGISTRY_IMAGE/deploy-tools:$DEPLOY_TOOLS_VERSION
```

`config.toml` on the runner host:
```toml
[[runners]]
  [runners.docker]
    image = "registry.gitlab.com/myorg/<platform-repo>/deploy-tools:latest"
```

### Chart lifecycle — OCI registry

When `k8s/charts/**` changes on `main`, the chart pipeline:
1. Lints the chart
2. Reads `version` from `Chart.yaml`
3. Packages and pushes to the GitLab Container Registry

```
charts/application/Chart.yaml  →  version: 1.2.0
  └─ helm push oci://registry.gitlab.com/myorg/<platform-repo>/charts/application:1.2.0
```

The `release/helmfile.yaml.gotmpl` pins the app chart version via `$appVersion`
(default `CHART_VERSION` env, else the pinned default):

```gotmpl
{{- $appVersion := env "CHART_VERSION" | default "1.0.0" }}
```

Override at deploy time:
```bash
# Use a specific chart version without editing the file
CHART_VERSION=1.3.0 helmfile -e prod sync

# Use local chart during development
CHART_PATH=../charts/application helmfile -e dev template
```

### Branch → Environment mapping (source repos)

| Branch pattern | Environment | Approval |
|---|---|---|
| `develop`, `dev`, `feature/*` | `dev` | automatic |
| `staging`, `release/*` | `staging` | automatic |
| `main`, `master` | `prod` | **manual gate** |

### Required CI/CD variables

Set at the **GitLab group level** so all projects inherit them automatically.

| Variable | Scope | Description |
|---|---|---|
| `SOPS_AGE_PRIVATE_KEY` | Helm repo | age private key for SOPS decryption |
| `KUBE_CONFIG` | Helm repo | base64-encoded kubeconfig per cluster |
| `HELM_TRIGGER_TOKEN` | Source repos | Pipeline trigger token from helm repo |
| `HELM_PROJECT_ID` | Source repos | GitLab project ID of the platform repository |
| `REGISTRY_USER` | Source repos | Container registry username |
| `REGISTRY_PASSWORD` | Source repos | Container registry password |

### Setup in each source repo

Three lines. That's it:

```yaml
# be-payment repo: .gitlab-ci.yml
include:
  - project: 'myorg/<platform-repo>'
    ref: main
    file: 'ci/deploy-template.gitlab-ci.yml'

variables:
  HELM_PROJECT_ID: "456"                 # project ID of the platform repository
  IMAGE_REGISTRY: "harbor.prod.example.com"
  # SERVICE_NAME defaults to CI_PROJECT_NAME
  # Override only if helmfile release name differs from repo name:
  # SERVICE_NAME: "be-payment"
```

Push to `develop` → image built → `be-payment` deployed to `dev` automatically.  
Push to `main` → image built → manual button appears → deploys to `prod`.

### Image tag in values

`values.yaml.gotmpl` reads `IMAGE_TAG` from the CI environment, falls back to the pinned tag locally:

```yaml
image:
  repository: harbor.prod.example.com/be-payment
  tag: {{ env "IMAGE_TAG" | default "v2.0.1" }}
```

### Pipeline trigger token

**GitLab → the platform repository → Settings → CI/CD → Pipeline triggers → Add new token**

Store the token as `HELM_TRIGGER_TOKEN` in GitLab group CI/CD variables.

---

## Adding a New Service

A service is a folder under `k8s/apps/`.

1. Copy the closest existing app as the skeleton — `be-user` is the minimal one:

```bash
cp -r apps/be-user apps/be-order
```

2. Adjust `apps/be-order/helmfile.yaml.gotmpl`: change `name:` and the `name:` /
   `tier:` labels to `be-order`. Nothing else in that file is service-specific.

3. Fill in `apps/be-order/values.yaml.gotmpl` — image, ingress host, resources.
   `image.repository` has **no chart default**, so a missing or mistyped values
   file fails the render instead of deploying something unintended.

4. Optional layers, each detected on disk — create only the ones you need:

```bash
mkdir -p apps/be-order/config
touch apps/be-order/config/common.yaml   # ConfigMap data, all envs
touch apps/be-order/config/dev.yaml      # ConfigMap data, dev only
touch apps/be-order/secrets.yaml.gotmpl  # reads .Values.secrets.be-order.*
```

5. Add the secret values under `secrets.be-order` in each
   `env-values/<env>/secrets.enc.yaml` (they stay SOPS-encrypted in git).

6. Register the folder in the root `helmfile.yaml.gotmpl` include list, under
   the applications block at the end — the list is the deploy order, so apps
   belong last:

```yaml
  - path: apps/be-order/helmfile.yaml.gotmpl
```

7. Deploy:

```bash
CHART_PATH="$(pwd)/charts/application" helmfile -e dev -l name=be-order sync
```

---

## Enabling and Disabling Components

Every component has an `enabled` flag. Set it to `false` instead of removing the block:

```yaml
workers:
  - name: webhook
    enabled: false        # skip this worker

cronjobs:
  - name: weekly-report
    enabled: false        # skip this cronjob

autoscaling:
  enabled: false          # no HPA

podDisruptionBudget:
  enabled: false          # no PDB

networkPolicy:
  enabled: false          # no NetworkPolicy
```

---

## Chart Capabilities

| Resource | Condition |
|---|---|
| Deployment (app) | always, unless `daemonset.enabled: true` |
| Service | always |
| Ingress | `ingress.enabled: true` |
| HPA | `autoscaling.enabled: true` |
| PodDisruptionBudget | `podDisruptionBudget.enabled: true` |
| NetworkPolicy | `networkPolicy.enabled: true` |
| ConfigMap | `configmap.enabled: true` |
| Secret | `secret.enabled: true` |
| ServiceAccount | `serviceAccount.create: true` |
| DaemonSet | `daemonset.enabled: true` |
| Worker Deployment | each item in `workers[]` with `enabled: true` |
| HPA per Worker | each item in `workers[]` with `autoscaling.enabled: true` |
| CronJob | each item in `cronjobs[]` with `enabled: true` |
