# `ci/` — test value matrices

Convention from Helm `chart-testing` (`ct lint`/`ct install`): every
`*-values.yaml` here is a separate render/install case. CI iterates over them, so
a change that only breaks the StatefulSet path or only breaks workers is caught
before merge instead of at deploy time.

| File | Covers |
|---|---|
| `minimal-values.yaml` | smallest valid input — image only |
| `full-values.yaml` | every optional feature on at once: workers + KEDA, cronjobs, initContainers, sidecar, RBAC, NetworkPolicy egress, Ingress+TLS, ServiceMonitor, PrometheusRule, extraObjects |
| `statefulset-values.yaml` | `workload.kind: StatefulSet` + volumeClaimTemplates + headless Service |
| `daemonset-values.yaml` | `workload.kind: DaemonSet` |
| `gateway-api-values.yaml` | HTTPRoute + GRPCRoute instead of Ingress |
| `proxy-values.yaml` | nginx proxy sidecar: `http` on nginx, app probes rewritten to `app`, NetworkPolicy on proxy.port, preStop hold, worker without sidecar |

Add a case here whenever you fix a rendering bug — that is what stops it coming back.

```bash
for f in charts/application/ci/*-values.yaml; do
  helm template ci charts/application -f "$f" > /dev/null || echo "FAIL $f"
done
```
