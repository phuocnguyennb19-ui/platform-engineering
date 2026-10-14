# cluster-autoscaler — Deploy

> **Values live in [`infra-base/k8s/platform/cluster-autoscaler/`](../../../infra-base/k8s/platform/cluster-autoscaler/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Scales AWS **ASG node groups** up/down based on pending pods. Exists for clusters where
Karpenter is not an option (non-EKS, fixed ASGs, regulated node images).

| | |
|---|---|
| Chart | `autoscaler/cluster-autoscaler` |
| Version | `9.46.6` |
| Release / Namespace | `cluster-autoscaler` / `kube-system` |
| Selector | `-l name=cluster-autoscaler` |
| Labels | `layer=platform, tier=infra, component=autoscaling` |
| Values | `values.yaml.gotmpl` |
| Installed | **`false` by default** — gated on `ENABLE_CLUSTER_AUTOSCALER=true` |
| Needs | `observability/kube-prometheus-stack` |

> ⚠ **Never run together with Karpenter.** Two autoscalers on the same nodes make
> contradictory scale-down decisions and cause node flapping. Pick one:
> Karpenter (preferred on EKS) **or** this.

---

## 1. Prerequisites

| Requirement | Where |
|---|---|
| `ENABLE_CLUSTER_AUTOSCALER=true` exported | shell / CI variable — otherwise `installed: false` |
| Karpenter disabled | `-l 'name!=karpenter'`, or drop `karpenter/` from the root `helmfile.yaml.gotmpl` include list |
| IRSA role ARN | `rbac.serviceAccount.annotations` — replace `<ACCOUNT_ID>` |
| ASGs tagged for discovery | `k8s.io/cluster-autoscaler/enabled`, `k8s.io/cluster-autoscaler/eks-<env>` |
| ASG min/max sized correctly | Cluster Autoscaler never exceeds the ASG max |
| Region correct | `awsRegion: ap-southeast-1` in the values file |

---

## 2. Deploy

```bash
export ENV=prod
export ENABLE_CLUSTER_AUTOSCALER=true

helmfile -e $ENV -f platform/cluster-autoscaler/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/cluster-autoscaler/helmfile.yaml.gotmpl sync
```

Scale policy in `values.yaml.gotmpl`: `expander: least-waste`,
`scale-down-unneeded-time` 10m (prod) / 5m (non-prod),
`scale-down-utilization-threshold: 0.5`, `balance-similar-node-groups: true`.

---

## 3. Verify

```bash
kubectl -n kube-system rollout status deploy/cluster-autoscaler-aws-cluster-autoscaler --timeout=180s

# The status ConfigMap is the authoritative view of what CA thinks it can do
kubectl -n kube-system get cm cluster-autoscaler-status -o yaml | head -40
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=50
```

Expect each discovered node group listed with `health=Healthy` and a sane min/max.

---

## 4. Rollback

```bash
helm history cluster-autoscaler -n kube-system
helm rollback cluster-autoscaler <REVISION> -n kube-system --wait
```

To disable entirely: unset `ENABLE_CLUSTER_AUTOSCALER` and re-sync — the release flips to
`installed: false` and helmfile uninstalls it. Nodes already running stay; the ASG keeps
its current desired count.

---

## 5. Monitoring & alerting

`serviceMonitor.enabled: true` (namespace `kube-system`, selector `release: kube-prometheus-stack`).

| Signal | Metric |
|---|---|
| Unschedulable backlog | `cluster_autoscaler_unschedulable_pods_count` > 0 for 10m |
| Scale-up failures | `cluster_autoscaler_failed_scale_ups_total` |
| At ASG ceiling | `cluster_autoscaler_max_nodes_count` vs `cluster_autoscaler_nodes_count` |
| Loop health | `cluster_autoscaler_last_activity` staleness |

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pods `Pending`, no scale-up | ASG already at max, or no node group can satisfy the pod's resources/affinity. Read `cluster-autoscaler-status`. |
| `AccessDenied` on `autoscaling:*` | IRSA role missing / `<ACCOUNT_ID>` placeholder not replaced. |
| No node groups discovered | ASG discovery tags missing or wrong `clusterName` (`eks-<env>`). |
| Node never scales down | Pods without a PDB, local storage, or `kube-system` pods pinned there. `skip-nodes-with-system-pods: false` is already set; check `safe-to-evict` annotations. |
| Nodes flap with Karpenter installed | Both autoscalers active — disable one. |

---

## 7. Notes

- `skip-nodes-with-local-storage: false` means CA **will** evict pods with `emptyDir`.
  Stateful workloads must rely on PVCs + PDBs, not local disk.
- `priorityClassName: system-cluster-critical` keeps CA itself from being evicted during
  a scale-down it initiated.
