# Upgrading `application` 2.2.x → 2.3.0

Not breaking: `proxy.enabled` defaults to `false`, and with it off every manifest renders
exactly as in 2.2.0 (only the `helm.sh/chart` label changes). Check, before turning it on:

- **The port named `http` moves to the nginx container.** The app must listen on
  `proxy.upstreamPort`, which the chart exposes as `app`; `service.targetPort` is ignored.
  Service, headless Service and Ingress/HTTPRoute keep their ports and now reach nginx.
- **App probes on `port: http` become `port: app`** and keep probing the app directly.
  A probe that names another port, or a number, is left as written — a number equal to
  `proxy.port` would probe nginx, not the app.
- **NetworkPolicy:** the default ingress port is `proxy.port`. A custom
  `networkPolicy.ingress.ports` list is used as given — it must contain `proxy.port`.
- **`lifecycle.preStop` of the app is replaced** by a native `sleep` of
  `proxy.shutdown.appPreStopSleepSeconds` (15). The `sleep` action needs Kubernetes ≥ 1.30;
  on an older cluster set it to `0` and give the app a preStop longer than
  `proxy.shutdown.drainSeconds` yourself.
- **The image must be pullable and admitted.** The default is
  `nginxinc/nginx-unprivileged` by digest under `global.imageRegistry`; mirror it there
  (Kyverno `require-trusted-registry`) or set `proxy.image.registry`/`repository`.
- Enabling it changes the pod template → a normal rolling update of the app pods.

Diff every app before syncing: `helmfile -e <env> -l name=<app> diff`.

---

# Upgrading `application` 2.1.x → 2.2.0

Not breaking for a values file that uses only keys the chart knows. Check, before deploying:

- **Unknown top-level keys now fail the render** (`values.schema.json` root
  `additionalProperties: false`). A misspelled key (`replicaCont: 3`) used to be ignored and the
  default deployed; now `helm template` fails with "additional properties 'replicaCont' not
  allowed". Fix the key, or remove it.
- **`podDisruptionBudget.maxUnavailable: 0` / `minAvailable: 0` are honoured** (also per worker).
  They used to render `maxUnavailable: 1`. `maxUnavailable: 0` blocks every voluntary eviction,
  so node drains wait on that PDB — use it only on purpose.

Diff every app before syncing: `helmfile -e <env> -l name=<app> diff`.

---

# Upgrading `application` 2.0.x → 2.1.0

Not breaking for a values file that pins every image. Check, before deploying:

- **Workers and cronjobs no longer inherit root `initContainers`.** A worker that relied on
  the app's initContainer (rare — usually it ran a migration twice) must declare it in its
  own `initContainers:`. `initContainers: []` on a worker is now redundant but harmless.
- **Images resolve differently where they were wrong before.** An initContainer without
  `image` now runs the app image (registry + digest). A component whose `image.repository`
  differs from the app's no longer inherits the app's tag or digest — it must set its own,
  or the render fails with "image tag/digest could not be resolved".
- **`externalSecret.apiVersion` defaults to `external-secrets.io/v1`.** On an ESO that does
  not serve v1 yet, set `externalSecret.apiVersion: external-secrets.io/v1beta1`.

Diff every app before syncing: `helmfile -e <env> -l name=<app> diff`.

---

# Upgrading `application` 1.x → 2.0.0

**2.0.0 is a breaking release. Read this before touching production.**

The break is deliberate: it fixes a class of bug that is invisible in `helm diff`,
passes every lint, and only surfaces as intermittent connection errors under load.

---

## 1. Why it breaks: selectors are now component-scoped

In 1.x every workload the chart created carried the same two labels:

```yaml
app.kubernetes.io/name: application
app.kubernetes.io/instance: <release>
```

The Service, PodDisruptionBudget and ServiceMonitor selected on exactly those two.
Worker Deployments and CronJob pods carried them too — so **worker and cronjob pods
became endpoints of the application Service**. With a numeric `targetPort` the
EndpointSlice controller adds any matching ready pod regardless of whether the port
exists, and a worker with no readinessProbe is Ready the moment it starts.

Symptom: a share of in-cluster requests fail with connection refused, proportional to
`worker replicas / (app replicas + worker replicas)`. Every pod reports Healthy.

The PDB had the same defect: cronjob pods counted toward the app's availability
budget, so a nightly job could block a node drain.

2.0.0 gives every workload a distinct `app.kubernetes.io/component`
(`app` / `worker` / `cronjob`) and scopes all selectors to it.

### Consequence

`Deployment.spec.selector` and `StatefulSet.spec.selector` are **immutable**.
`helm upgrade` will fail with:

```
field is immutable
```

You must recreate the workload. Pick one:

**Option A — orphan and re-adopt (no downtime, recommended)**

```bash
NS=prod REL=be-user
# Old pods keep serving; only the controller object is removed.
kubectl -n $NS delete deployment $REL --cascade=orphan
helm upgrade $REL oci://<registry>/helm/application --version 2.0.0 -n $NS -f values.yaml
kubectl -n $NS rollout status deployment/$REL
# The new ReplicaSet comes up, then remove the orphaned pods.
kubectl -n $NS delete pod -l app.kubernetes.io/instance=$REL,'!app.kubernetes.io/component'
```

**Option B — uninstall / install (simple, has downtime)**

```bash
helm uninstall $REL -n $NS && helm install $REL ... --version 2.0.0
```

Do this per release, in a maintenance window, lowest-traffic service first.

---

## 2. Required values changes

### `daemonset.enabled` → `workload.kind`

1.x accepted `daemonset.enabled: true`, which disabled the Deployment and created
**nothing** — the application silently disappeared while `helm upgrade` reported
success. There was no `daemonset.yaml` in the chart.

```yaml
# before (broken)
daemonset:
  enabled: true

# after
workload:
  kind: DaemonSet     # Deployment | StatefulSet | DaemonSet
```

### KEDA for queue consumers → `workers[].keda`

In 1.x the ScaledObject always targeted the **application** Deployment. Configuring
it "for a worker" scaled the HTTP surface on queue lag and left the consumer pinned
at its static replica count.

```yaml
# before — scales the app Deployment on Kafka lag (wrong)
keda:
  enabled: true
  triggers:
    - type: kafka
      metadata: { ... }

# after — scales the worker Deployment
workers:
  - name: consumer
    enabled: true
    keda:
      enabled: true
      minReplicaCount: 2
      maxReplicaCount: 20
      triggers:
        - type: kafka
          metadata: { ... }
```

Root-level `keda` still exists and is still valid — for scaling the app workload
itself on an external metric.

### `securityDefaults` now actually applies

The `securityDefaults` block and its two merge helpers existed in 1.x but **no
template ever called them**. Anything set there was silently ignored.

It is now wired into every container. The chart also ships hardened values by
default (non-root, read-only rootfs, dropped capabilities, seccomp RuntimeDefault).

Check what this changes for you before rolling out:

```bash
helm template <rel> <chart> -f values.yaml | yq '.spec.template.spec.containers[].securityContext'
```

If a service genuinely needs to write to its root filesystem or run as root, say so
explicitly:

```yaml
securityContext:
  readOnlyRootFilesystem: false
```

Note that with `readOnlyRootFilesystem: true` most applications need `/tmp` as a
volume — `extraVolumes` + `extraVolumeMounts`.

### `image.tag: latest` is now rejected

There is no `latest` fallback; an unresolvable reference fails the render instead of
shipping a floating tag. Resolution order is `digest` → `tag` → `Chart.AppVersion`.

### CronJob schedules now honour a timezone

`cronjobDefaults.timeZone` defaults to `Asia/Ho_Chi_Minh` and is rendered as
`spec.timeZone`. In 1.x the schedule was evaluated in **UTC** — a `TZ` env var only
affects the process, never the scheduler, so `0 2 * * *` fired at 09:00 local.

**Your jobs will move by the UTC offset after this upgrade.** If a job must keep
firing at the old wall-clock time, set `timeZone: Etc/UTC` on it.

### NetworkPolicy allows same-namespace traffic by default

`networkPolicy.ingress.allowSameNamespace` and `egress.allowSameNamespace` default
to `true`, adding a `podSelector: {}` peer.

Once an ingress rule carries a `from` list, **only** those peers are allowed —
same-namespace traffic is not implicit. A policy listing only `infra` and
`observability` silently drops every service-to-service call inside the namespace.
If you rely on that isolation, set the flag to `false` explicitly.

---

## 3. New capabilities (all optional, all default off)

| Area | Values key |
|---|---|
| StatefulSet / DaemonSet | `workload.kind`, `workload.statefulset.volumeClaimTemplates` |
| Rollout tuning | `workload.strategy`, `minReadySeconds`, `progressDeadlineSeconds`, `revisionHistoryLimit` |
| Per-worker scaling & exposure | `workers[].{keda,autoscaling,podDisruptionBudget,service,serviceMonitor}` |
| HPA anti-flapping | `autoscaling.behavior` (on by default, 5m scale-down window) |
| VPA | `verticalPodAutoscaler` |
| RBAC | `rbac.rules`, `rbac.clusterRules` |
| Secret rotation | `reloader`, `externalSecret.injectEnvFrom` |
| `valueFrom` env | `envRaw` |
| gRPC routing | `grpcRoute` |
| Baseline SLO alerts | `prometheusRule.defaultRules` |
| Post-deploy gate | `tests` → `helm test <release>` |
| Arbitrary manifests | `extraObjects` |
| Key-name validation | `values.schema.json` |

---

## 4. Render-time validation

The chart now fails the render instead of shipping a broken object. Guards:

- `autoscaling` + `keda` both enabled
- PDB with both `minAvailable` and `maxUnavailable`
- invalid `workload.kind`; autoscaling on a DaemonSet
- a non-null probe with no handler (`httpGet`/`exec`/`tcpSocket`/`grpc`)
- `serviceMonitor` without a Service
- `ingress` and `httpRoute` both enabled; `ingress` without hosts
- `keda` without triggers; worker/cronjob without a name or schedule
- `image.tag: latest`, unresolvable image reference

Plus `values.schema.json`, which rejects misspelled keys — the failure mode
`helmfile`'s `missingFileHandler: Warn` otherwise turns into a silent default.

---

## 5. Verification checklist

```bash
NS=prod REL=be-notification

# Worker pods must NOT appear in the app Service endpoints
kubectl -n $NS get endpointslice -l kubernetes.io/service-name=$REL -o yaml | grep -c targetRef
kubectl -n $NS get pod -l app.kubernetes.io/instance=$REL -L app.kubernetes.io/component

# KEDA targets the worker Deployment
kubectl -n $NS get scaledobject -o custom-columns=NAME:.metadata.name,TARGET:.spec.scaleTargetRef.name

# securityContext is really applied
kubectl -n $NS get deploy $REL -o jsonpath='{.spec.template.spec.containers[0].securityContext}'

# Same-namespace traffic works
kubectl -n $NS exec deploy/be-payment -- nc -zv $REL 80

# CronJob timezone
kubectl -n $NS get cronjob -o custom-columns=NAME:.metadata.name,SCHEDULE:.spec.schedule,TZ:.spec.timeZone

helm test $REL -n $NS
```

## 6. Rollback

2.0.0 does not migrate data or change any Secret/ConfigMap contents, so rollback is
a chart-version rollback — but it hits the same immutable-selector wall in reverse:

```bash
kubectl -n $NS delete deployment $REL --cascade=orphan
helm rollback $REL <previous-revision> -n $NS
```

Keep the 1.1.0 chart available in the OCI registry until every release is on 2.x.
