# Argo CD — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/argocd/`](../../../../environments/dev/kubernetes/tools/argocd/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

GitOps continuous delivery. Installed by **helmfile** (it is a `layer=platform` release),
then optionally takes ownership of the app tier via the App-of-Apps in
`kubernetes/argocd/`.

| | |
|---|---|
| Chart | `argo/argo-cd` |
| Version | `7.8.0` |
| Release / Namespace | `argocd` / `infra` |
| Selector | `-l name=argocd` |
| Labels | `layer=platform, tier=infra, component=delivery` |
| Values | `values.yaml.gotmpl` |
| URL | `argocd.<ingressDomain>` |
| Server mode | `server.insecure: true` — TLS terminates at the ingress |

Replicas: controller 1 (sharding not enabled), repo-server/server 1 in dev-staging, 2 in prod.

> ⚠ **Never let helmfile and Argo CD both own the app tier.** Argo's `selfHeal` + `prune`
> will revert every `helmfile sync`, and helmfile will revert Argo. Pick one with
> `APP_TIER_OWNER` (`helmfile` default, or `argocd`). See `README.md`.

---

## 1. Prerequisites

- `infra` namespace (PSA `baseline` — Argo's redis/dex need fsGroup).
- `ingress-nginx` + cert-manager for `argocd.<domain>`.
- `kube-prometheus-stack` for the ServiceMonitor.
- Egress to quay.io for `redisSecretInit` (see below).
- **prod only, before the first sync:** SSO configured — read the next section.

---

## 2. 🔴 prod: local admin is disabled

`admin.enabled: "false"` in prod, with `policy.default: role:readonly`. The built-in admin
is a shared, non-attributable credential with cluster-admin reach through Argo and it
bypasses the SSO audit trail — so it is off.

**Configure SSO (`dex.config` / `oidc.config`) and map your IdP groups in `rbac.policy.csv`
BEFORE the first prod sync**, or nobody can log in:

```yaml
rbac:
  policy.csv: |
    g, platform-team@example.com, role:admin
    g, devs@example.com,          role:readonly
  scopes: "[groups, email]"
```

Emergency recovery: set `admin.enabled: "true"` in `values.yaml.gotmpl`, re-sync, restart
`argocd-server`, fix SSO, then turn it back off.

---

## 3. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f releases/platform/argocd/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/argocd/helmfile.yaml.gotmpl sync
```

If the network blocks quay.io, set `redisSecretInit.enabled: false` and create the secret
by hand:

```bash
kubectl -n infra create secret generic argocd-redis \
  --from-literal=auth=$(openssl rand -base64 24)
```

---

## 4. Bootstrap GitOps (App-of-Apps)

```bash
# 1. hand the app tier to Argo — STALE: this step used `helmfile -l layer=app sync` in kubernetes/,
#    which matches no release any more (apps: ../applications/, released per app from the repo root).
#    The ownership switch for applications/ is not documented yet; decide it with the platform team
#    (owner = delivery.owner in environments/<env>/kubernetes/cluster/<cluster>.yaml). Never both owners.

# 2. login (dev/staging)
kubectl -n infra get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
argocd login argocd.$INGRESS_DOMAIN --username admin

# 3. register the repo
kubectl -n infra create secret generic gitlab-repo \
  --from-literal=type=git \
  --from-literal=url=https://gitlab.com/myorg/helm-project-v3.git \
  --from-literal=username=<user> --from-literal=password=<token>
kubectl -n infra label secret gitlab-repo argocd.argoproj.io/secret-type=repository

# 4. root app
kubectl apply -f ../kubernetes/argocd/bootstrap/appproject-platform.yaml
kubectl apply -f ../kubernetes/argocd/root-app.yaml
```

`root-app` pulls `bootstrap/` → creates the `platform-apps` ApplicationSet → one
Application per app × env (`be-payment-dev`, `be-payment-prod`, …).

Sync behaviour: **dev/staging automated** (prune + selfHeal); **prod is manual** —
`argocd app diff` then `argocd app sync`.

---

## 5. Verify

```bash
kubectl -n infra get pods -l app.kubernetes.io/part-of=argocd
kubectl -n infra rollout status deploy/argocd-server --timeout=300s

argocd app list
argocd app get be-payment-dev
kubectl -n infra get applications.argoproj.io
```

Healthy = `Synced` + `Healthy`. `OutOfSync` on prod is expected (manual sync).

---

## 6. Deploying a new version through Argo

Argo cannot read CI variables, so **the image tag is committed to git** — that commit is
the deploy:

```bash
# edit ../applications/<app>/k8s/prod/values.yaml → image.tag
git commit -am "deploy: <app> abc1234 → prod" && git push
argocd app sync <app>-prod      # prod requires a manual sync
```

---

## 7. Rollback

```bash
argocd app history be-payment-prod
argocd app rollback be-payment-prod <ID>
```

Preferred (keeps git as the source of truth):

```bash
git revert <commit-that-changed-the-tag>
git push
argocd app sync <app>-prod
```

Rolling back **Argo itself**:

```bash
helm history argocd -n infra
helm rollback argocd <REVISION> -n infra --wait
```

Applications and their history live in CRs in `infra` and survive a chart rollback. While
Argo is down, running workloads are unaffected — only reconciliation stops (and drift is no
longer corrected).

---

## 8. Monitoring & alerting

`controller.metrics` + ServiceMonitor enabled.

| Signal | Metric |
|---|---|
| Out-of-sync apps | `argocd_app_info{sync_status="OutOfSync"}` (expected on prod; alert elsewhere) |
| Unhealthy apps | `argocd_app_info{health_status!="Healthy"}` |
| Sync failures | `argocd_app_sync_total{phase="Failed"}` |
| Reconcile latency | `argocd_app_reconcile_bucket` — rising means the controller is saturated |
| Repo-server errors | `argocd_git_request_total{request_type="ls-remote"}` failures |

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Nobody can log in to prod | `admin.enabled: false` with no working SSO — use the recovery path in §2. |
| App stuck `Progressing` | Underlying workload not becoming Ready; `argocd app get` shows the failing resource. |
| Argo reverts a manual change | `selfHeal: true` — that is the point. Change git, not the cluster. |
| Argo and helmfile fight | Both own the app tier. Set `APP_TIER_OWNER` and re-sync. |
| `repository not accessible` | Repo secret missing the `argocd.argoproj.io/secret-type=repository` label, or a bad token. |
| Pods `CrashLoopBackOff` at install | `argocd-redis` secret missing (quay.io blocked) — create it manually. |
| ComparisonError on a Helm app | Chart values reference an env var Argo does not have; Argo renders without CI variables. |

---

## 10. Notes

- `exec.enabled: "false"` — no shell into pods from the Argo UI. Keep it off; it is an
  audit-bypassing backdoor.
- Argo CD is installed by helmfile, not by itself. Bootstrapping order is
  helmfile → Argo → (optionally) Argo owns apps.
- GitOps manifests (`Application`, `AppProject`, `ApplicationSet`) live in
  `kubernetes/argocd/` and are applied via the root app, **not** by helmfile.
