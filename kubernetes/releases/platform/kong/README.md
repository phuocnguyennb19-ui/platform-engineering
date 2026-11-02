# Kong Gateway — Deploy

> **Values live in [`environments/<env>/kubernetes/ingress/kong/`](../../../../environments/dev/kubernetes/ingress/kong/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

**The only ingress controller of the platform** (DB-less Kong + Kong Ingress Controller 3.x)
and the Gateway API controller. Every platform UI and every app uses a classic `Ingress` with
`ingressClassName: kong` (`ingressClass` in `environments/<env>/kubernetes/state.yaml`);
`GatewayClass: kong` is implemented too. Gateway features (auth, rate limiting,
transformations, mTLS) come from plugins. ingress-nginx is being retired — §8.

| | |
|---|---|
| Chart | `kong/kong` |
| Version | `2.51.0` |
| Release / Namespace | `kong` / `infra` |
| Selector | `-l name=kong` |
| Labels | `layer=platform, tier=infra, component=gateway` |
| Values | `values.yaml.gotmpl` + `manifests/plugins.yaml` (KongClusterPlugin CRs, part of the release via `extra-objects.yaml.gotmpl`) |
| Proxy | `LoadBalancer`, DNS `api.<ingressDomain>` via ExternalDNS |

| Env | Replicas | HTTP listener | HPA / PDB |
|---|---|---|---|
| dev | 1 | enabled (Ingresses allow http,https) | no |
| staging | 2 | enabled — ACME HTTP-01 + 308 redirect only; Ingresses are `konghq.com/protocols: https` | no |
| prod | 3 | enabled — ACME HTTP-01 + 308 redirect only; Ingresses are `konghq.com/protocols: https` | HPA 3→6, PDB `minAvailable: 1` |

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
| **Gateway API CRDs** | required for `GatewayAlpha` — installed separately, see `releases/platform/gateway-api/README.md` |
| `kube-prometheus-stack` | ServiceMonitor CRD |

DB-less: no PostgreSQL dependency. Configuration comes from CRDs (`KongPlugin`,
`KongClusterPlugin`, `KongConsumer`, `HTTPRoute`) reconciled by the built-in controller —
which is what makes it GitOps-friendly.

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f releases/platform/kong/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/kong/helmfile.yaml.gotmpl sync   # also installs manifests/plugins.yaml

# Cluster where plugins.yaml was kubectl-applied before: Helm refuses to take over objects it
# did not create. Adopt them ONCE before the first sync (no downtime — the objects stay):
#   for p in $(yq -N '.metadata.name' releases/platform/kong/manifests/plugins.yaml); do
#     kubectl --context=<ctx> label kongclusterplugin "$p" app.kubernetes.io/managed-by=Helm --overwrite
#     kubectl --context=<ctx> annotate kongclusterplugin "$p" meta.helm.sh/release-name=kong meta.helm.sh/release-namespace=infra --overwrite
#   done
```

Plugins shipped in `manifests/plugins.yaml`:

| Plugin | Scope | Purpose |
|---|---|---|
| `prometheus` | global | status/latency/bandwidth metrics on every route |
| `correlation-id` | global | injects `X-Request-ID` (trace-friendly) |
| `security-headers` | global | `response-transformer`: X-Frame-Options, X-Content-Type-Options, X-XSS-Protection, Referrer-Policy, CSP, HSTS — what ingress-nginx set with `controller.addHeaders` + `hsts` |
| `request-size-limit` | opt-in (`konghq.com/plugins`) | rejects bodies > 8 MB — ingress-nginx `proxy-body-size: 8m`; set by default on every app (app-values) and platform UI Ingress, deliberately **not** on harbor |
| `rate-limit-default` | opt-in | 300 req/min per consumer, `policy: local` |

Global = label `global: "true"`. A route/service-level plugin of the same type **replaces**
the global one for that route (it does not stack) — an app with its own
`response-transformer` must repeat the security headers. `konghq.com/plugins` is a single
comma-separated annotation: an app that sets it replaces the env default
(`request-size-limit`) and must list it again if it wants the limit.

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
- Turning `proxy.http.enabled` off breaks ACME HTTP-01 (every per-Ingress certificate
  fails to renew) and the http→https redirect. Keep it on in every env.

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
| `http://` answers `426 Upgrade Required` instead of a redirect | The Ingress has `konghq.com/protocols: https` but no `konghq.com/https-redirect-status-code` (Kong's default code is 426). |
| `http://` answers `404 no Route matched` on an HTTPS-only host | Redirect not generated by the `expressions` router for this route — verify with `curl -sI http://<host>/` after the first sync (§8 step 3); fallback is `env.router_flavor: traditional_compatible`. |
| `413` on an upload | `request-size-limit` (8 MB) is attached — raise it with a dedicated KongClusterPlugin for that Ingress, never remove the global floor for everyone. |
| Harbor push fails mid-layer / kong pod evicted (`ephemeral-storage`) | Body buffered into the prefix emptyDir — check the harbor Ingress still has `konghq.com/request-buffering: "false"` and no `request-size-limit`. |
| Config push fails after a CR edit | Invalid plugin config — the controller logs the exact field. DB-less validates strictly. |

---

## 7. Notes

- Admin API is `ClusterIP` + TLS with HTTP disabled, and Kong Manager UI is off
  (`manager.enabled: false`). Configuration is git → CRDs, never clicked in.
- Router flavour is `expressions` — faster matching, but a different syntax from the
  traditional router if you migrate old routes.
- Plugin credentials (JWT keys, API keys) belong in SOPS-managed Secrets referenced by the
  CRs, never inline in `config/plugins.yaml`.

---

## 8. Cutover from ingress-nginx (Kong becomes the only ingress)

Decision: Kong is the only ingress controller; ingress-nginx (IngressClass `nginx-<env>`) is
retired. Apps keep the Kubernetes Ingress API with `ingressClassName: kong` (not HTTPRoute).
Git already carries the Kong side: `ingressClass: kong` in `environments/<env>/kubernetes/state.yaml`,
Kong annotations in every tool and app-values Ingress, `proxy.http.enabled: true` in every env.
ingress-nginx stays installed behind `ingressNginx: true` (state.yaml) until step 4.

Annotation mapping used (ingress-nginx → Kong Ingress Controller 3.x):

| ingress-nginx | Kong |
|---|---|
| `ingressClassName: nginx-<env>` | `ingressClassName: kong` |
| `ssl-redirect` / `force-ssl-redirect: "true"` | `konghq.com/protocols: "https"` + `konghq.com/https-redirect-status-code: "308"` |
| `ssl-redirect: "false"` | `konghq.com/protocols: "http,https"` (Kong default, stated explicitly) |
| `proxy-body-size: "8m"` (+ controller default 8m) | `konghq.com/plugins: "request-size-limit"` (KongClusterPlugin, 8 MB) |
| `proxy-body-size: "0"` (harbor) | no size plugin + `konghq.com/request-buffering: "false"`, `konghq.com/response-buffering: "false"` |
| `backend-protocol: HTTP` (argocd) | nothing — HTTP is Kong's default upstream protocol (`konghq.com/protocol` goes on the **Service** for HTTPS/gRPC backends) |
| controller `addHeaders`, `hsts*` | global KongClusterPlugin `security-headers` (`response-transformer`) |

Each step runs per environment, dev → staging → prod. Each step is a separate approval;
staging and prod are production-class writes, and step 4 is destructive.

1. **Kong ready to take traffic.** Sync Kong (`helmfile -e <env> -f releases/platform/kong/helmfile.yaml.gotmpl diff`
   then `sync`) so port 80 is open on `kong-proxy`. The same sync installs the plugins
   (`security-headers`, `request-size-limit` must exist **before** any Ingress references them —
   an Ingress naming a missing plugin fails translation in KIC). The `helmfiles:` order puts the
   networking group (cert-manager, ingress-nginx, kong, external-dns) before every tool with an
   Ingress, so even a single `-l layer=platform` sync installs the plugins first; syncing Kong
   alone first is still the safer cutover (you verify it before anything re-classes). If
   plugins.yaml was kubectl-applied on that cluster before, adopt those objects first (§2).
   Optional, to shorten step 2's DNS window: lower the TTL of the records external-dns owns
   and wait out the old TTL.
2. **Re-class everything.** `helmfile -e <env> -l layer=platform diff` then `sync` (CI
   `helmfile:sync:<env>`), then each app from the repo root (`helmfile -e <env> -l name=<app> diff|sync`).
   Every Ingress moves to class `kong`; ingress-nginx stops serving them; KIC publishes the
   `kong-proxy` address into `Ingress.status`; external-dns repoints each host's record to the
   Kong NLB; cert-manager's HTTP-01 solvers now use class `kong` (existing certificates are
   **not** re-issued until renewal — the TLS Secrets are reused as-is).
3. **Verify** (per host): `dig +short <host>` = Kong LB; `curl -sI http://<host>/` → `308` with
   `Location: https://…` (`200` in dev); `curl -sI https://<host>/` → expected status plus the
   security headers; `kubectl --context=<ctx> get ingress -A -o wide` shows the Kong address
   and no `nginx-<env>` class left; `kubectl --context=<ctx> get certificate -A` all Ready;
   a test renewal (`cmctl renew <cert> -n <ns>` on a staging-issuer cert) succeeds; Harbor
   `docker push` of a large image works; ingress-nginx request rate
   (`nginx_ingress_controller_requests`) has dropped to ~0 for longer than the old DNS TTL.
4. **Uninstall ingress-nginx.** Set `ingressNginx: false` in `environments/<env>/kubernetes/state.yaml`,
   review `helmfile -e <env> -f releases/platform/ingress-nginx/helmfile.yaml.gotmpl diff`
   (must show only the removal), then sync. Its NLB is deleted. The IngressClass `nginx-<env>`
   goes with the release.
5. **Clean up.** Remove the `platform-ingress-nginx` group from
   `environments/<env>/kubernetes/monitoring/prometheus-rules/platform.yaml.gotmpl` and sync
   kube-prometheus-stack. Once every env is done, remove the ingress-nginx release folder, its
   values and its `helmfiles:` entry in a separate change.

Rollback: before step 4, revert the commit and sync platform + apps — Ingresses return to
`nginx-<env>` and external-dns repoints back (DNS TTL applies). After step 4, set
`ingressNginx: true` and sync first (a **new** NLB, new address), then revert the class.
