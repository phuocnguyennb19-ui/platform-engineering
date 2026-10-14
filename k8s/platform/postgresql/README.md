# PostgreSQL — Deploy

> **Values live in [`infra-base/k8s/platform/postgresql/`](../../../infra-base/k8s/platform/postgresql/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Primary relational store, shared by the app tier (`appdb`) and Harbor (`registry`).

| | |
|---|---|
| Chart | `bitnami/postgresql` |
| Version | `16.7.4` |
| Release / Namespace | `postgresql` / `database` |
| Selector | `-l name=postgresql` |
| Labels | `layer=platform, tier=infra, component=database` |
| Values | `values.yaml.gotmpl` + `files/postgresql.conf` + `files/pg_hba.conf` |
| Needs | `database/minio` (intra-domain) |
| Secrets | `.Values.secrets.postgresql.{postgresPassword,password,replicationPassword}` |
| Blast radius | **Critical.** Every backend service and Harbor depend on it. |

| Env | Architecture | Replicas | Storage | max_connections | shared_buffers |
|---|---|---|---|---|---|
| dev | standalone | 0 | 10Gi | 100 | 128MB |
| staging | standalone | 0 | 20Gi | 150 | 256MB |
| prod | replication | 2 read replicas | 100Gi | 300 | 1GB, `ssl=on` |

---

## 1. Prerequisites

| Requirement | Note |
|---|---|
| `database` namespace | `platform/bootstrap/manifests/namespaces.yaml` |
| MinIO synced | declared `needs` |
| SOPS keys | `postgresPassword`, `password`, `replicationPassword` under `secrets.postgresql` |
| StorageClass (RWO) | prod: use a class backed by fast SSD (`gp3`) |
| **Bitnami registry decision** | see below |

> ⚠ **Bitnami images (2025+)**: `docker.io/bitnami` now publishes only `latest`; pinned
> tags moved to the paid `bitnamisecure` repo. For prod, mirror images into Harbor
> (proxy-cache project `bitnami`) and set `global.imageRegistry: harbor.<domain>`.
> Deploying prod against `docker.io` with an unpinned tag is a supply-chain risk and will
> be blocked by the Kyverno `disallow-latest-tag` policy.

---

## 2. Configuration map

| Where | Owns |
|---|---|
| `values.yaml.gotmpl` | architecture, sizing, HA, replicas, metrics |
| `files/postgresql.conf` | static tunables: logging, WAL, hardening (read via `readFile`) |
| `files/pg_hba.conf` | client auth rules |
| `$size` table | per-env `max_connections`, `shared_buffers`, `effective_cache_size` |
| SOPS `env-values/<env>/secrets.enc.yaml` | all passwords — rendered into the `postgresql` Secret via `extraDeploy` |

Credentials are never inlined in values: the chart consumes `existingSecret: postgresql`,
and that Secret is rendered from SOPS.

---

## 3. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f platform/postgresql/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/postgresql/helmfile.yaml.gotmpl sync
```

**Always run `diff` first.** A changed `architecture` or PVC size shows up here and both
are disruptive (see Rollback).

---

## 4. Verify

```bash
kubectl -n database rollout status statefulset/postgresql --timeout=600s
kubectl -n database get pods -l app.kubernetes.io/name=postgresql

# connectivity + auth
PGPASSWORD=$(kubectl -n database get secret postgresql -o jsonpath='{.data.password}' | base64 -d)
kubectl -n database run psql --rm -it --restart=Never --image=postgres:16-alpine -- \
  psql "postgresql://appuser:$PGPASSWORD@postgresql.database.svc.cluster.local:5432/appdb" -c '\l'

# prod: replication healthy
kubectl -n database exec -it postgresql-0 -- \
  psql -U postgres -c 'SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;'
```

Expect `state=streaming` for each replica and `replay_lag` near zero.

---

## 5. Rollback & data safety

```bash
helm history postgresql -n database
helm rollback postgresql <REVISION> -n database --wait --timeout 15m
```

What a rollback does **not** fix:

- **PVC size**: volumes only grow. A rollback to a smaller `storage` value leaves the
  larger PVC in place (harmless) but the reverse is impossible.
- **`architecture` change** (`replication` → `standalone`): read replicas are removed;
  their data is discarded. Verify the primary is authoritative first.
- **Data**: nothing in Helm restores rows. Restore comes from Velero PV snapshots or a
  logical dump.

Take a dump before any risky change:

```bash
kubectl -n database exec postgresql-0 -- \
  pg_dump -U postgres -Fc appdb > appdb-$(date +%F).dump
```

---

## 6. Backup / DR

- **PV-level**: Velero daily schedule (`velero`, `0 2 * * *`) covers the
  `database` namespace. Verify a restore into a scratch namespace at least once.
- **Logical**: run a `pg_dump` CronJob for point-in-time-ish recovery of individual tables.
- **PITR**: pgBackRest/WAL archiving to MinIO is out of scope for this chart. If prod
  needs true PITR, graduate to the **CloudNativePG** operator.

---

## 7. Monitoring & alerting

`metrics.enabled: true` + ServiceMonitor (`release: kube-prometheus-stack`).

| Signal | Metric |
|---|---|
| Availability | `pg_up` |
| Connection saturation | `sum(pg_stat_activity_count) / pg_settings_max_connections` > 0.8 |
| Replication lag (prod) | `pg_replication_lag_seconds` > 30 |
| Deadlocks | `rate(pg_stat_database_deadlocks[5m])` |
| Cache hit ratio | `pg_stat_database_blks_hit / (blks_hit + blks_read)` < 0.95 |
| Disk | PVC used % > 80 |

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod `CrashLoopBackOff`, `password authentication failed` | SOPS password changed after the PVC was initialised — Postgres keeps the *old* password in its data dir. Reset with `ALTER USER`, or wipe the PVC (dev only). |
| `FATAL: sorry, too many clients` | `max_connections` exceeded. Add PgBouncer rather than raising it indefinitely. |
| Harbor cannot connect | `database` NetworkPolicy blocking the `harbor` namespace — see `platform/bootstrap/README.md`. |
| Replica stuck `catching up` | WAL retention too small or network saturated; check `wal_keep_size`. |
| Pull error / `latest` blocked by Kyverno | Bitnami registry issue — configure the Harbor mirror. |
| Pod `Pending` | PVC cannot bind; check the StorageClass. |

---

## 9. Notes

- The app tier connects with `DB_SSLMODE: require` (`apps/be-payment/config.yaml`), and
  `ssl` is only `on` in prod — dev/staging connections fall back accordingly.
- For a large multi-tenant prod, CloudNativePG gives you failover, PITR and backups as
  first-class features; this chart is a good fit up to a single-primary workload.
