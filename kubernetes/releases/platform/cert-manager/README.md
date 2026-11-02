# cert-manager — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/cert-manager/`](../../../../environments/dev/kubernetes/tools/cert-manager/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

TLS certificate automation. Issues and renews certificates for every ingress host, for
Vault's internal TLS, and for the Gateway API listener. Deploy it **first in the `infra`
domain** — several later releases block on certificates it issues.

| | |
|---|---|
| Chart | `jetstack/cert-manager` |
| Version | `v1.21.0` |
| Release / Namespace | `cert-manager` / `infra` (created by this release) |
| Selector | `-l name=cert-manager` |
| Labels | `layer=platform, tier=infra, component=tls` |
| Values | `values.yaml.gotmpl` |
| Extras | Both `ClusterIssuer`s ride along as `extraObjects`, as post-install/post-upgrade hooks |

| Env | Replicas (controller/webhook/cainjector) | PDB |
|---|---|---|
| dev / staging | 1 | no |
| prod | 2 | `minAvailable: 1` |

---

## 1. Prerequisites

- `infra` namespace with PSA `baseline` (`environments/<env>/kubernetes/namespace/namespaces.yaml`).
- `prometheus-operator-crds` for the ServiceMonitor CRD.
- For **HTTP-01** to validate: Kong must be running with the IngressClass `kong` **and its
  proxy http listener on** (`proxy.http.enabled: true` in
  `environments/<env>/kubernetes/ingress/kong/values.yaml.gotmpl`, every env), and the DNS
  record for the host must already point at the Kong proxy LB (`kong-proxy`).
- Optional: `ACME_EMAIL` (defaults to `platform@example.com`).

---

## 2. What ships with the release

`crds.enabled: true`, `crds.keep: true` — the CRDs are installed by the release and
**deliberately not deleted** on uninstall (deleting them would cascade-delete every
Certificate in the cluster).

Two `ClusterIssuer`s are created as `extraObjects` so they exist as soon as the webhook is
Ready, instead of a `kubectl apply` someone forgets on a new cluster. They are helm hooks
(`post-install,post-upgrade`, weight 10, `before-hook-creation`): helm maps a release's normal
manifests before creating anything, and on a fresh cluster the `ClusterIssuer` kind does not
exist until this release has installed its CRDs. A hook is mapped only when it runs, after the
CRDs, after `wait` and after the chart's `startupapicheck` hook, so **one `sync` installs
everything** on a new cluster. Cost: both issuers are deleted and recreated on every sync (the
ACME account key Secret and issued certificates stay), `helm uninstall` leaves them, and helm
lists them as hooks, not release resources. The first `diff` on a cluster without the CRDs
needs `--diff-args '--disable-validation'`.

| Issuer | ACME endpoint | Use |
|---|---|---|
| `letsencrypt-staging` | staging directory | wiring things up, no rate limit pain |
| `letsencrypt-prod` | production directory | real certificates |

> The HTTP-01 solver ingress class follows `.Values.ingressClass` from
> `environments/<env>/kubernetes/state.yaml` (`kong` in every env). It used to be hardcoded to `nginx-prod`, which meant
> dev/staging challenges were routed to a non-existent IngressClass and never validated.
> Keep it env-driven. The solver Ingress carries no `konghq.com/protocols`, so Kong serves
> it on plain HTTP even for hosts whose own Ingress is HTTPS-only (308 redirect).

---

## 3. Deploy

```bash
export ENV=dev
export ACME_EMAIL=platform@example.com

helmfile -e $ENV -f releases/platform/cert-manager/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/cert-manager/helmfile.yaml.gotmpl sync

# the webhook must be Available before anything requests a Certificate
kubectl wait --for=condition=Available deploy/cert-manager-webhook -n infra --timeout=180s
```

Immediately after this, on a fresh cluster, issue Vault's TLS certificate — `vault`
mounts the Secret `vault-tls` and will hang in `ContainerCreating` without it:

```bash
kubectl apply -f releases/platform/vault/manifests/certificate.yaml
kubectl wait --for=condition=Ready certificate/vault-tls -n vault --timeout=180s
```

---

## 4. Verify

```bash
kubectl -n infra get pods -l app.kubernetes.io/instance=cert-manager
kubectl get clusterissuer
kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[0].message}{"\n"}'   # ACME account registered

# certificates across the cluster
kubectl get certificate -A
kubectl get certificaterequest,order,challenge -A     # empty = nothing stuck
```

A `Certificate` should reach `READY=True` within a couple of minutes. Anything sitting in
`Order`/`Challenge` for longer is a validation problem, not a cert-manager bug.

---

## 5. Rollback

```bash
helm history cert-manager -n infra
helm rollback cert-manager <REVISION> -n infra --wait
```

- Issued certificates live in Secrets and **survive** rollback/uninstall. Existing TLS keeps
  working; only renewals stop.
- CRDs are kept (`crds.keep: true`). Never `kubectl delete crd certificates.cert-manager.io`
  — it deletes every Certificate object cluster-wide.
- Rolling back across a major version can leave CRDs newer than the controller. Match the
  CRD version to the chart version.

---

## 6. Monitoring & alerting

`prometheus.servicemonitor.enabled: true`.

| Signal | Metric |
|---|---|
| **Expiry** | `certmanager_certificate_expiration_timestamp_seconds - time() < 14d` — the alert that matters |
| Not ready | `certmanager_certificate_ready_status{condition="False"} == 1` |
| ACME failures | `certmanager_http_acme_client_request_count{status!~"2.."}` |
| Controller sync errors | `certmanager_controller_sync_call_count` vs error logs |

Alert on expiry **and** on `ready=False`. A silently failing renewal only becomes visible
when the certificate actually expires — by then it is an outage.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Challenge stuck `pending` | The solver IngressClass does not match the env's class, or DNS for the host does not point at the ingress LB yet. |
| `Order` failed, ACME rate limit | Let's Encrypt allows 5 duplicate certs/week per exact name set. Use `letsencrypt-staging` while iterating. |
| Webhook `connection refused` / TLS error on apply | Webhook not Ready, or a NetworkPolicy blocks the API server → `infra`. `infra` intentionally has no default-deny for this reason. |
| Certificate Ready but the browser shows the old cert | Kong has not received the new config yet; check the controller logs (`kubectl -n infra logs deploy/kong -c ingress-controller --tail=50`) for a failed config push. |
| Challenge answered with `308` / `426` instead of the token | The solver route did not win over the host's HTTPS-only route; check the solver Ingress has class `kong` and `kubectl -n infra logs deploy/kong -c ingress-controller` for translation errors. |
| Vault pod stuck `ContainerCreating` | `vault-tls` Secret missing — apply `releases/platform/vault/manifests/certificate.yaml`. |
| `<no ingressClassName>` in challenge ingress | `.Values.ingressClass` empty for that env in `environments/<env>/kubernetes/state.yaml`. |

---

## 8. Notes

- Use `letsencrypt-staging` first for any new hostname; switch the annotation to
  `letsencrypt-prod` only once a challenge succeeds.
- Point an Ingress at an issuer with:
  ```yaml
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  ```
- DNS-01 (needed for wildcards and for on-prem/private clusters) is not configured here —
  add a solver with the provider credentials if you need `*.<domain>`.
