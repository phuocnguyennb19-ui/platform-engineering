# ingress-nginx — Deploy

> **Values live in [`infra-base/k8s/platform/ingress-nginx/`](../../../infra-base/k8s/platform/ingress-nginx/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

North-south HTTP entry point for the cluster. Creates the IngressClass `nginx-<env>` that
every app Ingress and the ACME HTTP-01 solver reference.

| | |
|---|---|
| Chart | `ingress-nginx/ingress-nginx` |
| Version | `4.15.1` |
| Release / Namespace | `ingress-nginx` / `infra` |
| Selector | `-l name=ingress-nginx` |
| Labels | `layer=platform, tier=infra, component=ingress` |
| Values | `values.yaml.gotmpl` |
| IngressClass | `nginx-<env>` (controller value `k8s.io/ingress-nginx-<env>`) |
| Service | `LoadBalancer`, AWS **NLB**, `internet-facing` |
| Blast radius | **Critical.** A bad sync takes all public traffic down. |

| Env | Replicas | HPA | PDB |
|---|---|---|---|
| dev | 1 | off | no |
| staging | 2 | 2→4 @70% CPU | no |
| prod | 3 | 3→6 @70% CPU | `minAvailable: 1` |

---

## 1. Prerequisites

- `infra` namespace with PSA **`baseline`** — the controller needs `NET_BIND_SERVICE` and
  cannot run under `restricted`.
- Cloud LB support. The service annotations are **AWS-specific**
  (`aws-load-balancer-type: nlb`, `internet-facing`); change them for GCP/Azure/on-prem
  (MetalLB) before syncing.
- `kube-prometheus-stack` for the ServiceMonitor CRD.
- cert-manager, if you want TLS on the hosts it serves.

---

## 2. Security posture baked into the values

| Setting | Why |
|---|---|
| `allowSnippetAnnotations: false` | Snippet annotations are an RCE/file-read surface (CVE-2021-25742, CVE-2023-5044). **Keep off.** |
| `annotations-risk-level: Medium` | Ceiling on which annotations the controller accepts — rejects high/critical ones while allowing the everyday set (ssl-redirect, proxy-body-size, backend-protocol, cluster-issuer). |
| `addHeaders` | Global security headers (X-Frame-Options, nosniff, CSP, Referrer-Policy) for **every** ingress — no per-app snippet needed. |
| `ssl-protocols: TLSv1.2 TLSv1.3`, HSTS 2y | Modern TLS only |
| `server-tokens: false` | Hide version banner |
| `use-forwarded-headers` + `proxy-real-ip-cidr` | Trust forwarded headers only from internal CIDRs — **set these per VPC** or you enable IP spoofing |
| `proxy-body-size: 8m` | Abuse limit (Harbor overrides it to `0` for image layers on its own ingress) |

If a chart needs an annotation that gets rejected, the controller logs the annotation name —
raise the risk level deliberately, per case, rather than globally.

---

## 3. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f platform/ingress-nginx/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/ingress-nginx/helmfile.yaml.gotmpl sync
```

**Always diff.** Changes to `config` reload nginx on every pod; changes to the Service can
recreate the load balancer and change its address.

---

## 4. Verify

```bash
kubectl -n infra rollout status deploy/ingress-nginx-controller --timeout=300s
kubectl get ingressclass
kubectl -n infra get svc ingress-nginx-controller -o wide      # note the external hostname

# config is valid and loaded
kubectl -n infra exec deploy/ingress-nginx-controller -- nginx -t

# end-to-end
curl -I https://payment.$INGRESS_DOMAIN
kubectl get ingress -A
```

DNS for each host must resolve to the LB address (ExternalDNS does this automatically for
annotated resources — see `platform/external-dns/README.md`).

---

## 5. Rollback

```bash
helm history ingress-nginx -n infra
helm rollback ingress-nginx <REVISION> -n infra --wait --timeout 10m
```

Rollback caveats:

- **Do not delete the Service** to "fix" it. Recreating a `LoadBalancer` Service allocates a
  **new** NLB hostname/IP; every DNS record then points at a dead endpoint until it
  propagates. That is a much longer outage than the original problem.
- Config changes are hot-reloaded — a rollback restores the previous nginx config within
  seconds.
- Changing `ingressClassResource.name` orphans every existing Ingress (they reference the old
  class). Treat it as a migration, not an edit.

---

## 6. Monitoring & alerting

`metrics.serviceMonitor.enabled: true`.

| Signal | Metric |
|---|---|
| Error rate | `rate(nginx_ingress_controller_requests{status=~"5.."}[5m])` per host |
| Latency | `histogram_quantile(0.99, nginx_ingress_controller_request_duration_seconds_bucket)` |
| Config reload failures | `nginx_ingress_controller_config_last_reload_successful == 0` — **page on this** |
| Certificate expiry seen by nginx | `nginx_ingress_controller_ssl_expire_time_seconds` |
| Saturation | active connections, CPU vs HPA target |

`config_last_reload_successful == 0` means nginx is serving a **stale** config: new
Ingresses silently do not take effect.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Ingress created but 404 | `ingressClassName` does not match `nginx-<env>`. |
| App gets the wrong client IP | `proxy-real-ip-cidr` does not cover your LB subnet. |
| Annotation ignored, warning in logs | Rejected by `annotations-risk-level: Medium` — evaluate before raising it. |
| 502 for a specific host | Backend pods not Ready, or a NetworkPolicy blocks `infra` → app namespace. |
| SSL error on an app host | Certificate not issued — check `kubectl get certificate -n <ns>` and cert-manager. |
| LB has no external address | Cloud controller cannot provision (subnet tags, quota, wrong annotations for the provider). |
| Large uploads fail with 413 | `proxy-body-size` — override per-ingress, not globally. |

---

## 8. Notes

- Two gateways coexist: **ingress-nginx** for plain ingress and **Kong** (`kong`) for
  API-gateway features. Pick per service; do not chain them without a reason.
- On-prem: replace the AWS NLB annotations with MetalLB, or use `NodePort` for local kind
  clusters.
- prod runs 3 replicas with anti-affinity implied by the HPA + PDB — verify you have enough
  nodes before raising `minAvailable`.
