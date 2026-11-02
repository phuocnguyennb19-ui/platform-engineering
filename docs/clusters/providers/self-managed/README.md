# Generic self-managed Kubernetes

Metadata: [`../../../../dev/cluster/self-managed-dev.yaml`](../../../../environments/dev/kubernetes/cluster/self-managed-dev.yaml) ·
environment `dev`. Apps use the `dev` values; select this cluster for `dev` in
`dev/cluster/target.local.yaml` and deploy with `helmfile -e dev -l name=<app> sync` from the repository root.

The repository holds no evidence of which distribution, CNI or storage system a self-managed
cluster uses, so none is prescribed. This page separates what must be **provisioned** (the
cluster) from what is **workload configuration** (everything this repository deploys onto it).
Commands are marked **[read]** or **[CHANGES STATE]**; nothing is run for you.

A worked, tested example on a laptop — two Lima VMs, `kubeadm init` + `kubeadm join`, Calico,
`serverTLSBootstrap` — is in [`docs/20-runbooks/local-cluster-kubeadm.md`](../../../20-runbooks/local-cluster-kubeadm.md).

## 0. New cluster or existing one?

| Situation | Go to |
|---|---|
| A team already operates the cluster | §2 — ask for a named identity and a kubeconfig; never reinstall |
| You are building it | §1, then §2 |

## 1. Provision a new cluster [CHANGES STATE]

Provisioning ends when the API answers, nodes are `Ready` and DNS works. Ingress, storage
classes and monitoring are platform choices made afterwards (§4), not part of the install.

| Step | Requirement | Reference |
|---|---|---|
| Nodes | Supported Linux; container runtime (containerd) with the systemd cgroup driver; swap off or explicitly allowed; unique hostnames; time in sync; `br_netfilter` + `net.ipv4.ip_forward=1` | upstream "Installing kubeadm" |
| Control plane | One stable API address (VIP or load balancer) before the first `init` — it is baked into every certificate and kubeconfig; 3 control-plane nodes for HA | [`kubeadm-config.example.yaml.txt`](kubeadm-config.example.yaml.txt) |
| Workers | Join with the token/CA hash printed by `kubeadm init` (short-lived; regenerate with `kubeadm token create --print-join-command` on a control-plane node) — never stored in git | upstream "Creating a cluster with kubeadm" |
| CNI | Chosen and installed right after `init`; its pod CIDR must equal `podSubnet`. Must enforce NetworkPolicy — the chart renders NetworkPolicies (`networkPolicy.enabled` in the dev app values) and `environments/<env>/kubernetes/network/` relies on them | your CNI's docs |
| Kubernetes version | Same minor as the rest of the platform (EKS dev: `1.32`, `environments/dev/terraform/core.yaml`) | |

Other distributions (RKE2, Talos, …) satisfy the same table with their own tools.

## 2. Connect — kubeconfig context

- Use a **named** identity (OIDC, or a client certificate per person / pipeline with an
  expiry), not the `admin.conf` that `kubeadm init` writes — that file is cluster-admin with
  no audit trail of who used it.
- Keep the kubeconfig in its own file (`chmod 600`), with a context alias such as
  `self-managed-dev`; put that alias into `dev/cluster/self-managed-dev.yaml`.
- The API certificate must include the address in the kubeconfig; a `x509` error on the
  first call is a trust/SAN problem, not an outage.

```bash
kubectl --kubeconfig "$HOME/.kube/self-managed-dev.yaml" --context=self-managed-dev auth whoami   # [read] (Kubernetes ≥ 1.28)
```

## 3. Check — preflight

```bash
make k8s-preflight CLUSTER=self-managed-dev CONTEXT=self-managed-dev KUBECONFIG_FILE=$HOME/.kube/self-managed-dev.yaml   # [read]
```

## 4. Workload configuration (after provisioning)

`CTX=self-managed-dev`, plus `--kubeconfig <file>` when it is not in your default kubeconfig.

| Capability | What must exist | Read-only check |
|---|---|---|
| Cluster DNS | CoreDNS or equivalent, Deployment `k8s-app=kube-dns` in `kube-system` | preflight check 5 |
| Ingress | A controller serving the class the values use (every env uses `kong` — Kong Ingress Controller, `kubernetes/releases/platform/kong`) | `C ingress` |
| LoadBalancer Services | Bare metal has no cloud LB: MetalLB, kube-vip or an external LB must assign addresses | `kubectl --context="$CTX" get svc -A --field-selector spec.type=LoadBalancer` — `<pending>` means nothing does **[read]** |
| Storage | A provisioner with exactly one default StorageClass, if anything uses PVCs | `C persistentStorage` |
| Monitoring CRDs + operator | Only for apps that opt in with `prometheusRule.enabled: true`: PrometheusRule CRD **and** a running Prometheus Operator | `C prometheusOperator` |
| Gateway API | CRDs + a GatewayClass Accepted by a controller, only if used | `C gatewayAPI` |
| Authorization | RBAC on; the preflight identity can read nodes, namespaces, CRDs, StorageClasses, IngressClasses, Deployments, DaemonSets | preflight check 16 |

A CRD without its controller installs cleanly and then does nothing — preflight checks both.
