# K3s

Metadata: [`../../../../dev/cluster/k3s-dev.yaml`](../../../../environments/dev/kubernetes/cluster/k3s-dev.yaml) · environment `dev`.
Apps use the `dev` values; point `dev` at this cluster in `environments/dev/kubernetes/cluster/target.local.yaml`
(`cluster: k3s-dev` and, if your context has another name, `context: <your-k3s-context>`), then from the repository root
`helmfile -e dev -l name=<app> sync` (guarded by `scripts/deploy/release-guard.sh`).

Commands are marked **[read]** or **[CHANGES STATE]**. Nothing here is run for you; installing
or changing a server is always an explicit decision of whoever owns the machine.

## 0. New cluster or existing one?

| Situation | Go to |
|---|---|
| Someone already runs the K3s cluster | §2 — only a kubeconfig is needed; never reinstall |
| You are building it | §1, then §2 |

## 1. Provision a new K3s cluster [CHANGES STATE]

**Nodes.** Linux, 2 vCPU / 4 GiB per server at minimum, unique hostnames, time in sync,
swap off, firewall open between nodes for 6443/tcp (API), 10250/tcp (kubelet), 8472/udp
(flannel VXLAN) and 2379–2380/tcp (embedded etcd, HA only).

**Server config.** Write `/etc/rancher/k3s/config.yaml` **before** installing, starting from
[`config.example.yaml.txt`](config.example.yaml.txt). It disables the bundled Traefik
because the repository's values expect the Kong IngressClass (`kong`), and adds the
API address to the certificate SANs. Decide every line; nothing in it is required by K3s.

**Install.** Use the official installer and pin the version — the version must match the
Kubernetes minor the rest of the platform is tested with (EKS dev runs `1.32`, see
`environments/dev/terraform/core.yaml`):

```bash
# on the first server                                                   [CHANGES STATE]
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<v1.32.x+k3s1> sh -s - server
# on each agent; the join token lives on the server in
# /var/lib/rancher/k3s/server/node-token — copy it over a secure channel, never into git
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<v1.32.x+k3s1> K3S_URL=https://<api-address>:6443 K3S_TOKEN=<join-token> sh -
```

Review the installer script before piping it to a shell if your policy requires it.

## 2. Connect — kubeconfig context

K3s writes `/etc/rancher/k3s/k3s.yaml` (root-only) with context `default` and server
`https://127.0.0.1:6443`. Neither is usable from another machine as-is:

1. Copy the file to your machine over a secure channel into its **own** file, e.g.
   `~/.kube/k3s-dev.yaml` (`chmod 600`). It contains a client certificate and key: never
   commit it, never paste it into a ticket.
2. In that copy, replace `127.0.0.1` with the API address and rename the context/cluster/user
   `default` to an alias such as `k3s-dev`. **[CHANGES STATE: your local file only]**
3. Put the alias into `dev/cluster/k3s-dev.yaml` (`context:`), replacing `<k3s-dev-context>`.

Keep it as a separate file and pass it explicitly — nothing merges into `~/.kube/config`:

```bash
kubectl --kubeconfig "$HOME/.kube/k3s-dev.yaml" --context=k3s-dev get nodes          # [read]
```

## 3. Check — preflight

```bash
make k8s-preflight CLUSTER=k3s-dev CONTEXT=k3s-dev KUBECONFIG_FILE=$HOME/.kube/k3s-dev.yaml   # [read]
```

Expected on K3s: check 9 WARNs (flannel is built into the k3s binary, no DaemonSet); storage
reports `rancher.io/local-path` and the `local-path-provisioner` Deployment; `C ingress`
FAILs until an ingress controller serving `kong` runs (the kong release) (Traefik if you kept it registers
class `traefik`, which the repository values do not use).

## 4. Read-only verification by hand

`CTX=k3s-dev`, plus `--kubeconfig <file>` if it is not in your default kubeconfig.

| What | Command [read] | Expect |
|---|---|---|
| Nodes | `kubectl --context="$CTX" get nodes -o wide` | all `Ready`, version `+k3s` |
| Traefik | `kubectl --context="$CTX" get helmcharts.helm.cattle.io -n kube-system` | `traefik` only if not disabled |
| ServiceLB | `kubectl --context="$CTX" get daemonsets -n kube-system -l svccontroller.k3s.cattle.io/svcname` | `svclb-*` per LoadBalancer Service, none if disabled |
| CNI | `kubectl --context="$CTX" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.flannel\.alpha\.coreos\.com/backend-type}{"\n"}{end}'` | flannel backend, or another CNI's DaemonSet |
| Storage | `kubectl --context="$CTX" get storageclass` | `local-path (default)` — node-local; data does not follow a pod |
| CRDs / controllers | `kubectl --context="$CTX" get crd` · `kubectl --context="$CTX" get deployments -A` | what was added |

Server flags, on a server node — select keys, do not print the file (it may hold `token:`):

```bash
sudo grep -E '^(disable|flannel-backend|disable-network-policy|tls-san|cluster-cidr|service-cidr)' /etc/rancher/k3s/config.yaml   # [read]
```
