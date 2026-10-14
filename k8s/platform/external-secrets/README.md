# External Secrets Operator — Deploy

> **Values live in [`infra-base/k8s/platform/external-secrets/`](../../../infra-base/k8s/platform/external-secrets/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Syncs secrets from an external store (Vault, AWS Secrets Manager, GCP Secret Manager) into
Kubernetes Secrets, so credentials never live in git.

| | |
|---|---|
| Chart | `external-secrets/external-secrets` |
| Version | `2.8.0` |
| Release / Namespace | `external-secrets` / `infra` |
| Selector | `-l name=external-secrets` |
| Labels | `layer=platform, tier=infra, component=secrets` |
| Values | `values.yaml.gotmpl` |
| CRDs | `installCRDs: true` |
| Replicas | 1 (dev/staging), 2 (prod) — controller, webhook and cert-controller each |

---

## 1. Prerequisites

- `infra` namespace (PSA `baseline`).
- `kube-prometheus-stack` for the ServiceMonitor CRD.
- A backend to read from — usually `vault` — reachable from the cluster.
- For AWS Secrets Manager: an IRSA role on the ESO service account.

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f platform/external-secrets/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/external-secrets/helmfile.yaml.gotmpl sync
```

A `(Cluster)SecretStore` is **cluster-specific config** (backend URL + auth), so it is not
part of the release. Create it once the operator is Ready:

```bash
kubectl apply -f platform/external-secrets/manifests/example-secretstore.yaml
```

---

## 3. Verify

```bash
kubectl -n infra get pods -l app.kubernetes.io/name=external-secrets
kubectl get crd | grep external-secrets.io

# the store must validate BEFORE any ExternalSecret can work
kubectl get clustersecretstore,secretstore -A
kubectl describe clustersecretstore vault-backend | grep -A3 Conditions   # Valid=True
```

End-to-end test:

```bash
kubectl -n dev get externalsecret
kubectl -n dev describe externalsecret <name>      # SecretSynced=True
kubectl -n dev get secret <target-name>            # the Secret ESO created
```

---

## 4. Rollback

```bash
helm history external-secrets -n infra
helm rollback external-secrets <REVISION> -n infra --wait
```

- Secrets ESO already created **remain** in the cluster when the operator is down —
  running workloads are unaffected. What stops is *refresh*: rotated credentials in Vault
  no longer reach the cluster.
- Uninstalling with CRD removal deletes every `ExternalSecret` object. The derived
  Kubernetes Secrets survive only if `deletionPolicy` is not `Delete`. Check before
  uninstalling.

---

## 5. Monitoring & alerting

`serviceMonitor.enabled: true`.

| Signal | Metric |
|---|---|
| Sync failures | `externalsecret_status_condition{condition="Ready",status="false"}` |
| Store validity | `clustersecretstore_status_condition{condition="Valid",status="false"}` |
| Backend errors | `externalsecret_sync_calls_error` |
| Staleness | time since last successful sync per ExternalSecret |
| Webhook health | `up{job=~".*external-secrets.*webhook.*"}` |

A silently failing sync is the dangerous case: pods keep running with **stale** credentials
until a rotation invalidates them. Alert on `Ready=false`, not just on pod health.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `SecretStore validation failed` | Backend unreachable, or the auth method (Kubernetes auth in Vault) is not enabled/bound. |
| `permission denied` from Vault | The ESO role lacks the `eso-read` policy — see `platform/vault/files/policies/eso-read.hcl`. |
| ExternalSecret Ready but the Secret is empty | Wrong `remoteRef.key`/`property`, or the value is nested JSON that needs `property`. |
| Webhook timeout on apply | Webhook pod not Ready, or a NetworkPolicy blocks API server → `infra`. |
| Secret not refreshing | `refreshInterval` too long, or the operator is down. |
| App still uses the old password | The Secret changed but the pod did not restart — annotate the workload for Reloader (`reloader`). |

---

## 7. Notes / migration path

This platform currently keeps app secrets in **SOPS** (`env-values/<env>/secrets.enc.yaml`, rendered by
helmfile). ESO is the target state:

1. Deploy Vault + ESO, create a `ClusterSecretStore` with Kubernetes auth.
2. Write the app's secrets into Vault under a per-service path.
3. In the app values, set `externalSecret.enabled: true` (supported by
   `charts/application/templates/config/externalsecret.yaml`) and delete `secrets.yaml.gotmpl`.
4. The app needs **no change** — it still reads the same keys via `envFrom`.

Do it per service, and verify the generated Secret matches the old one key-for-key before
removing the SOPS file.
