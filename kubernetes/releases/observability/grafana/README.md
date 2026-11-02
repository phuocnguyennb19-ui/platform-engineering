# Grafana — Deploy

> **Values live in [`environments/<env>/kubernetes/monitoring/grafana/`](../../../../environments/dev/kubernetes/monitoring/grafana/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

The platform's pane of glass. Standalone release (the `kube-prometheus-stack` subchart is
disabled) wiring **metrics ↔ logs ↔ traces** into one correlated view.

| | |
|---|---|
| Chart | `grafana/grafana` (Grafana 11.6.1, pinned image) |
| Version | `8.15.0` |
| Release / Namespace | `grafana` / `observability` |
| Selector | `-l name=grafana` |
| Labels | `layer=platform, tier=infra, component=metrics` |
| Values | `values.yaml.gotmpl` + `datasources.yaml.gotmpl` |
| Needs | `loki`, `tempo`, `opensearch` |
| Secrets | `secrets.grafana.{username,password,secretKey}`, `secrets.opensearch.password` |

| Env | Storage |
|---|---|
| dev | 5Gi PVC |
| staging | 5Gi PVC |
| prod | 10Gi PVC |

Runs **1 replica** with SQLite on an RWO PVC. That is a deliberate limit: for HA you must
configure an external database (Postgres) in `grafana.ini` first — scaling replicas with
SQLite corrupts the database.

---

## 1. Prerequisites

| Requirement | Why |
|---|---|
| Loki, Tempo, OpenSearch Ready | declared `needs`; datasources point at them |
| `kube-prometheus-stack` | Prometheus datasource + dashboard ConfigMaps (`forceDeployDashboards: true`) |
| SOPS keys | admin credentials + `secretKey` for datasource encryption |
| ingress-nginx + cert-manager | for `grafana.<ingressDomain>` |
| StorageClass | PVC for the SQLite database |

---

## 2. Datasources (`datasources.yaml.gotmpl`)

| Datasource | uid | Target | Correlation |
|---|---|---|---|
| Prometheus | `prometheus` | `kube-prometheus-stack-prometheus:9090` | metrics → exemplars → Tempo |
| Loki | `loki` | `loki-gateway` | `derivedFields` (TraceID) → Tempo |
| Tempo | `tempo` | `tempo:3100` | traces → logs (Loki) and → metrics |
| OpenSearch | `opensearch` | `opensearch-cluster-master:9200` | full-text search |

The correlation wiring is the point of this file — verify the round trip after any change:
a metric spike → exemplar → trace → the pod's logs.

> **Gap:** **Mimir is deployed but not registered as a datasource here.** Long-term
> metrics are therefore not queryable from Grafana today; the Prometheus datasource only
> sees local (short-retention) TSDB. To close it, add a `prometheus`-type datasource
> pointing at the Mimir query frontend with the `X-Scope-OrgID` header. See
> `kubernetes/releases/observability/mimir/README.md`.

---

## 3. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f ../kubernetes/releases/observability/grafana/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f ../kubernetes/releases/observability/grafana/helmfile.yaml.gotmpl sync
```

---

## 4. Verify

```bash
kubectl -n observability rollout status deploy/grafana --timeout=300s

kubectl -n observability port-forward svc/grafana 3000:80 &
curl -s localhost:3000/api/health | jq

# datasources actually reachable (not just defined)
PASS=$(kubectl -n observability get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u "admin:$PASS" localhost:3000/api/datasources | jq -r '.[] | "\(.name)\t\(.type)\t\(.url)"'
for id in $(curl -s -u "admin:$PASS" localhost:3000/api/datasources | jq -r '.[].id'); do
  curl -s -u "admin:$PASS" "localhost:3000/api/datasources/$id/health" | jq -c '{message}'
done

# dashboards picked up by the sidecar
kubectl -n observability get cm -l grafana_dashboard=1 --no-headers | wc -l
```

---

## 5. Rollback

```bash
helm history grafana -n observability
helm rollback grafana <REVISION> -n observability --wait
```

- **Dashboards created in the UI live in the SQLite PVC**, not in git. A rollback keeps
  them (the PVC is untouched), but a PVC deletion loses them. Provision dashboards as code
  (ConfigMaps with `grafana_dashboard: "1"`) so this stops being a risk.
- Changing `secrets.grafana.secretKey` invalidates stored datasource credentials — they
  must be re-entered or re-provisioned.

---

## 6. Monitoring & alerting

| Signal | Metric |
|---|---|
| Availability | `up{job="grafana"}` |
| HTTP errors | `rate(grafana_http_request_duration_seconds_count{status_code=~"5.."}[5m])` |
| Datasource failures | `grafana_datasource_request_total{code!~"2.."}` |
| Login failures | `grafana_api_login_post_total{status="failed"}` — spikes mean brute force |
| Sidecar | dashboard ConfigMap count vs expected |

Grafana being down does not break the platform, but it blinds the on-call. Keep an
independent alerting path (Alertmanager → Slack/PagerDuty) that does not route through it.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Datasource "Bad Gateway"/`no such host` | Target release not synced, or the service name/namespace changed. Check `datasources.yaml.gotmpl`. |
| Logs → trace link does nothing | Loki `derivedFields` regex does not match the trace-id format the apps emit. |
| No historical metrics beyond Prometheus retention | Expected — the Mimir datasource is not wired yet (see the gap note above). |
| OpenSearch datasource TLS error | Demo certs + `verificationMode: full` — see `releases/platform/opensearch/README.md`. |
| Pod `CrashLoopBackOff` after scaling to 2 | SQLite + RWO PVC. Revert to 1 replica or move to an external database. |
| Dashboards disappeared | PVC replaced, or the sidecar lost the ConfigMap label. |
| Cannot log in | `secrets.grafana.*` changed after first install — the admin password is only applied at bootstrap; reset it in-container. |

---

## 8. Notes

- Grafana is disabled inside `kube-prometheus-stack` on purpose (`grafana.enabled: false`)
  but that chart still emits dashboard ConfigMaps for this release's sidecar.
- Treat dashboards as code. Anything business-critical that exists only in the UI will be
  lost the first time the PVC is recreated.
- Hardened pod security: runs as UID 472, non-root, seccomp `RuntimeDefault`.
