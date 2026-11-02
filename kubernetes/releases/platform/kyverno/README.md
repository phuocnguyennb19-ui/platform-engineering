# Kyverno — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/kyverno/`](../../../../environments/dev/kubernetes/tools/kyverno/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Policy admission controller: validates, mutates and generates Kubernetes resources against
policies kept in git. It sits **on the API request path** — treat every change as a
cluster-wide change.

| | |
|---|---|
| Chart | `kyverno/kyverno` |
| Version | `3.8.2` |
| Release / Namespace | `kyverno` / `infra` |
| Selector | `-l name=kyverno` |
| Labels | `layer=platform, tier=infra, component=policy` |
| Values | `values.yaml.gotmpl` |
| Policies | `policies.yaml`, `policies-supplychain.yaml` — applied **after** the release |
| Replicas (prod) | admission 3, background/reports/cleanup 2 each |

Admission controller replicas: **3 in prod** because a single unavailable webhook can block
every create/update in the cluster.

---

## 1. Prerequisites

- `infra` namespace (PSA `baseline`), with **no default-deny NetworkPolicy** — the API
  server must reach the webhook. See `kubernetes/docs/NAMESPACES.md`.
- `kube-prometheus-stack` for the ServiceMonitor CRDs (all four controllers export metrics).

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f releases/platform/kyverno/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/kyverno/helmfile.yaml.gotmpl sync

# policies come AFTER the admission controller is Available
kubectl wait --for=condition=Available deploy/kyverno-admission-controller -n infra --timeout=300s
kubectl apply -f releases/platform/kyverno/manifests/policies.yaml
kubectl apply -f releases/platform/kyverno/manifests/policies-supplychain.yaml
```

---

## 3. Policy rollout discipline

Kyverno 1.13+ sets `failureAction` **per rule** (`spec.validationFailureAction` was
removed). What ships here:

| Policy | File | Action | Scope |
|---|---|---|---|
| `disallow-latest-tag` | `policies.yaml` | Audit | cluster |
| `require-requests-limits` | `policies.yaml` | Audit | cluster |
| `disallow-privileged` | `policies.yaml` | Audit | cluster |
| `require-readonly-rootfs` | `policies.yaml` | Audit | cluster |
| `pod-security-restricted` | `policies.yaml` | Audit | cluster |
| **`require-trusted-registry`** | `policies-supplychain.yaml` | **Enforce** | `dev`, `staging`, `prod` only |
| `require-image-digest` | `policies-supplychain.yaml` | Audit | `prod` |
| `verify-image-signatures` | `policies-supplychain.yaml` | Audit | app namespaces |

> ⚠ **`require-trusted-registry` is the one policy that actually blocks.** App pods in
> `dev`/`staging`/`prod` must pull from `harbor.*.example.com/*` or
> `registry.gitlab.com/myorg/*`. Deploying an app image from Docker Hub into those
> namespaces will be **rejected at admission**. Infra namespaces are deliberately excluded
> (upstream images come from quay.io, registry.k8s.io, ghcr.io, public.ecr.aws).

Everything else is Audit on purpose: read the reports first, fix the violations, and only
then enforce — one policy at a time, starting with the app namespaces.

```bash
# read the violations
kubectl get cpolr                 # cluster-scoped policy reports
kubectl get polr -A               # namespaced
kubectl get polr -A -o json | jq -r '.items[].results[] | select(.result=="fail") | "\(.policy)\t\(.rule)\t\(.resources[0].name)"' | sort | uniq -c | sort -rn
```

Then flip a single rule (note: `failureAction` lives under `validate`, per rule):

```yaml
spec:
  rules:
    - name: <rule>
      validate:
        failureAction: Enforce      # was: Audit
```

Switching everything to `Enforce` at once is the fastest way to break every deploy in the
cluster, including the platform's own releases.

---

## 4. Verify

```bash
kubectl -n infra get pods -l app.kubernetes.io/part-of=kyverno
kubectl get clusterpolicy
kubectl get clusterpolicy -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status,ACTION:.spec.rules[0].validate.failureAction

# webhooks registered
kubectl get validatingwebhookconfigurations | grep kyverno

# functional check: a policy actually fires
kubectl run bad --image=nginx:latest --dry-run=server 2>&1 | grep -i disallow-latest-tag
```

---

## 5. Rollback

```bash
helm history kyverno -n infra
helm rollback kyverno <REVISION> -n infra --wait
```

🔴 **Emergency: Kyverno is blocking all deploys.** The webhook failure policy decides
whether an unavailable Kyverno fails open or closed. If the cluster is wedged:

```bash
# 1. Relax the offending policy first (preferred)
kubectl patch clusterpolicy <name> --type merge -p '{"spec":{"rules":[{"validate":{"failureAction":"Audit"}}]}}'

# 2. Last resort — remove the webhook so the API server stops calling Kyverno
kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg
```

Option 2 disables policy enforcement cluster-wide. Do it only during an incident, record
it, and restore it (the controller recreates the webhook) immediately after.

---

## 6. Monitoring & alerting

ServiceMonitors are enabled on all four controllers.

| Signal | Metric |
|---|---|
| Admission latency | `kyverno_admission_review_duration_seconds` p99 — this is added to **every** API write |
| Policy results | `kyverno_policy_results_total{result="fail"}` by policy |
| Policy execution errors | `kyverno_policy_execution_duration_seconds` + `error` results |
| Webhook availability | `up{job=~"kyverno.*"}`, admission controller replica count |
| Reports controller lag | report freshness vs cluster changes |

Alert on admission latency: a slow policy slows down every deployment in the cluster.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Every `kubectl apply` times out | Admission webhook unreachable — check pods, then NetworkPolicy on `infra`. |
| A platform release fails to install | A policy rejects the chart's pods (privileged DaemonSets: node-exporter, Falco, Velero node-agent). Exclude those namespaces in the policy. |
| App pod rejected: "image must come from a trusted registry" | `require-trusted-registry` is **Enforce**. Push the image to Harbor/GitLab; do not widen the allowlist casually. |
| `disallow-latest-tag` report on an image | Audit-only today. Pin the tag before enforcing. |
| Policy shows `Ready=False` | Invalid policy definition — `kubectl describe clusterpolicy <name>`. |
| Reports empty | reports-controller down, or policies are all `Enforce` (blocked resources produce no report). |
| Mutation not applied | Mutate rules only fire on create/update; existing resources need a background scan or re-apply. |

---

## 8. Notes

- Policies live in git (`policies.yaml`, `policies-supplychain.yaml`) and are applied with
  `kubectl` because they must land **after** the controller is healthy — helmfile cannot
  express that ordering.
- The supply-chain policies pair with Harbor + Trivy + image signing in the CI pipeline;
  enforcing image-signature checks without a working signing step will block all deploys.
- Kyverno enforces at admission. It is complementary to **PSA** (namespace-level baseline)
  and **Falco** (runtime detection) — none of the three replaces the others.
