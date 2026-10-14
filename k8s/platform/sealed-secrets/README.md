# Sealed Secrets — Deploy

> **Values live in [`infra-base/k8s/platform/sealed-secrets/`](../../../infra-base/k8s/platform/sealed-secrets/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Lets you commit encrypted secrets to git: `kubeseal` encrypts a Secret with the
controller's public certificate, producing a `SealedSecret` CR that only the in-cluster
controller can decrypt.

| | |
|---|---|
| Chart | `sealed-secrets/sealed-secrets` |
| Version | `2.17.0` |
| Release / Namespace | `sealed-secrets` / `infra` |
| Selector | `-l name=sealed-secrets` |
| Labels | `layer=platform, tier=infra, component=secrets` |
| Values | `values.yaml.gotmpl` |
| Image | `bitnami/sealed-secrets-controller:0.30.0` (pinned) |
| Key rotation | `keyrenewperiod: 720h` (30d), old keys retained |

Complements SOPS/ESO/Vault: good for GitOps-committed secrets that do not warrant a full
Vault path.

---

## 1. Prerequisites

- `infra` namespace.
- `kubeseal` CLI locally, matching the controller version.

---

## 2. 🔴 Back up the sealing key — do this first

The controller generates a sealing keypair and rotates it every 30 days, keeping old keys
so previously sealed secrets still decrypt. **If those keys are lost, every SealedSecret in
git becomes permanently undecryptable.**

```bash
# back up ALL sealing keys
kubectl -n infra get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-keys-backup.yaml     # store OFFLINE, encrypted — never in this repo
```

Also ensure Velero includes the `infra` namespace (`velero` backs up `*`).
Verify the restore path at least once — an untested backup is not a backup.

---

## 3. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f platform/sealed-secrets/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/sealed-secrets/helmfile.yaml.gotmpl sync
```

---

## 4. Usage

```bash
# fetch the public cert once (safe to commit)
kubeseal --controller-name sealed-secrets --controller-namespace infra \
  --fetch-cert > sealed-secrets-pub.pem

# seal a secret
kubectl -n dev create secret generic my-app --dry-run=client \
  --from-literal=API_KEY=supersecret -o yaml \
| kubeseal --cert sealed-secrets-pub.pem -o yaml > my-app/sealedsecret.yaml

kubectl apply -f my-app/sealedsecret.yaml
```

Scope matters: by default a SealedSecret is bound to its **namespace and name**. Use
`--scope namespaced` or `cluster-wide` deliberately — cluster-wide sealing removes that
protection.

---

## 5. Verify

```bash
kubectl -n infra rollout status deploy/sealed-secrets --timeout=180s
kubectl get crd sealedsecrets.bitnami.com

kubectl -n dev get sealedsecret
kubectl -n dev get secret my-app          # the decrypted Secret the controller created
kubectl -n infra logs deploy/sealed-secrets --tail=30 | grep -i unseal
```

---

## 6. Rollback

```bash
helm history sealed-secrets -n infra
helm rollback sealed-secrets <REVISION> -n infra --wait
```

- Decrypted Secrets already in the cluster are **not** removed by a rollback.
- ⚠ The sealing keys live in Secrets in `infra`. A rollback does not touch them, but a
  namespace deletion or a cluster rebuild does — restore the key backup **before**
  re-applying SealedSecrets, otherwise the controller generates a new key and every
  committed SealedSecret fails to decrypt.

Restore:

```bash
kubectl apply -f sealed-secrets-keys-backup.yaml
kubectl -n infra rollout restart deploy/sealed-secrets
```

---

## 7. Monitoring

| Signal | Metric / check |
|---|---|
| Controller up | `up{job=~".*sealed-secrets.*"}` |
| Unseal errors | `sealed_secrets_controller_unseal_errors_total` — alert on any increase |
| Unseal requests | `sealed_secrets_controller_unseal_requests_total` |
| Key age | age of the newest `sealed-secrets-key*` Secret vs the 30d rotation |

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no key could decrypt secret` | Sealed with a different cluster's key, or keys were lost/regenerated. Re-seal from the plaintext source. |
| `cannot unseal: namespace mismatch` | Secret sealed for another namespace/name; re-seal or change the scope. |
| Secret not created after apply | Controller down, or the CRD is missing. Check the controller logs. |
| kubeseal fails to fetch the cert | Wrong `--controller-namespace` (it is `infra` here, not `kube-system`). |

---

## 9. Notes

Three secret mechanisms coexist in this repo — use the right one:

| Mechanism | Use for | Where |
|---|---|---|
| **SOPS** | platform + env secrets consumed by helmfile at render time | `env-values/<env>/secrets.enc.yaml` |
| **Sealed Secrets** | app secrets committed alongside manifests in GitOps | this release |
| **ESO + Vault** | rotated/dynamic credentials, target state | `external-secrets` |

Pick one owner per secret. Two mechanisms writing the same Secret name will overwrite each
other on every reconcile.
