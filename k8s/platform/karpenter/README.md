# Karpenter — Deploy

> **Values live in [`infra-base/k8s/platform/karpenter/`](../../../infra-base/k8s/platform/karpenter/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Node autoscaler for **AWS EKS**. Provisions right-sized EC2 nodes directly from pending
pods (no ASG round-trip) and consolidates under-used nodes.

| | |
|---|---|
| Chart | `oci://public.ecr.aws/karpenter/karpenter` |
| Version | `1.14.0` |
| Release / Namespace | `karpenter` / `kube-system` |
| Selector | `-l name=karpenter` |
| Labels | `layer=platform, tier=infra, component=autoscaling` |
| Values | `values.yaml.gotmpl` (+ `nodepool.yaml` applied separately) |
| Needs | `observability/kube-prometheus-stack` |
| Blast radius | **High** — it creates and terminates cluster nodes. |

> ⚠ **Mutually exclusive with `cluster-autoscaler`.** Running both on the same nodes
> causes them to fight over scale-down decisions. `cluster-autoscaler` is disabled by
> default (`ENABLE_CLUSTER_AUTOSCALER`); leave it that way when Karpenter is on.
> On non-EKS clusters, deselect Karpenter: `-l 'name!=karpenter'`.

---

## 1. Prerequisites (must exist **before** the first sync)

| Requirement | Why | Where to set |
|---|---|---|
| EKS cluster name | Karpenter targets it | `settings.clusterName` in `values.yaml.gotmpl` (currently `my-eks-<env>` — **placeholder**) |
| IRSA role ARN | EC2 + SQS API access | `serviceAccount.annotations` (currently `<ACCOUNT_ID>` — **placeholder**) |
| SQS interruption queue | Spot interruption handling | `settings.interruptionQueue` (`karpenter-<env>`) |
| Subnet + SG discovery tags | Node placement | tag AWS resources with `karpenter.sh/discovery=<clusterName>` |
| A default node role / instance profile | Nodes join the cluster | referenced by `EC2NodeClass` in `nodepool.yaml` |

The values file ships **placeholders**. Syncing without replacing them produces a
controller that cannot provision anything (and logs IAM `AccessDenied`).

---

## 2. Deploy

```bash
export ENV=prod
helmfile -e $ENV -f platform/karpenter/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/karpenter/helmfile.yaml.gotmpl sync

# NodePool + EC2NodeClass — Karpenter does nothing until these exist
kubectl apply -f platform/karpenter/manifests/nodepool.yaml
```

Sizing: 1 replica dev/staging, 2 in prod; controller requests 500m CPU / 512Mi.

---

## 3. Verify

```bash
kubectl -n kube-system rollout status deploy/karpenter --timeout=300s
kubectl get nodepool,ec2nodeclass
kubectl -n kube-system logs deploy/karpenter --tail=50 | grep -iE 'error|launched|disrupt'

# End-to-end test: force a pending pod and watch a node appear
kubectl create deploy scale-test --image=public.ecr.aws/docker/library/nginx:1.27 --replicas=20
kubectl get nodeclaims -w        # ctrl-c once a claim goes Ready
kubectl delete deploy scale-test
```

---

## 4. Rollback

```bash
helm history karpenter -n kube-system
helm rollback karpenter <REVISION> -n kube-system --wait
```

**Removing Karpenter does not remove its nodes.** If you uninstall, drain and delete
the NodeClaims first, otherwise you keep paying for orphaned EC2 instances:

```bash
kubectl delete nodepool --all      # stops new provisioning
kubectl get nodeclaims             # then drain/delete each remaining node
```

---

## 5. Monitoring & alerting

`serviceMonitor.enabled: true`.

| Signal | Metric |
|---|---|
| Provisioning failures | `karpenter_nodeclaims_launch_failed_total` |
| Pods that cannot be scheduled | `karpenter_pods_state{state="pending"}` sustained > 5m |
| Node churn | `karpenter_nodeclaims_terminated_total` rate |
| Disruption/consolidation activity | `karpenter_voluntary_disruption_decisions_total` |
| Interruption events consumed | `karpenter_interruption_received_messages_total` |

Alert on sustained pending pods with zero launches — that is Karpenter being unable to
provision (quota, IAM, subnet capacity), and it is silent otherwise.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No nodes launched, pods stay `Pending` | No `NodePool` applied, or the pod's requirements match no `EC2NodeClass`. |
| `AccessDenied` / `UnauthorizedOperation` in logs | IRSA role ARN placeholder not replaced, or the role lacks `ec2:RunInstances`/`sqs:*`. |
| `no subnets matched selector` | Missing `karpenter.sh/discovery` tags on subnets/SGs. |
| Nodes launch then never join | Wrong instance profile / node role in `EC2NodeClass`, or cluster security group not attached. |
| Nodes flap (launch → terminate) | Consolidation too aggressive — set `disruption.consolidationPolicy` / `budgets` in `nodepool.yaml`. |
| Spot nodes killed with no warning | Interruption queue name wrong → Karpenter never sees the 2-minute notice. |

---

## 7. Notes / risks

- Karpenter has cluster-wide authority to terminate nodes. Ensure every workload that
  matters has a **PDB** — this repo sets PDBs on prod platform releases for that reason.
- Prefer `nodepool.yaml` for consolidation policy and instance-type constraints; keep the
  Helm values limited to controller wiring.
- On-prem / non-EKS: skip this release entirely and use `cluster-autoscaler` only if
  fixed node groups exist.
