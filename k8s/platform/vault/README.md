# HashiCorp Vault — Deploy

> **Values live in [`infra-base/k8s/platform/vault/`](../../../infra-base/k8s/platform/vault/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Secrets management: dynamic secrets, PKI, transit encryption. Backend for the External
Secrets Operator and (in prod) the Vault Agent Injector.

| | |
|---|---|
| Chart | `hashicorp/vault` |
| Version | `0.30.0` |
| Release / Namespace | `vault` / `vault` (created by this release) |
| Selector | `-l name=vault` |
| Labels | `layer=platform, tier=infra, component=secrets` |
| Values | `values.yaml.gotmpl` + `files/policies/*.hcl` |
| TLS | Secret `vault-tls`, issued by cert-manager from `platform/vault/manifests/certificate.yaml` |

| Env | Topology | Replicas | Storage | Unseal |
|---|---|---|---|---|
| dev | HA Raft | 1 | 5Gi | manual |
| staging | HA Raft | 1 | 8Gi | manual |
| prod | HA Raft | 3 + anti-affinity | 20Gi | **auto-unseal (AWS KMS)** |

Note: even dev runs **real** Vault with integrated storage — not `-dev` mode — so data
persists and the unseal workflow is exercised.

---

## 1. Prerequisites — the certificate comes first

```bash
# cert-manager must be Ready, then issue Vault's TLS material BEFORE syncing Vault
kubectl wait --for=condition=Available deploy/cert-manager-webhook -n infra --timeout=180s
kubectl apply -f platform/vault/manifests/certificate.yaml
kubectl wait --for=condition=Ready certificate/vault-tls -n vault --timeout=180s
```

Skipping this leaves the Vault pod stuck in `ContainerCreating` — it mounts `vault-tls`
under `/vault/userconfig/vault-tls`.

For **prod auto-unseal**, both variables must be set or the `seal` stanza is omitted
entirely (a literal `<KMS_KEY_ID>` placeholder produces HCL Vault rejects at startup):

| Variable | Effect if missing |
|---|---|
| `VAULT_KMS_KEY_ID` | no seal stanza → Vault starts **sealed**, needs manual unsealing |
| `AWS_ACCOUNT_ID` | IRSA role ARN for the auto-unseal service account is wrong |
| `AWS_REGION` | defaults to `ap-southeast-1` |

---

## 2. Deploy

```bash
export ENV=prod
export VAULT_KMS_KEY_ID=<kms-key-id>
export AWS_ACCOUNT_ID=<account>
export AWS_REGION=ap-southeast-1

helmfile -e $ENV -f platform/vault/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/vault/helmfile.yaml.gotmpl sync
```

---

## 3. Initialise and unseal (first install only)

```bash
kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=5 -key-threshold=3
```

🔴 **The output contains the unseal keys and the initial root token. They are printed
exactly once.** Store them in an offline secret manager (not git, not a ticket, not this
repo). Distribute the key shares to separate holders.

```bash
# dev/staging (manual unseal — repeat with 3 different keys)
kubectl -n vault exec -it vault-0 -- vault operator unseal <key-1>
kubectl -n vault exec -it vault-0 -- vault operator unseal <key-2>
kubectl -n vault exec -it vault-0 -- vault operator unseal <key-3>

# prod with KMS auto-unseal: pods unseal themselves; join the other Raft peers
kubectl -n vault exec -it vault-1 -- vault operator raft join https://vault-0.vault-internal:8200
kubectl -n vault exec -it vault-2 -- vault operator raft join https://vault-0.vault-internal:8200
```

Then load the policies kept in git and enable Kubernetes auth:

```bash
kubectl -n vault exec -i vault-0 -- vault policy write admin   - < platform/vault/files/policies/admin.hcl
kubectl -n vault exec -i vault-0 -- vault policy write eso-read - < platform/vault/files/policies/eso-read.hcl
kubectl -n vault exec -it vault-0 -- vault auth enable kubernetes
```

Revoke the initial root token once a real auth method works.

---

## 4. Verify

```bash
kubectl -n vault get pods
kubectl -n vault exec -it vault-0 -- vault status         # Sealed: false, HA Mode: active
kubectl -n vault exec -it vault-0 -- vault operator raft list-peers    # prod: 3 voters
kubectl -n vault exec -it vault-0 -- vault policy list
```

Then confirm the consumer side: an ESO `SecretStore` pointing at Vault reports
`Valid=True` (see `platform/external-secrets/README.md`).

---

## 5. Rollback & disaster recovery

```bash
helm history vault -n vault
helm rollback vault <REVISION> -n vault --wait
```

⚠ Vault-specific hazards:

- A rollback **restarts pods, which re-seals them** unless auto-unseal is configured.
  Have the unseal keys in hand before touching a manually-unsealed Vault.
- Raft data lives in the PVCs. Deleting them destroys all secrets — Helm will not warn you.
- Reducing the replica count below the Raft quorum (3 → 1 in prod) makes the cluster
  unavailable. Remove peers explicitly with `vault operator raft remove-peer` first.

Take Raft snapshots on a schedule and store them off-cluster:

```bash
kubectl -n vault exec vault-0 -- vault operator raft snapshot save /tmp/vault-$(date +%F).snap
kubectl -n vault cp vault-0:/tmp/vault-$(date +%F).snap ./vault-$(date +%F).snap
# restore: vault operator raft snapshot restore <file>
```

---

## 6. Monitoring & alerting

| Signal | Metric |
|---|---|
| **Sealed** | `vault_core_unsealed == 0` — page immediately |
| Leadership | `vault_core_leadership_lost_count`, no active node |
| Raft health | `vault_raft_storage_entry_count`, peer count |
| Token/lease pressure | `vault_expire_num_leases` |
| Request errors | `vault_core_handle_request` latency + 5xx |
| Audit device failure | Vault **stops serving** if audit logging fails — alert on it |

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod `ContainerCreating` forever | `vault-tls` Secret missing — apply `platform/vault/manifests/certificate.yaml`. |
| Vault up but `Sealed: true` (prod) | `VAULT_KMS_KEY_ID` was not set at sync time → no seal stanza. Set it and re-sync. |
| `failed to unseal: invalid key` | Wrong or reordered unseal key shares. |
| Standby pods not joining | Raft join not run, or TLS SANs do not cover `vault-N.vault-internal`. |
| ESO cannot authenticate | Kubernetes auth method not enabled, or the role/policy binding is missing. |
| 503 during a rolling upgrade | Normal leader election gap. Prod's 3 replicas keep it short; single-replica envs will drop requests. |

---

## 8. Notes / risks

- **No secret is provisioned at deploy time** — Vault is the source of truth, not a
  consumer of SOPS. That is why this release has no SOPS keys.
- The migration path for app secrets is: SOPS → ESO `SecretStore` → Vault. See
  `apps/be-payment/README.md` and `platform/external-secrets/manifests/example-secretstore.yaml`.
- Enable an audit device before real use, and monitor it: a full/failed audit sink causes
  Vault to reject requests by design.
