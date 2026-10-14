# Gateway API — Deploy

**Not a Helm release.** Gateway API has no upstream chart: the CRDs come from a pinned
release manifest and the controller is Kong (`kong`, `GatewayAlpha` feature gate).
This directory holds one templated manifest defining the cluster `GatewayClass` and a
single shared multi-tenant `Gateway`.

| | |
|---|---|
| Manifest | `gateway.yaml.gotmpl` |
| Namespace | `infra` |
| Controller | `konghq.com/kic-gateway-controller` (from `kong`) |
| GatewayClass | `kong` |
| Gateway | `platform` |
| Listeners | HTTP :80 always; HTTPS :443 outside dev (TLS Secret `platform-gateway-tls`) |

App teams attach `HTTPRoute`s from their own namespaces — the Gateway accepts routes only
from namespaces labelled `gateway-access: "true"`.

---

## 1. Prerequisites — in this order

```bash
# 1. Gateway API CRDs (standard channel, PINNED version — do not use a floating tag)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# 2. Kong with the GatewayAlpha feature gate (already set in platform/kong/values.yaml.gotmpl)
helmfile -e $ENV -f platform/kong/helmfile.yaml.gotmpl sync

# 3. TLS certificate for the HTTPS listener (staging/prod)
#    cert-manager must issue a Secret named `platform-gateway-tls` in namespace `infra`
kubectl -n infra get secret platform-gateway-tls
```

Applying the Gateway before the CRDs exist fails with `no matches for kind "Gateway"`.
Applying it before Kong is running leaves it `Programmed=False` forever.

---

## 2. Deploy

`gateway.yaml.gotmpl` is a Go template referencing `.Environment.Name` and `.Values`
(`ingressDomain`, etc.), so it must be rendered by helmfile before it is valid YAML — the
repo-supported path (`docs/DEPLOY.md`, §6.6):

```bash
export ENV=dev

# 1. review the render first
helmfile -e $ENV -f platform/kong/helmfile.yaml.gotmpl template --include-crds | less

# 2. apply
helmfile -e $ENV -f platform/kong/helmfile.yaml.gotmpl template --include-crds | kubectl apply -f -
```

> This renders the whole `infra` domain, not just this file. Review the diff before
> applying, or extract only the `GatewayClass`/`Gateway` documents from the output.
> A cleaner long-term option is to move the manifest into a raw-chart release so it is
> owned by helmfile like everything else.

Then opt a namespace into the shared Gateway:

```bash
kubectl label namespace dev gateway-access=true
```

---

## 3. Verify

```bash
kubectl get gatewayclass kong \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{"\n"}'      # True

kubectl -n infra get gateway platform
kubectl -n infra get gateway platform \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'    # True

# listener status + attached routes
kubectl -n infra describe gateway platform | sed -n '/Listeners/,$p'
kubectl get httproute -A
```

A route that is created but not attached shows `Accepted=False` with the reason
(`NotAllowedByListeners` is almost always the missing namespace label).

---

## 4. Example HTTPRoute (app-owned)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: be-payment
  namespace: dev              # must carry label gateway-access=true
spec:
  parentRefs:
    - name: platform
      namespace: infra
  hostnames: ["payment.dev.example.com"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: /api }
      backendRefs:
        - name: be-payment
          port: 80
```

`charts/application` already ships an `httproute.yaml` template for this.

---

## 5. Rollback

```bash
# remove the Gateway (routes stop being served immediately)
kubectl -n infra delete gateway platform

# revoke one namespace's access without touching the Gateway
kubectl label namespace dev gateway-access-
```

⚠ **Never delete the Gateway API CRDs to "reset" things** — that cascade-deletes every
Gateway and HTTPRoute in the cluster. CRD upgrades should be applied with
`--server-side --force-conflicts`, and only after reading the release notes: Gateway API
has shipped breaking changes between versions.

Fallback path: services with a plain `Ingress` (ingress-nginx) keep working independently,
so an ingress-based rollback is available per service.

---

## 6. Monitoring

There is no separate exporter — Gateway health is Kong's health:

| Signal | Where |
|---|---|
| Gateway `Programmed` condition | `kubectl get gateway -A` / a kube-state-metrics custom resource metric |
| Route attach failures | `HTTPRoute` `Accepted=False` conditions |
| Traffic + errors | Kong metrics (`kong_http_requests_total`) — see `platform/kong/README.md` |
| Certificate expiry | cert-manager metrics for `platform-gateway-tls` |

Worth adding a kube-state-metrics custom-resource-state config for Gateway/HTTPRoute
conditions — otherwise a detached route is invisible in Prometheus.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no matches for kind "Gateway"` | CRDs not installed. |
| GatewayClass `Accepted=False` | No controller matches `konghq.com/kic-gateway-controller` — Kong not running or feature gate off. |
| Gateway `Programmed=False` | Kong controller cannot provision the listener; check its logs. Missing TLS Secret is the usual cause on :443. |
| HTTPRoute `NotAllowedByListeners` | Namespace missing `gateway-access: "true"`. |
| HTTPS listener missing in dev | By design — dev only creates the HTTP listener. |
| Route works via Ingress but not HTTPRoute | Two controllers; confirm `parentRefs` points at `platform`/`infra`. |

---

## 8. Notes

- One shared multi-tenant Gateway is deliberate: app teams do not each get a load balancer.
  Namespace opt-in via label is the tenancy boundary.
- Pin the CRD version in git (the URL above) and upgrade it as a reviewed change — an
  unpinned `latest` manifest is a cluster-wide, un-reviewed API change.
- Gateway API and Ingress can coexist; migrate services one at a time rather than
  flipping the whole platform.
