#  — Deploy (app tier)

The four application releases, all rendered from the shared `charts/application` chart.
Deploy **last**: they need `ingress-nginx` and `metrics-server`.

| Service | Ingress host | ConfigMap | SOPS Secret | Per-service doc |
|---|---|---|---|---|
| `be-payment` | `payment.<domain>` | ✅ | ✅ | [apps/be-payment/README.md](../apps/be-payment/README.md) |
| `be-user` | `user.<domain>` | ✖ | ✖ | [apps/be-user/README.md](../apps/be-user/README.md) |

The ConfigMap / Secret columns describe what is **present on disk** — the helmfile
detects them, so this table is documentation, not configuration. Nothing breaks if
it drifts.

Namespace: `<env>` (`dev` / `staging` / `prod`). Labels: `layer=app`, plus
`tier=backend|gateway`.

---

## 1. 🔴 Ownership switch — pick exactly one

The app tier can be driven by **helmfile** *or* **Argo CD**, never both. Two controllers
reconciling the same Deployment produce an infinite sync loop (Argo's `selfHeal`+`prune`
reverts helmfile, helmfile reverts Argo).

```bash
export APP_TIER_OWNER=helmfile   # default → these releases install; keep the Argo ApplicationSet disabled
export APP_TIER_OWNER=argocd     # → releases become installed:false; Argo owns the app tier
```

Switching to Argo requires one sync to *remove* the helmfile releases first:

```bash
export APP_TIER_OWNER=argocd
helmfile -e $ENV -l layer=app sync
kubectl apply -f ../argocd/root-app.yaml
```

See `platform/argocd/README.md`.

---

## 2. Chart resolution

| Variable | Default | Effect |
|---|---|---|
| `CHART_PATH` | unset | set to `charts/application` to use the **local** chart (dev) |
| `CHART_REGISTRY` | — | explicit OCI reference |
| `HELM_CHART_ACCOUNT_ID` | `339713046864` | ECR account for the default OCI path |
| `AWS_REGION` | `ap-southeast-1` | ECR region |
| `CHART_VERSION` | `2.0.0` | chart version when pulling OCI |
| `IMAGE_TAG` | `1.0.0` | **application image tag** — CI passes `$CI_COMMIT_SHORT_SHA` |

Default OCI path: `oci://<acct>.dkr.ecr.<region>.amazonaws.com/helm/application`, which
must match where `ci/k8s/main.yml` `chart:publish` pushes.

---

## 3. Values layering (order matters)

```
env-values/app-values.yaml.gotmpl      → hardened defaults for every service/env
env-values/<env>/app-values.yaml.gotmpl       → env defaults: registry, replicas, netpol
<svc>/values.yaml.gotmpl       → the service itself (image, probes, hosts)
<svc>/config.yaml              → ConfigMap baseline
<svc>/config/<env>.yaml        → ConfigMap per-env override
<svc>/secrets.yaml.gotmpl      → SOPS-backed Secret
```

**Every layer is optional.** All six are detected on disk (`isFile`), none is
declared. Create a file and it is layered in on the next render; delete it and it
is not. There is no `hasEnv` / `hasSecret` flag to keep in sync — that bookkeeping
was the thing people forgot, and forgetting it deployed a service without its
ConfigMap.

Granularity is per-service **and** per-env independently:

- `be-user` has only `values.yaml.gotmpl` — the other five simply do not exist.
- `<svc>/config/prod.yaml` alone is valid: prod gets the override, dev and staging
  do not.
- Even `env-values/**/app-values.yaml.gotmpl` may be absent; the chart's own defaults are already
  hardened (non-root UID 10001, `readOnlyRootFilesystem`, all capabilities dropped,
  seccomp `RuntimeDefault`, no auto-mounted SA token).

File names state their **role**, not their environment. `<svc>/config/prod.yaml` is
ConfigMap data; `env-values/prod/app-values.yaml.gotmpl` is chart values. They used to both be
called `prod.yaml`, one directory apart.

What `env-values/app-values.yaml.gotmpl` actually adds on top of the chart defaults: the
memory-backed `/tmp` volume, the NetworkPolicy allowing ingress from namespace
`infra` plus same-namespace, Reloader, and the baseline `prometheusRule`.

> ⚠ **Safety does not come from this file — it comes from the chart.**
> Making every layer optional is only safe because `image.repository` has no
> default. A values file that fails to load, or a path that was mistyped, now
> fails the render with `at '/image/repository': minLength: got 0, want 1`.
>
> Previously `repository` defaulted to `nginx` and `missingFileHandler` was `Warn`,
> so a mistyped path printed `skipping missing values file` into the log and
> deployed an **nginx pod under the service's own name and Ingress** — green
> pipeline, green rollout, wrong application serving production traffic.
>
> `missingFileHandler: Error` is kept as a second line of defence: every path the
> helmfile emits was confirmed present on disk a moment earlier, so if one is
> missing at render time something is genuinely wrong.

---

## 4. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
export APP_TIER_OWNER=helmfile
export IMAGE_TAG=abc1234                 # real image tag
export CHART_PATH=charts/application     # dev: use the local chart

helmfile -e $ENV -l layer=app diff
helmfile -e $ENV -l layer=app sync

# one service
helmfile -e $ENV -l name=be-payment sync
```

---

## 5. Verify

```bash
helmfile -e $ENV -l layer=app list
kubectl -n $ENV get pods,svc,ingress,hpa
kubectl -n $ENV rollout status deploy -l app.kubernetes.io/instance=be-payment

# probes and image are what you expect
kubectl -n $ENV get deploy be-payment -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# metrics are being scraped
kubectl -n $ENV get servicemonitor
```

---

## 6. Rollback

```bash
helm history be-payment -n $ENV
helm rollback be-payment <REVISION> -n $ENV --wait --timeout 5m
```

`helmDefaults` deliberately sets `atomic: false` and `cleanupOnFail: false`, so **nothing
rolls back automatically** — a failed release stays for inspection. In CI there is a manual
`deploy:rollback` job (optional `ROLLBACK_REVISION`).

Under Argo CD: `argocd app rollback <app> <ID>`, or `git revert` the tag commit.

---

## 7. Common failure modes

| Symptom | Cause / fix |
|---|---|
| Pods `ImagePullBackOff` | `global.imageRegistry` (from `env-values/<env>/app-values.yaml.gotmpl`) + `IMAGE_TAG` — the image must exist in Harbor for that env. |
| Admission rejects the pod | `require-trusted-registry` is **Enforce** for `dev/staging/prod`: images must come from `harbor.*.example.com/*` or `registry.gitlab.com/myorg/*`. |
| SSL error on the ingress host | `ssl-redirect: true` with no `tls:` block. Every service enabling ingress must set **both** `hosts` and `tls` (see `env-values/prod/app-values.yaml.gotmpl`). |
| App cannot reach Postgres/Redis/Kafka | NetworkPolicy — check `platform/network-policies/manifests/20-database.yaml` and the egress rules in `env-values/<env>/app-values.yaml.gotmpl`. Both halves are required. |
| Config change has no effect | Workload missing the Reloader annotation — see `platform/reloader/README.md`. |
| Argo reverts a helmfile deploy | Both owners active. Fix `APP_TIER_OWNER`. |
| Secret decryption fails | `SOPS_AGE_KEY_FILE` unset, or `env-values/<env>/secrets.enc.yaml` not encrypted. |

---

## 8. Notes

- The gateway is `kong` (ns `infra`, `layer=platform`), not an app-tier release. The
  overlapping `kong-ingress` was deleted — it ran DB-less with no config source, so it
  could never reach Ready. See `platform/kong/README.md`.
- Labels are load-bearing: CI selects infrastructure with `-l layer=platform`, so an app
  labelled `tier: infra` would leak into the platform pipeline — use `tier: gateway` for
  any future app-tier gateway.
- SLO alerts (`prometheusRule`) are defined per service in prod only — extend them as
  services take real traffic.
