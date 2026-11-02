# bootstrap — Deploy (namespaces + PSA)

Raw manifests, **not** Helm releases. Namespaces go in **before everything** —
they are step 1 of any cluster build.

| File | When | Command |
|---|---|---|
| `namespaces.yaml` | **step 1** of any cluster build | `kubectl apply -f environments/<env>/kubernetes/namespace/` |

> **NetworkPolicies moved.** They now live in their own directory,
> [`network/`](NETWORK-POLICIES.md), and are still applied
> **last**, once the stack is healthy:
> `kubectl apply -f environments/<env>/kubernetes/network/`

---

## 1. namespaces.yaml — Pod Security Admission

Helm's `--create-namespace` creates namespaces **without labels**, so PSA would be
enforced nowhere. Pre-creating them here is what makes Pod Security Admission real.
Charts keep `createNamespace: true` — a harmless no-op once the namespace exists.

PSA level per namespace, set to the tightest each workload actually supports:

| Namespace | enforce | Why |
|---|---|---|
| `infra` | `baseline` | argocd needs fsGroup; ingress-nginx (legacy, until the Kong cutover) needs `NET_BIND_SERVICE` |
| `observability` | `privileged` | node-exporter uses hostNetwork/hostPath |
| `velero` | `privileged` | node-agent mounts hostPath |
| `trivy-system` | `privileged` | node-collector mounts hostPath |
| `database` | restricted-leaning | stateful stores run rootless |

`warn` / `audit` are pinned to `restricted` everywhere so violations surface in API
responses and the audit log **without** breaking the workload.

```bash
kubectl apply -f environments/<env>/kubernetes/namespace/
kubectl get ns -L pod-security.kubernetes.io/enforce
```

Skipping this step is the single most common cause of a build that "works" but has no
security boundary at all.

---

## 2. NetworkPolicies — in `../network/` and `../../<env>/network/`

Zero-trust ingress policies used to live here as `manifests/network-policies.yaml`.
They now have their own directory so that policies have a single home — see
[`kubernetes/docs/NETWORK-POLICIES.md`](NETWORK-POLICIES.md).

The ordering contract is unchanged: namespaces **first**, policies **last**.

```bash
kubectl apply -f environments/<env>/kubernetes/network/    # after every release is healthy
```

The `infra` namespace still has **no** default-deny policy, deliberately: it hosts
admission/conversion webhooks (cert-manager, external-secrets, kyverno, kong, ingress-nginx)
that the API server must reach. That reasoning, and the pattern for hardening it, is
documented in the new directory.

---

## 3. Verify

```bash
# PSA actually labelled
kubectl get ns infra observability database velero trivy-system \
  -o custom-columns=NS:.metadata.name,ENFORCE:.metadata.labels.pod-security\\.kubernetes\\.io/enforce
```

Namespace pods should schedule normally; a rejection naming `violates PodSecurity`
means the workload needs a looser level than the label allows.

---

## 4. Rollback

```bash
# Namespaces — DO NOT delete. Deleting a namespace cascade-deletes every release in it.
```

To relax PSA on one namespace instead of deleting anything:

```bash
kubectl label ns <ns> pod-security.kubernetes.io/enforce=privileged --overwrite
```

Treat that as a temporary incident action and revert it.

---

## 5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod rejected: `violates PodSecurity "restricted"` | Workload needs a looser level, or its securityContext is wrong. Fix the workload first; relax PSA only as a last resort. |
| Harbor core `CrashLoopBackOff` talking to Postgres | `database` default-deny blocking the `harbor` namespace — add an allow rule. |
| App cannot reach DB/Redis after applying policies | Missing `allow-apps-ingress`, or egress rules in `environments/<env>/kubernetes/app-values.yaml.gotmpl`. |
| Webhook timeouts cluster-wide | A default-deny was applied to `infra`. Remove it. |
| Prometheus targets all down after apply | The `from observability` allow rule is missing on that namespace. |

---

## 6. Notes

- These manifests are env-agnostic — the same file applies to dev/staging/prod.
- They are not managed by helmfile on purpose: they must exist before helm runs (namespaces)
  or after it finishes (policies), which helmfile ordering cannot express.
- Consider moving both under Argo CD later so drift is detected; today they are apply-once.
