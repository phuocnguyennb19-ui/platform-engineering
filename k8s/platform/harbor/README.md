# Harbor — Deploy

> **Values live in [`infra-base/k8s/platform/harbor/`](../../../infra-base/k8s/platform/harbor/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Private container/OCI and Helm registry with image scanning. Also the **Bitnami image
mirror** (proxy-cache project) that the data-store charts pull through.

| | |
|---|---|
| Chart | `harbor/harbor` |
| Version | `1.17.0` |
| Release / Namespace | `harbor` / `harbor` (created by this release) |
| Selector | `-l name=harbor` |
| Labels | `layer=platform, tier=infra, component=registry` |
| Values | `values.yaml.gotmpl` |
| URL | `https://harbor.<ingressDomain>` |
| Replicas | 1 (dev/staging), 2 (prod) |

Harbor **reuses the shared platform stores** instead of bundling its own:

| Component | Backed by |
|---|---|
| database | `postgresql` (`postgresql.database.svc`, db `registry`) |
| cache | `redis` |
| storage | `minio` (bucket `harbor-registry`, user `harbor`) |
| scanner | bundled Trivy |

That means **Harbor is last in the deploy order** — it needs data + infra to exist first.

---

## 1. Prerequisites

| Requirement | Check |
|---|---|
| PostgreSQL up, database `registry` created | `kubectl -n database exec postgresql-0 -- psql -U postgres -c '\l'` |
| Redis up | `redis` synced |
| MinIO up with the `harbor-registry` bucket + `harbor` user | `minio` synced |
| ingress-nginx + cert-manager | for `harbor.<domain>` and the `harbor-tls` Secret |
| SOPS keys | `secrets.harbor.*` (admin password) and `secrets.minio.harborSecretKey` |
| NetworkPolicy allows `harbor` → `database` | otherwise core crashes on startup |

Create the database if it does not exist:

```bash
kubectl -n database exec -it postgresql-0 -- psql -U postgres -c 'CREATE DATABASE registry;'
```

---

## 2. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f platform/harbor/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/harbor/helmfile.yaml.gotmpl sync
```

Ingress notes: `proxy-body-size: "0"` (image layers are large) and `ssl-redirect` on
outside dev. TLS uses the `harbor-tls` Secret (`certSource: secret`).

---

## 3. Post-install configuration

```bash
# login
PASS=$(kubectl -n harbor get secret harbor-admin -o jsonpath='{.data.password}' | base64 -d)
docker login harbor.$INGRESS_DOMAIN -u admin -p "$PASS"
```

Then, in the UI or via the API:

1. **Projects**: `library` (apps), `helm` (charts), `bitnami` (**proxy cache** → docker.io).
2. **Robot accounts** for CI and for the cluster's image pull secrets — never use `admin`.
3. **Vulnerability policy**: block pulls of images with Critical CVEs.
4. **Retention + garbage collection** schedule — without it the MinIO bucket grows forever.

The `bitnami` proxy-cache project is what closes the 2025 Bitnami gap: set
`global.imageRegistry: harbor.<domain>` on `data/*` releases so they pull pinned images
through the mirror.

---

## 4. Verify

```bash
kubectl -n harbor get pods
kubectl -n harbor rollout status deploy/harbor-core --timeout=600s

curl -sk https://harbor.$INGRESS_DOMAIN/api/v2.0/health | jq

# round trip
docker pull alpine:3.20
docker tag alpine:3.20 harbor.$INGRESS_DOMAIN/library/alpine:3.20
docker push harbor.$INGRESS_DOMAIN/library/alpine:3.20
docker pull harbor.$INGRESS_DOMAIN/library/alpine:3.20
```

All components in `/api/v2.0/health` must be `healthy` — that endpoint checks the external
database, Redis and object storage too, which makes it the single best smoke test.

---

## 5. Rollback

```bash
helm history harbor -n harbor
helm rollback harbor <REVISION> -n harbor --wait --timeout 15m
```

⚠ Harbor-specific hazards:

- **Images and charts live in MinIO; metadata lives in PostgreSQL.** A rollback that
  reverts a schema migration can desynchronise the two. Back up the `registry` database
  before upgrading:
  ```bash
  kubectl -n database exec postgresql-0 -- pg_dump -U postgres -Fc registry > registry-$(date +%F).dump
  ```
- Harbor does not support downgrades across major versions — the database schema is
  migrated forward only.
- Never point two Harbor instances at the same bucket + database.

---

## 6. Monitoring & alerting

| Signal | Check |
|---|---|
| Health endpoint | `/api/v2.0/health` — all components healthy |
| Core availability | `up` on harbor-core / registry pods |
| Storage growth | MinIO bucket `harbor-registry` size trend |
| Scan findings | Critical CVEs in pushed images (Harbor's own scan reports) |
| GC job results | failed garbage collection = unbounded storage growth |
| Pull/push errors | ingress-nginx 5xx on the `harbor.<domain>` host |

Because the platform pulls images through Harbor, **a Harbor outage becomes a
cluster-wide deploy outage**. Treat its availability as tier-1.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `harbor-core` `CrashLoopBackOff` connecting to the DB | Database `registry` missing, wrong credentials, or the `database` NetworkPolicy blocks namespace `harbor`. |
| Push fails with `413 Request Entity Too Large` | `proxy-body-size` not `0` on the ingress. |
| Push succeeds, pull returns 404 | Object storage misconfigured — check the MinIO credentials/bucket. |
| `x509: certificate signed by unknown authority` on docker login | `harbor-tls` issued by the LE **staging** issuer, or a self-signed cert not trusted by the client. |
| Proxy-cache project returns 401 | Docker Hub rate limit / missing upstream credentials on the proxy project. |
| Storage keeps growing | Retention policy and garbage collection not scheduled. |
| Kyverno blocks app pods | `require-trusted-registry` **Enforce** expects `harbor.*.example.com/*` — good; push the image to Harbor. |

---

## 8. Notes

- Harbor is a hard dependency for the app tier once `require-trusted-registry` is enforced.
  Plan its HA (2 replicas in prod, shared stores already HA) accordingly.
- It also hosts the `application` Helm chart if you prefer OCI over ECR — see
  `README.md` for how `CHART_REGISTRY` / `HELM_CHART_ACCOUNT_ID` resolve.
- Registry scanning (Harbor/Trivy) and runtime scanning (`trivy-operator`) answer
  different questions. Keep both.
