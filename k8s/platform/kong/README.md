# Kong Gateway — Deploy

> **Values live in [`infra-base/k8s/platform/kong/`](../../../infra-base/k8s/platform/kong/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

API gateway (DB-less) **and** the Gateway API controller. Handles services that need
gateway features beyond plain ingress: auth, rate limiting, transformations, mTLS.
Implements both `GatewayClass: kong` and the classic `ingressClassName: kong`.

| | |
|---|---|
| Chart | `kong/kong` |
| Version | `2.51.0` |
| Release / Namespace | `kong` / `infra` |
| Selector | `-l name=kong` |
| Labels | `layer=platform, tier=infra, component=gateway` |
| Values | `values.yaml.gotmpl` + `config/plugins.yaml` (KongClusterPlugin CRs) |
| Proxy | `LoadBalancer`, DNS `api.<ingressDomain>` via ExternalDNS |

| Env | Replicas | HTTP listener | HPA / PDB |
|---|---|---|---|
| dev | 1 | enabled | no |
| staging | 2 | **disabled** (TLS only) | no |
| prod | 3 | **disabled** (TLS only) | HPA 3→6, PDB `minAvailable: 1` |

> **Sole gateway.** The overlapping app-tier release `kong-ingress` — a second,
> hand-rolled Kong on `charts/application` — was deleted in favour of this one.
> It ran DB-less with no `KONG_DECLARATIVE_CONFIG` and no controller, so nothing
> ever supplied it a configuration: `/status/ready` returned `503 no
> configuration available` permanently and the release could never reach Ready
> in **any** environment. This release does not have that problem because
> `ingressController.enabled: true` supplies config from Ingress/CRDs.

---

## 1. Prerequisites

| Requirement | Why |
|---|---|
| `infra` namespace (PSA `baseline`) | controller + proxy |
| cert-manager | TLS for the proxy listener outside dev |
| ExternalDNS (optional) | creates `api.<domain>` from the proxy annotation |
| **Gateway API CRDs** | required for `GatewayAlpha` — installed separately, see `platform/gateway-api/README.md` |
| `kube-prometheus-stack` | ServiceMonitor CRD |

DB-less: no PostgreSQL dependency. Configuration comes from CRDs (`KongPlugin`,
`KongClusterPlugin`, `KongConsumer`, `HTTPRoute`) reconciled by the built-in controller —
which is what makes it GitOps-friendly.

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f platform/kong/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/kong/helmfile.yaml.gotmpl sync

# cluster-wide declarative plugins — apply AFTER the release is Ready
kubectl apply -f platform/kong/manifests/plugins.yaml
```

Plugins shipped in `config/plugins.yaml`:

| Plugin | Scope | Purpose |
|---|---|---|
| `prometheus` | global | status/latency/bandwidth metrics on every route |
| `correlation-id` | global | injects `X-Request-ID` (trace-friendly) |
| `request-size-limit` | global | rejects bodies > 20MB at the edge |
| `rate-limit-default` | opt-in | 300 req/min per consumer, `policy: local` |

---

## 3. Verify

```bash
kubectl -n infra rollout status deploy/kong --timeout=300s
kubectl -n infra get svc kong-proxy -o wide

# controller reconciling
kubectl -n infra logs deploy/kong -c ingress-controller --tail=40 | grep -iE 'error|successfully synced'

# Gateway API wired up
kubectl get gatewayclass kong
kubectl -n infra get gateway platform

# plugins registered
kubectl -n infra get kongclusterplugin

# admin API is ClusterIP + TLS only — never public
kubectl -n infra get svc kong-admin -o jsonpath='{.spec.type}{"\n"}'      # ClusterIP
```

---

## 4. Rollback

```bash
helm history kong -n infra
helm rollback kong <REVISION> -n infra --wait
```

- DB-less means **no state to migrate** — rollback is clean. Plugin CRs are separate
  objects and survive.
- Recreating the `kong-proxy` LoadBalancer changes its address; ExternalDNS will update
  `api.<domain>`, but clients with cached DNS see errors meanwhile. Avoid deleting the
  Service.
- Turning `proxy.http.enabled` on/off changes the listener set — clients on plain HTTP break
  immediately outside dev (by design).

---

## 5. Monitoring & alerting

`serviceMonitor.enabled: true` plus the global `prometheus` plugin.

| Signal | Metric |
|---|---|
| Upstream errors | `kong_http_requests_total{code=~"5.."}` per service |
| Latency | `kong_request_latency_ms_bucket`, `kong_upstream_latency_ms_bucket` |
| Rate-limit rejections | `kong_http_requests_total{code="429"}` |
| Controller sync failures | `ingress_controller_configuration_push_count{success="false"}` |
| Datastore/config errors | controller logs — DB-less config push failures are silent otherwise |

A failed config push means Kong keeps serving the **last good** config: new routes silently
do not appear. Alert on it.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| HTTPRoute has no effect | Gateway API CRDs missing, or `GatewayAlpha=true` feature gate not set. Check `kubectl get crd | grep gateway.networking`. |
| Route attaches but 404 | The route's namespace lacks the `gateway-access: "true"` label required by the Gateway's `allowedRoutes` selector. |
| 503 from the proxy | Upstream service has no Ready endpoints. |
| Rate limiting inaccurate across replicas | `policy: local` counts per pod. Switch to `policy: redis` and point at `redis`. |
| Plugin CR ignored | Missing `kubernetes.io/ingress.class: kong` annotation on the CR. |
| Config push fails after a CR edit | Invalid plugin config — the controller logs the exact field. DB-less validates strictly. |

---

## 7. Notes

- Admin API is `ClusterIP` + TLS with HTTP disabled, and Kong Manager UI is off
  (`manager.enabled: false`). Configuration is git → CRDs, never clicked in.
- Router flavour is `expressions` — faster matching, but a different syntax from the
  traditional router if you migrate old routes.
- Plugin credentials (JWT keys, API keys) belong in SOPS-managed Secrets referenced by the
  CRs, never inline in `config/plugins.yaml`.
