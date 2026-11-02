# OpenSearch Dashboards — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/opensearch-dashboards/`](../../../../environments/dev/kubernetes/tools/opensearch-dashboards/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Web UI for OpenSearch. Connects to `https://opensearch-cluster-master:9200` and is exposed
via Ingress at `dashboards.<ingressDomain>`.

| | |
|---|---|
| Chart | `opensearch/opensearch-dashboards` |
| Version | `3.7.0` |
| Release / Namespace | `opensearch-dashboards` / `observability` |
| Selector | `-l name=opensearch-dashboards` |
| Labels | `layer=platform, tier=infra, component=search` |
| Values | `values.yaml.gotmpl` |
| Needs | `opensearch` |

| Env | Replicas | TLS verification |
|---|---|---|
| dev | 1 | `none` (demo certs) |
| staging | 1 | `full` (needs a real CA) |
| prod | 2 + PDB | `full` (needs a real CA) |

---

## 1. Prerequisites

- **OpenSearch Ready** (declared `needs`).
- Secret `opensearch-admin` with key `password` in `observability` — consumed via
  `extraEnvs` (`OPENSEARCH_USERNAME=admin`). It comes from `secrets.opensearch.password`.
- `ingress-nginx` + cert-manager for the `dashboards.<domain>` host outside dev.
- Outside dev, `opensearch.ssl.verificationMode: full` — the OpenSearch cluster must
  present certificates from a CA the Dashboards pod trusts. With the chart's demo certs
  this **will fail**; see `releases/platform/opensearch/README.md`.

---

## 2. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f releases/platform/opensearch-dashboards/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/opensearch-dashboards/helmfile.yaml.gotmpl sync
```

---

## 3. Verify

```bash
kubectl -n observability rollout status deploy/opensearch-dashboards --timeout=300s
kubectl -n observability logs deploy/opensearch-dashboards --tail=40 | grep -iE 'error|unable to connect'

kubectl -n observability port-forward svc/opensearch-dashboards 5601:5601 &
curl -s localhost:5601/api/status | jq '.status.overall.state'     # "green"
```

Then load `https://dashboards.<ingressDomain>` and confirm login with the admin credential.

---

## 4. Rollback

```bash
helm history opensearch-dashboards -n observability
helm rollback opensearch-dashboards <REVISION> -n observability --wait
```

Stateless UI — rollback is safe. Saved objects (index patterns, visualisations, saved
searches) live in the `.kibana*` indices **inside OpenSearch**, so they survive. Export
them before major upgrades:

```bash
curl -s localhost:5601/api/saved_objects/_export -H 'osd-xsrf:true' \
  -H 'Content-Type: application/json' -d '{"type":["index-pattern","dashboard","visualization"]}' \
  > dashboards-export.ndjson
```

---

## 5. Monitoring

| Signal | Check |
|---|---|
| Pod availability | `kube_deployment_status_replicas_unavailable{deployment="opensearch-dashboards"}` |
| App status | `/api/status` overall state |
| Ingress health | 5xx rate on the `dashboards.<domain>` host in the ingress-nginx metrics |
| Upstream | OpenSearch cluster status — Dashboards is only as healthy as its backend |

This is a UI: alert lightly. The real signal is OpenSearch's own health.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Unable to connect to OpenSearch` | Backend not Ready, or `opensearchHosts` points at the wrong service/namespace. |
| TLS handshake failure (staging/prod) | `verificationMode: full` against demo certs. Install real certs on OpenSearch or, temporarily and knowingly, relax the mode. |
| Login rejected | `opensearch-admin` Secret out of sync with the actual OpenSearch admin password. |
| 502 through the ingress | Pod not Ready, or the ingress class does not match `nginx-<env>`. |
| Blank/looping UI after an upgrade | Version skew: Dashboards and OpenSearch must be the same minor version — both are pinned to `3.7.0` here; upgrade them together. |

---

## 7. Notes

- Keep Dashboards and OpenSearch chart versions in lockstep. Mixing minors causes subtle
  API failures that look like UI bugs.
- Grafana is the primary pane of glass in this platform (metrics/logs/traces correlation);
  Dashboards is for full-text search and index management. Do not duplicate dashboards
  across both.
