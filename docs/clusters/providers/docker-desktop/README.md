# Docker Desktop Kubernetes

Metadata: [`../../../../dev/cluster/docker-desktop-dev.yaml`](../../../../environments/dev/kubernetes/cluster/docker-desktop-dev.yaml) — Docker
Desktop as a deploy target of the `dev` environment (namespace `dev`, context `docker-desktop`).

Commands are marked **[read]** (changes nothing) or **[CHANGES STATE]** (run it yourself,
deliberately). Nothing in this repository runs a [CHANGES STATE] command for you.

## 1. Provision — enable Kubernetes

Docker Desktop creates the cluster itself; this repository never does.

1. Docker Desktop → Settings → Kubernetes → **Enable Kubernetes** → Apply & restart.
   **[CHANGES STATE]** (creates the cluster inside the Docker VM — single node, or a
   control-plane plus workers when the multi-node option is chosen)
2. Wait until the Kubernetes indicator in the Docker Desktop window is green.

If Kubernetes is not enabled, the context below does not exist (or does not answer) and
preflight stops with exit 2 or FAIL on check 3 — it never tries to enable it.

## 2. Connect — kubeconfig context

Docker Desktop adds the context `docker-desktop` to `~/.kube/config` when Kubernetes starts.

```bash
kubectl config get-contexts -o name | grep -Fx docker-desktop         # [read]
kubectl --context=docker-desktop get nodes -o wide                    # [read]
```

Select it as the `dev` target on your machine (gitignored file):

```yaml
# environments/dev/kubernetes/cluster/target.local.yaml
schema: kubernetes-target/v1alpha1
cluster: docker-desktop-dev
```

Never `kubectl config use-context`: every command here names its context.

## 3. Check — preflight

```bash
make k8s-preflight CLUSTER=docker-desktop-dev                          # [read]
# same as: bash scripts/cluster/preflight.sh --cluster docker-desktop-dev
```

What a fresh Docker Desktop cluster typically reports, and why:

| Result | Check | Meaning |
|---|---|---|
| PASS | 1–7 | cluster up, CoreDNS available |
| WARN | 8 namespaces | `dev` does not exist until it is created (see §4) |
| WARN | 9 CNI DaemonSets | the pod network is built in; only `kube-proxy` is a DaemonSet |
| PASS | 10 / C persistentStorage | a default StorageClass and its provisioner |
| WARN | C ingress (optional) | no ingress controller ships with Docker Desktop |
| WARN | C prometheusOperator (optional) | no monitoring CRDs; only apps that set `prometheusRule.enabled: true` need them |

## 4. Deploy an app

```bash
# Infra Base: the same namespaces + PSA labels as the cloud clusters (incl. `dev`), once   [CHANGES STATE]
kubectl --context=docker-desktop diff -f environments/dev/kubernetes/namespace/namespaces.yaml
kubectl --context=docker-desktop apply -f environments/dev/kubernetes/namespace/namespaces.yaml

# one app, from the repository root                                              [CHANGES STATE]
helmfile -e dev -l name=<app> diff
helmfile -e dev -l name=<app> sync

# reach it without an ingress controller                                         [read]
kubectl --context=docker-desktop -n dev port-forward svc/<app>-application 8080:80
```

Full sequence, command by command (namespaces → CRDs → cert-manager → metrics-server → kong → apps → teardown):
[`docs/20-runbooks/local-docker-desktop.md`](../../../20-runbooks/local-docker-desktop.md).

The dev values pull images from the dev ECR (`global.imageRegistry`) unless the app sets its
own `image.registry` (e.g. `docker.io`); a laptop cluster usually needs the latter.

**Ingress controller:** the dev values expect IngressClass `kong`; the app tier does not
install it on a laptop cluster. Install the platform `kong` release **[CHANGES STATE]**, or use `port-forward`:

```bash
T=kubernetes/releases/platform/kong/helmfile.yaml.gotmpl
# first install only: helm-diff cannot map the KongClusterPlugin CRs before the chart's CRDs exist
helmfile -e dev --kube-context docker-desktop -f $T diff --diff-args '--disable-validation'
helmfile -e dev --kube-context docker-desktop -f $T sync
kubectl --context=docker-desktop -n infra get svc kong-proxy                     # EXTERNAL-IP assigned?
kubectl --context=docker-desktop -n infra port-forward svc/kong-proxy 8080:80   # curl -H 'Host: <app host>' localhost:8080
```

The dev values ask for `type: LoadBalancer`. Docker Desktop in kind mode runs a `kind-cloud-provider`
container that should assign LoadBalancer addresses — **not verified here** (kong never started on this
machine's Docker Desktop because the image pull failed). If `kong-proxy` stays `<pending>`, `wait: true`
blocks the sync until the 900 s timeout: rerun with the local-only override `--set proxy.type=ClusterIP`.
The image is `docker.io/library/kong:3.9`: the Docker Desktop engine must reach Docker Hub
(`docker pull kong:3.9` from the host is a quick check).

**metrics-server (local-only override):** only needed for HPA / `kubectl top`. Docker Desktop's kind
nodes serve kubelet certificates without IP SANs, so with the shared `dev` values metrics-server never
becomes Ready (`x509: cannot validate certificate for 172.18.0.x because it doesn't contain any IP SANs`).
On this laptop cluster only, add `--kubelet-insecure-tls` on the command line — never in
`environments/<env>/kubernetes/tools/metrics-server/values.yaml.gotmpl`, which EKS dev uses too
**[CHANGES STATE]**:

```bash
helmfile -e dev --kube-context docker-desktop \
  -f kubernetes/releases/platform/metrics-server/helmfile.yaml.gotmpl diff \
  --set 'args={--kubelet-preferred-address-types=InternalIP\,Hostname\,ExternalIP,--kubelet-insecure-tls}'
# same flags with `sync` once the diff shows only the added flag
kubectl --context=docker-desktop get apiservice v1beta1.metrics.k8s.io     # AVAILABLE True   [read]
kubectl --context=docker-desktop top nodes                                  # [read]
```

The flag skips verification of the kubelet certificate (a spoofed kubelet could feed fake metrics or
receive metrics-server's token). Acceptable on a single-user laptop cluster; on kubeadm/K3s fix the
certificates instead (kubelet `serverTLSBootstrap: true` + approved CSRs). EKS does not need it.
A later `sync` without `--set` drops the flag again.

**Monitoring CRDs:** only if an app enables `prometheusRule` — **[CHANGES STATE]**:
`helmfile -e dev --kube-context docker-desktop -f kubernetes/releases/observability/prometheus-operator-crds/helmfile.yaml.gotmpl sync`

## 5. Read-only verification by hand

| What | Command [read] | Expect |
|---|---|---|
| Nodes, architecture | `kubectl --context=docker-desktop get nodes -L kubernetes.io/arch` | `Ready`; `arm64` on Apple silicon — images must be multi-arch |
| CoreDNS | `kubectl --context=docker-desktop get deployment -n kube-system -l k8s-app=kube-dns` | `coredns` available |
| Storage | `kubectl --context=docker-desktop get storageclass` | one `(default)` |
| Ingress | `kubectl --context=docker-desktop get ingressclass` | empty until a controller is installed |
| App pods and their node | `kubectl --context=docker-desktop -n dev get pods -o wide` | `Running`, column `NODE` |
