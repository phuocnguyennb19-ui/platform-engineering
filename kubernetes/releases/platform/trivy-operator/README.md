# Trivy Operator — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/trivy-operator/`](../../../../environments/dev/kubernetes/tools/trivy-operator/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Continuous in-cluster scanning: image vulnerabilities, config audit, RBAC assessment and
exposed secrets. Results land as CRs (`VulnerabilityReport`, `ConfigAuditReport`, …) and as
Prometheus metrics.

| | |
|---|---|
| Chart | `aqua/trivy-operator` |
| Version | `0.34.0` |
| Release / Namespace | `trivy-operator` / `trivy-system` (created by this release) |
| Selector | `-l name=trivy-operator` |
| Labels | `layer=platform, tier=infra, component=security` |
| Values | `values.yaml.gotmpl` |
| Scope | `targetNamespaces: ""` → **all namespaces** |

Scanners enabled: vulnerability, config-audit, RBAC assessment, exposed-secret.
`ignoreUnfixed: true` (only actionable CVEs), report TTL 24h, history limit 10 (prod) / 3.

---

## 1. Prerequisites

- `trivy-system` namespace with PSA **`privileged`** — the node-collector mounts hostPath.
  Created by `environments/<env>/kubernetes/namespace/namespaces.yaml`.
- `kube-prometheus-stack` for the ServiceMonitor CRD.
- **Registry access**: scan jobs pull image metadata. For private images (Harbor) the
  operator needs pull credentials — otherwise those images report as scan failures.
- Egress to the Trivy vulnerability DB (or a mirrored DB in an air-gapped cluster).

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f releases/platform/trivy-operator/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/trivy-operator/helmfile.yaml.gotmpl sync
```

Capacity note: the operator spawns a scan Job **per workload**. On a large cluster the
first pass creates a burst of pods — deploy it during a quiet window and watch node
pressure.

---

## 3. Verify

```bash
kubectl -n trivy-system rollout status deploy/trivy-operator --timeout=300s
kubectl get crd | grep aquasecurity

# reports start appearing within a few minutes
kubectl get vulnerabilityreports -A | head
kubectl get configauditreports -A | head
kubectl get exposedsecretreports -A
kubectl get rbacassessmentreports -A

# highest-severity findings, cluster-wide
kubectl get vulnerabilityreports -A -o json \
  | jq -r '.items[] | select(.report.summary.criticalCount>0)
           | "\(.metadata.namespace)/\(.metadata.name)\tCRITICAL=\(.report.summary.criticalCount)"'
```

---

## 4. Rollback

```bash
helm history trivy-operator -n trivy-system
helm rollback trivy-operator <REVISION> -n trivy-system --wait
```

Low risk: the operator is observational — it does **not** block deployments (that is
Kyverno's job). Uninstalling removes the report CRs, so export anything you need for an
audit trail first. Nothing about workload availability depends on it.

---

## 5. Monitoring & alerting

`serviceMonitor.enabled: true`, `metricsFindingsEnabled: true`.

| Signal | Metric |
|---|---|
| Critical CVEs | `trivy_image_vulnerabilities{severity="Critical"}` by namespace/workload |
| Exposed secrets | `trivy_exposed_secrets` > 0 — treat as an incident |
| Config audit failures | `trivy_resource_configaudits{severity="Critical"}` |
| Scan job failures | scan Jobs in `Failed` state in `trivy-system` |
| Coverage | workloads with no report = images that could not be scanned |

Alert on **exposed secrets** and on new Critical CVEs in production namespaces. Track
coverage too: an unscanned image is not a clean image.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No reports generated | Scan jobs failing — `kubectl -n trivy-system get jobs` then read a failed pod's logs. |
| `MANIFEST_UNKNOWN` / auth errors | Operator cannot pull from Harbor; configure registry credentials. |
| Scan jobs `Pending` | Node resources exhausted by the initial burst; lower concurrency or scan fewer namespaces. |
| DB download fails | No egress to the Trivy DB source — mirror it internally for air-gapped clusters. |
| Reports vanish | TTL is 24h by design; use the metrics for history, not the CRs. |
| PSA denies node-collector | `trivy-system` must be `privileged`. |

---

## 7. Notes

- `ignoreUnfixed: true` hides CVEs with no available fix. It reduces noise but also hides
  real risk — review unfixed criticals separately rather than assuming they do not exist.
- Two scanning layers: **CI** (`chart:scan` / image scan in `ci/k8s/main.yml`, blocks the
  build) and **runtime** (this operator, catches CVEs disclosed *after* the image shipped).
  You need both.
- Harbor also ships a bundled Trivy scanner for the registry; this operator scans what is
  actually **running**, which is the more important question.
