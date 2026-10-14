# Velero — Deploy

> **Values live in [`infra-base/k8s/platform/velero/`](../../../infra-base/k8s/platform/velero/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Cluster and persistent-volume backup / disaster recovery to S3. This is the release that
decides whether a lost cluster is a bad afternoon or a company-level incident.

| | |
|---|---|
| Chart | `vmware-tanzu/velero` |
| Version | `12.1.0` |
| Release / Namespace | `velero` / `velero` (created by this release) |
| Selector | `-l name=velero` |
| Labels | `layer=platform, tier=infra, component=backup` |
| Values | `values.yaml.gotmpl` |
| Plugin | `velero/velero-plugin-for-aws:v1.11.0` (init container) |
| Node agent | `deployNodeAgent: true` (Kopia file-level PV backup) |
| Schedule | `daily-full` at `02:00`, all namespaces |
| Retention | prod `720h` (30d) · non-prod `168h` (7d) |

---

## 1. Prerequisites

| Requirement | Note |
|---|---|
| **S3 bucket exists** | `velero-backups-<env>` — Velero does **not** create it |
| IRSA role | `arn:aws:iam::<ACCOUNT_ID>:role/velero-<env>` — **replace the placeholder** |
| IAM permissions | S3 read/write on the bucket + `ec2:CreateSnapshot`, `DescribeVolumes`, `DescribeSnapshots` |
| `velero` namespace, PSA **privileged** | node-agent mounts hostPath |
| CSI snapshot support (optional) | for volume snapshots; Kopia covers PVCs without it |

`credentials.useSecret: false` — IRSA only, no static keys. If the annotation is not
replaced, every backup fails with `AccessDenied`.

---

## 2. Deploy

```bash
export ENV=prod
helmfile -e $ENV -f platform/velero/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/velero/helmfile.yaml.gotmpl sync
```

---

## 3. Verify — and actually test a restore

```bash
kubectl -n velero rollout status deploy/velero --timeout=300s
kubectl -n velero get ds node-agent

velero backup-location get          # PHASE must be Available
velero schedule get
velero backup get
```

**A backup you have never restored is not a backup.** Run this drill after install and on a
schedule:

```bash
# 1. on-demand backup of one namespace
velero backup create drill-$(date +%F) --include-namespaces dev --wait

# 2. restore it into a scratch namespace
velero restore create --from-backup drill-$(date +%F) \
  --namespace-mappings dev:dev-restore-test --wait

# 3. check the data, then clean up
kubectl -n dev-restore-test get pods,pvc
kubectl delete ns dev-restore-test
```

---

## 4. What is protected

| Layer | Covered by |
|---|---|
| Kubernetes objects (all namespaces) | daily-full schedule |
| PV data | node-agent (Kopia) file-level backup |
| Databases | PV-level only — **not** application-consistent. Take logical dumps too (see `platform/postgresql/README.md`) |
| Sealed Secrets keys | included via the `infra` namespace — critical, see `platform/sealed-secrets/README.md` |
| Vault data | Raft snapshots are a **separate** procedure, not Velero's job |

---

## 5. Rollback / restore

Chart rollback:

```bash
helm history velero -n velero
helm rollback velero <REVISION> -n velero --wait
```

Existing backups live in S3 and are unaffected by a chart rollback — they are readable by
any Velero pointed at the same bucket, which is what makes cluster rebuild possible.

Full-cluster restore (DR):

```bash
# on the new cluster, after installing Velero against the SAME bucket
velero backup get
velero restore create --from-backup <backup-name> --wait
velero restore describe <restore-name>
velero restore logs <restore-name>
```

Restore order matters: CRDs and namespaces first (Velero handles this), then rebuild
platform releases with helmfile rather than restoring them, and use Velero mainly for
**data** and app state.

---

## 6. Monitoring & alerting

`metrics.serviceMonitor.enabled: true`.

| Signal | Metric |
|---|---|
| **Backup failures** | `velero_backup_failure_total` — page on this |
| Partial failures | `velero_backup_partial_failure_total` |
| Last successful backup age | `velero_backup_last_successful_timestamp` > 26h = missed the daily |
| Backup duration | `velero_backup_duration_seconds` trending up = growing dataset |
| Restore failures | `velero_restore_failed_total` |
| Storage location | backup location `Available` |

The most dangerous failure mode is a schedule that quietly stopped running. Alert on the
**age of the last successful backup**, not just on failures.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Backup `PartiallyFailed` | Usually PVCs the node-agent could not read; `velero backup logs <name>` names them. |
| `AccessDenied` on S3 | IRSA placeholder not replaced, bucket missing, or wrong region. |
| Backup location `Unavailable` | Bucket/credentials wrong — `velero backup-location get` then check the Velero pod logs. |
| node-agent pods missing | `velero` namespace not `privileged`, or nodes tainted. |
| Restore leaves pods `Pending` | StorageClass name differs on the target cluster — use `--namespace-mappings` and a StorageClass mapping ConfigMap. |
| Snapshots not created | CSI driver lacks VolumeSnapshotClass; Kopia file backup still works. |
| Backups huge / slow | `includedNamespaces: "*"` includes everything. Exclude noisy namespaces or large ephemeral PVCs. |

---

## 8. Notes / risks

- The daily schedule covers **all** namespaces. That is a safe default but it grows fast —
  review bucket size monthly against the retention TTL.
- Velero backs up PV *data*, not database *consistency*. For Postgres/Kafka/ClickHouse,
  pair it with the engine's own dump/snapshot mechanism.
- On-prem/local clusters: point the backup location at MinIO (`minio`, bucket
  `velero-backups`) instead of AWS S3 — but then MinIO itself must not be the only copy.
- Document and rehearse the DR runbook. The failure you have not practised is the one that
  will not work.
