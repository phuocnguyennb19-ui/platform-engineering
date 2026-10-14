# MinIO — Deploy

> **Values live in [`infra-base/k8s/platform/minio/`](../../../infra-base/k8s/platform/minio/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

S3-compatible object store. It is the storage backend for **Mimir blocks, Loki chunks,
Tempo traces, Harbor registry and (optionally) Velero** — so it must be up before the
observability and delivery domains.

| | |
|---|---|
| Chart | `minio/minio` |
| Version | `5.4.0` |
| Release / Namespace | `minio` / `database` (created by this release) |
| Selector | `-l name=minio` |
| Labels | `layer=platform, tier=infra, component=storage` |
| Values | `values.yaml.gotmpl` |
| Secrets | `.Values.secrets.minio.*` from `env-values/<env>/secrets.enc.yaml` (SOPS) |
| Blast radius | **High.** Losing MinIO data loses metrics/logs/traces history and the registry. |

Topology by env:

| Env | Mode | Nodes | PVC | Notes |
|---|---|---|---|---|
| dev | `standalone` | 1 | 20Gi | not HA |
| staging | `standalone` | 1 | 50Gi | not HA |
| prod | `distributed` | 4 | 200Gi each | erasure coded, PDB + hard anti-affinity |

---

## 1. Prerequisites

| Requirement | Check |
|---|---|
| Namespaces applied | `kubectl get ns database` |
| SOPS keys present | `sops -d env-values/$ENV/secrets.enc.yaml \| grep -A6 'minio:'` |
| StorageClass with RWO | `kubectl get sc` |
| prod: 4 schedulable nodes | hard anti-affinity means 4 pods need 4 nodes |
| `kube-prometheus-stack` synced | ServiceMonitor CRD |

Required SOPS keys under `secrets.minio`: `rootUser`, `rootPassword`,
`mimirSecretKey`, `lokiSecretKey`, `tempoSecretKey`, `harborSecretKey`.

---

## 2. What this release provisions

Buckets (created by the `mc` post-install job, `purge: false`):

`mimir-blocks`, `mimir-ruler`, `mimir-alerts`, `loki-chunks`, `loki-ruler`,
`loki-admin`, `tempo-traces`, `harbor-registry`, `velero-backups`

Least-privilege service accounts — each consumer gets its own access key and a policy
scoped to its own buckets:

| User | Policy | Consumed by |
|---|---|---|
| `mimir` | `mimir-rw` | `mimir` |
| `loki` | `loki-rw` | `loki` |
| `tempo` | `tempo-rw` | `tempo` |
| `harbor` | `harbor-rw` | `harbor` |

Exposure: the **S3 API stays ClusterIP** (`ingress.enabled: false`); only the console is
exposed at `minio.<ingressDomain>` (TLS outside dev). Do not publish the data plane.

---

## 3. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f platform/minio/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/minio/helmfile.yaml.gotmpl sync
```

MinIO is first in the `data/` domain — `postgresql` declares `needs: [database/minio]`.

---

## 4. Verify

```bash
kubectl -n database get pods -l app=minio
kubectl -n database logs job/minio-post-job --tail=30      # bucket/user provisioning

# buckets + users, from inside the cluster
kubectl -n database run mc --rm -it --restart=Never \
  --image=quay.io/minio/mc:RELEASE.2025-04-08T15-39-49Z -- \
  sh -c 'mc alias set m http://minio.database.svc.cluster.local:9000 "$ROOT_USER" "$ROOT_PASS" && mc ls m && mc admin user list m'

# console
kubectl -n database port-forward svc/minio-console 9001:9001
```

For prod also confirm erasure-set health: `mc admin info m` should list 4 online drives.

---

## 5. Rollback

```bash
helm history minio -n database
helm rollback minio <REVISION> -n database --wait --timeout 10m
```

⚠ **PVCs are not touched by a rollback or an uninstall** — that is deliberate.
Never `helmfile destroy` MinIO in staging/prod without a verified backup: Loki/Mimir/Tempo
history and the Harbor registry live in those volumes.

Changing `mode` between `standalone` and `distributed` is **not** an in-place upgrade —
it requires a data migration (`mc mirror` to a new deployment).

---

## 6. Monitoring & alerting

`metrics.serviceMonitor.enabled: true`, `MINIO_PROMETHEUS_AUTH_TYPE: public` (scrape
without a bearer token — the endpoint is ClusterIP only).

| Signal | Metric |
|---|---|
| Capacity | `minio_cluster_capacity_usable_free_bytes` — alert below 20% |
| Drive health | `minio_cluster_drive_offline_total` > 0 |
| Erasure health (prod) | `minio_cluster_health_erasure_set_status` |
| API errors | `rate(minio_s3_requests_errors_total[5m])` |
| Consumer impact | Loki/Mimir/Tempo write failures spike together when MinIO degrades |

Capacity is the alert that matters most: when MinIO fills up, Loki and Mimir stop
ingesting and you lose observability exactly when you need it.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `minio-post-job` fails | Root credentials mismatch (SOPS re-encrypted after install) or MinIO not Ready yet. Re-run the job. |
| Mimir/Loki log `SignatureDoesNotMatch` / `AccessDenied` | The per-user secret key in `env-values/<env>/secrets.enc.yaml` differs from what the consuming release renders. Both read the same SOPS key — re-sync both. |
| Pods `Pending` in prod | Hard anti-affinity + fewer than 4 nodes. Add nodes or relax to `preferredDuringScheduling`. |
| `Disk not found` after node replacement | PVC bound to a lost node's volume. Restore from backup; do not delete the StatefulSet blindly. |
| Console 404 / TLS error | `minio-console-tls` not issued — check cert-manager and the `minio.<domain>` DNS record. |

---

## 8. Notes / risks

- Image tags are pinned (`RELEASE.2025-04-08T…`). Upgrade MinIO deliberately and read the
  release notes — MinIO has had breaking changes between releases.
- `purge: false` on every bucket: a re-sync will never wipe data. Keep it that way.
- For prod-grade durability, back the `database` namespace PVCs with Velero
  (`velero`) and verify a restore at least once.
