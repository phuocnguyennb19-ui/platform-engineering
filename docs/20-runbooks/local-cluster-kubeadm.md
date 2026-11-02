# Cluster local từ đầu: tạo VM → kubeadm init → join node → deploy

Từng bước, từ máy trống đến app chạy qua Ingress, trên một cluster Kubernetes **self-managed** thật trên
laptop: 1 control-plane + 1 worker, `kubeadm init` / `kubeadm join`, Calico (thực thi NetworkPolicy),
chứng chỉ kubelet do CA của cluster ký. Đã chạy thật 2026-10-23 trên Apple M4 (macOS, 16 GB):
Lima 2.2.1, Ubuntu 24.04, containerd 2.2.1, Kubernetes **v1.32.13** (cùng minor với EKS dev,
`environments/dev/terraform/core.yaml`), Calico v3.30.7. Metadata: `environments/dev/kubernetes/cluster/self-managed-dev.yaml`.

| Node | VM Lima | vCPU / RAM / disk | Hostname trong mạng VM |
|---|---|---|---|
| control-plane | `k8s-cp` | 2 / 4 GiB / 20 GiB | `lima-k8s-cp.internal` |
| worker | `k8s-worker1` | 2 / 3 GiB / 20 GiB | `lima-k8s-worker1.internal` |

| Bước | Việc | Kết quả mong đợi |
|---|---|---|
| [1](#bước-1--tạo-vm--máy-bạn) | Tạo 2 VM | `limactl list`: 2 VM `Running`; worker phân giải được `lima-k8s-cp.internal` |
| [2](#bước-2--chuẩn-bị-node--chạy-trên-mọi-vm-) | Chuẩn bị node (containerd, kubeadm) | mỗi VM in `containerd 2.x · kubeadm v1.32.x` |
| [3](#bước-3--kubeadm-init-trên-control-plane-) | `kubeadm init` | `Your Kubernetes control-plane has initialized successfully!` |
| [4](#bước-4--kubeconfig-trên-máy-bạn-) | Kubeconfig về máy bạn | `get nodes` thấy `lima-k8s-cp` (`NotReady` là đúng lúc này) |
| [5](#bước-5--cni-calico-) | Calico | node `Ready` |
| [6](#bước-6--join-worker-) | Join worker | `This node has joined the cluster`; 2 node `Ready` |
| [7](#bước-7--duyệt-chứng-chỉ-kubelet-) | Duyệt chứng chỉ kubelet | `tigerastatus`: tất cả `AVAILABLE True` |
| [7b](#bước-7b--loadbalancer-metallb-) | MetalLB (LoadBalancer cho cluster) | controller + 2 speaker `Running` |
| [8](#bước-8--nối-cluster-vào-repo-) | Nối vào repo + preflight | preflight `FAIL 1` (chỉ `C ingress`, hết sau bước 9) |
| [9](#bước-9--deploy-infra-base--platform--app-lên-cluster-mới) | Namespace → metrics-server → kong → app → NetworkPolicy | app trả 200 qua Kong |
| [9b](#bước-9b--tls-cho-ingress-cert-manager--ca-local-) | TLS: CRD monitoring → cert-manager → CA local → app dùng CA local | Certificate `READY True`; Ingress có ADDRESS |
| [10](#bước-10--kiểm-tra-cuối) | Kiểm tra cuối | preflight `FAIL 0` |
| [11](#bước-11--vận-hành-cluster-local) | Sau đó: dừng/bật, thêm/gỡ node, xoá cluster | |

Lệnh deploy và vận hành chung (đổi cấu hình, rollback, thêm app/tool, lỗi thường gặp):
[`kubernetes-manual.md`](kubernetes-manual.md). Đã có cluster khác thì không cần file này.

## Bước 1 — Tạo VM 🟡 (máy bạn)

```bash
brew install lima
for n in k8s-cp:4 k8s-worker1:3; do
  limactl create -y --name=${n%%:*} --cpus=2 --memory=${n##*:} --disk=20 \
    --containerd=none --mount-none --network=lima:user-v2 template:ubuntu-24.04
  limactl start -y ${n%%:*}
done
limactl list
limactl shell k8s-worker1 -- getent hosts lima-k8s-cp.internal      # VM thấy nhau qua mạng user-v2
```

- `--containerd=none`: kubeadm dùng containerd hệ thống (cài ở 0.2), không dùng containerd của Lima.
- `--mount-none`: VM không thấy thư mục home của bạn.
- `lima:user-v2`: mạng chung giữa các VM (192.168.104.0/24), tên `lima-<vm>.internal`.

## Bước 2 — Chuẩn bị node — chạy trên **mọi** VM 🟡

```bash
cat > /tmp/node-prep.sh <<'EOF'
set -euo pipefail
K8S_MINOR=v1.32
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay; modprobe br_netfilter
cat > /etc/sysctl.d/99-k8s.conf <<'S'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
S
sysctl --system >/dev/null
swapoff -a
apt-get update -qq
apt-get install -y -qq containerd apt-transport-https ca-certificates curl gpg >/dev/null
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml   # cgroup driver = kubelet
systemctl restart containerd && systemctl enable containerd >/dev/null
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
apt-mark hold kubelet kubeadm kubectl >/dev/null          # không tự nâng version
systemctl enable kubelet >/dev/null
echo "containerd $(containerd --version | awk '{print $3}') · kubeadm $(kubeadm version -o short)"
EOF
for n in k8s-cp k8s-worker1; do limactl shell $n -- sudo bash -s < /tmp/node-prep.sh; done
```

## Bước 3 — `kubeadm init` trên control-plane 🟡

```bash
cat > /tmp/kubeadm-config.yaml <<'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.32.13
clusterName: self-managed-dev
controlPlaneEndpoint: "lima-k8s-cp.internal:6443"   # tên ổn định, không phải IP của node
apiServer:
  certSANs: [lima-k8s-cp.internal, 127.0.0.1, localhost]   # 127.0.0.1: máy bạn vào API qua port forward của Lima
networking:
  podSubnet: 10.244.0.0/16      # = IPPool của Calico (0.5); không trùng mạng VM 192.168.104.0/24
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true        # chứng chỉ kubelet do CA cluster ký, có IP SAN → metrics-server kiểm TLS được
EOF
limactl copy /tmp/kubeadm-config.yaml k8s-cp:/tmp/kubeadm-config.yaml
limactl shell k8s-cp -- sudo kubeadm init --config /tmp/kubeadm-config.yaml
```

Output in ra một lệnh `kubeadm join … --token … --discovery-token-ca-cert-hash …` — **không** copy nó vào
đâu cả (token là credential); 0.6 tạo token mới, ngắn hạn.

## Bước 4 — Kubeconfig trên máy bạn 🟡

```bash
KC=~/.kube/self-managed-dev.yaml
limactl shell k8s-cp -- sudo cat /etc/kubernetes/admin.conf > $KC && chmod 600 $KC
kubectl --kubeconfig $KC config rename-context kubernetes-admin@self-managed-dev self-managed-dev
kubectl --kubeconfig $KC config set-cluster self-managed-dev --server=https://127.0.0.1:6443
export KUBECONFIG=~/.kube/config:~/.kube/self-managed-dev.yaml     # mọi lệnh sau đây cần biến này
kubectl --context=self-managed-dev get nodes                       # NotReady cho tới khi có CNI
```

`admin.conf` là cluster-admin không định danh — chấp nhận cho lab một người; cluster dùng chung thì cấp
identity riêng từng người ([self-managed guide §2](../clusters/providers/self-managed/README.md#2-connect--kubeconfig-context)).
Không commit, không gửi file này.

## Bước 5 — CNI: Calico 🟡

```bash
C=self-managed-dev
kubectl --context=$C create -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.7/manifests/tigera-operator.yaml
kubectl --context=$C apply --server-side -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.7/manifests/operator-crds.yaml
kubectl --context=$C wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s
kubectl --context=$C create -f - <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata: { name: default }
spec:
  registry: quay.io/                  # image Calico từ quay.io, không qua Docker Hub
  calicoNetwork:
    ipPools:
      - { name: default-ipv4-ippool, cidr: 10.244.0.0/16, encapsulation: VXLANCrossSubnet, natOutgoing: Enabled, nodeSelector: all() }
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata: { name: default }
spec: {}
EOF
kubectl --context=$C wait --for=condition=Ready node --all --timeout=300s
```

Bản 3.30 tách CRD của operator ra `operator-crds.yaml`; thiếu nó thì `Installation` báo `no matches for kind`.

## Bước 6 — Join worker 🟡

```bash
# token mới, sống 30 phút, đi thẳng từ control-plane sang worker — không hiện trên màn hình
limactl shell k8s-cp -- sudo kubeadm token create --print-join-command --ttl 30m \
  | limactl shell k8s-worker1 -- sudo bash -s
kubectl --context=$C wait --for=condition=Ready node --all --timeout=300s
kubectl --context=$C get nodes -o wide
```

## Bước 7 — Duyệt chứng chỉ kubelet 🟡

Với `serverTLSBootstrap: true`, mỗi kubelet xin chứng chỉ serving qua CSR; chưa duyệt thì `kubectl logs`/`exec`
và metrics-server lỗi `remote error: tls: internal error`. Chỉ duyệt CSR `kubelet-serving` của **đúng** node mình tạo:

```bash
kubectl --context=$C get csr -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.signerName}{"\t"}{.spec.username}{"\t"}{.status.conditions[0].type}{"\n"}{end}'
for c in $(kubectl --context=$C get csr -o jsonpath='{range .items[?(@.spec.signerName=="kubernetes.io/kubelet-serving")]}{.metadata.name}{" "}{.spec.username}{"\n"}{end}' \
           | awk '$2 ~ /^system:node:lima-k8s-(cp|worker1)$/ {print $1}'); do
  kubectl --context=$C certificate approve $c
done
kubectl --context=$C get tigerastatus          # apiserver, calico, ippools: AVAILABLE True
```

Lặp lại bước này khi thêm node và khi kubelet xoay vòng chứng chỉ (khoảng mỗi năm).

### Bước 7b — LoadBalancer: MetalLB 🟡

Cluster kubeadm không có cloud LB: thiếu nó thì Service `type: LoadBalancer` của kong ở `<pending>` mãi và
`helmfile sync` treo tới 900 s. MetalLB (L2) cấp IP trong mạng VM; kong dùng được value `dev` gốc, không cần override.

```bash
kubectl --context=$C apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.0/config/manifests/metallb-native.yaml
kubectl --context=$C -n metallb-system rollout status deploy/controller --timeout=180s
kubectl --context=$C -n metallb-system rollout status ds/speaker --timeout=180s
kubectl --context=$C apply -f - <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: lima-pool, namespace: metallb-system }
spec:
  addresses: [192.168.104.200-192.168.104.220]   # trong mạng user-v2, ngoài vùng IP của VM
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: lima-l2, namespace: metallb-system }
spec:
  ipAddressPools: [lima-pool]
EOF
```

Namespace `metallb-system` tự mang nhãn PSA `privileged` (speaker cần host network). IP này chỉ đi tới được
**từ trong các VM** — máy Mac không route được vào mạng `user-v2`; từ máy Mac dùng `kubectl port-forward`.

## Bước 8 — Nối cluster vào repo 🟢

```yaml
# environments/dev/kubernetes/cluster/target.local.yaml   (gitignored — chỉ máy bạn)
schema: kubernetes-target/v1alpha1
cluster: self-managed-dev
context: self-managed-dev
```

```bash
bash scripts/cluster/preflight.sh --cluster self-managed-dev --context self-managed-dev
```

Cluster mới, chưa có gì: preflight báo `FAIL 1` (`C ingress` — cluster này yêu cầu IngressClass, có sau khi cài
kong ở B2) và các WARN: namespace `dev` chưa có (B1), không có StorageClass, không có Prometheus CRD,
kubectl máy bạn (1.35) lệch 3 minor so với server (1.32) — các lệnh dưới vẫn chạy.

## Bước 9 — Deploy Infra Base → Platform → App lên cluster mới

Đúng thứ tự chuẩn của [`kubernetes-manual.md` Phần B](kubernetes-manual.md#phần-b--deploy-chuẩn-dựng-một-cluster):
Infra Base → Platform → Application → NetworkPolicy sau cùng. Cần age key của `dev` (chỉ cho platform).
Mỗi lệnh ghi đều có `diff` / `--dry-run=server` đứng trước — đọc nó rồi mới chạy lệnh ghi.
Đã chạy thật 2026-10-23; comment ghi kết quả thật.

```bash
export KUBECONFIG=~/.kube/config:~/.kube/self-managed-dev.yaml
```

Mọi release dùng value `dev` gốc — không có override `--set` nào.

```bash
C=self-managed-dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# B1 Infra Base
kubectl --context=$C apply --dry-run=server -f environments/dev/kubernetes/namespace/namespaces.yaml
kubectl --context=$C apply -f environments/dev/kubernetes/namespace/namespaces.yaml

# B2 Platform — metrics-server: value gốc, KHÔNG cần --kubelet-insecure-tls
T=kubernetes/releases/platform/metrics-server/helmfile.yaml.gotmpl
helmfile -e dev --kube-context $C -f $T diff
helmfile -e dev --kube-context $C -f $T sync
kubectl --context=$C top nodes

# B2 Platform — kong (cần MetalLB ở bước 7b); diff lần ĐẦU cần --disable-validation (CRD chưa có)
T=kubernetes/releases/platform/kong/helmfile.yaml.gotmpl
helmfile -e dev --kube-context $C -f $T diff --diff-args '--disable-validation'
helmfile -e dev --kube-context $C -f $T sync
kubectl --context=$C get ingressclass                                    # kong
kubectl --context=$C -n infra get svc kong-proxy                         # EXTERNAL-IP 192.168.104.200

# B4 Application (cluster + context lấy từ target.local.yaml)
helmfile -e dev -l name=devops-platform diff
helmfile -e dev -l name=devops-platform sync     # [OK] devops-platform @ dev → cluster 'self-managed-dev' context 'self-managed-dev'
helm --kube-context $C -n dev test devops-platform                       # Phase: Succeeded
helmfile -e dev -l name=test-app diff
helmfile -e dev -l name=test-app sync            # app thứ hai: worker checker + 2 CronJob
helm --kube-context $C -n dev test test-app                              # Phase: Succeeded
# frontend-html: guard chặn — [BLOCKED] … REPLACE_WITH_ placeholder (registry ECR của dev chưa điền). Đúng thiết kế.

# Đi qua Ingress thật — từ trong VM, qua IP MetalLB
limactl shell k8s-worker1 -- curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: devops-platform.dev.example.com' http://192.168.104.200/health   # 200
limactl shell k8s-worker1 -- curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: test-app.dev.example.com' http://192.168.104.200/healthz        # 200
# từ máy Mac
kubectl --context=$C -n infra port-forward svc/kong-proxy 8080:80 &
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: devops-platform.dev.example.com' localhost:8080/health   # 200

# B3 NetworkPolicy (Calico thực thi)
kubectl --context=$C apply --dry-run=server -f environments/dev/kubernetes/network/
kubectl --context=$C apply -f environments/dev/kubernetes/network/
# qua Kong vẫn 200 (allow-ingress-controllers); pod ở namespace `default` gọi thẳng Service của app bị chặn (default-deny)
```

## Bước 9b — TLS cho Ingress: cert-manager + CA local 🟡

Value `dev` của app đặt `ingress.tls` + `cert-manager.io/cluster-issuer: letsencrypt-staging`. Trên cluster local
Let's Encrypt không cấp được cho `*.dev.example.com`, nên thiếu Secret TLS → Kong bỏ TLS của Ingress, Ingress không
có ADDRESS. Cách làm dưới đây giữ nguyên value trong git, chỉ thêm thứ riêng của cluster này. Đã chạy thật 2026-10-23.

```bash
# 1. CRD của Prometheus Operator — cert-manager (và 18 tool khác) render ServiceMonitor.
#    Release riêng, đứng đầu thứ tự platform; chỉ CRD, không chạy Prometheus, không cần age key.
T=kubernetes/releases/observability/prometheus-operator-crds/helmfile.yaml.gotmpl
helmfile -e dev --kube-context $C -f $T diff
helmfile -e dev --kube-context $C -f $T sync

# 2. cert-manager — MỘT lần sync: 2 ClusterIssuer letsencrypt-* là hook post-install/post-upgrade,
#    tạo sau khi CRD + webhook sẵn sàng. (Trước 2026-10-26 chúng là resource thường và lần cài
#    đầu lỗi `no matches for kind "ClusterIssuer"`, phải sync 2 lần.)
T=kubernetes/releases/platform/cert-manager/helmfile.yaml.gotmpl
helmfile -e dev --kube-context $C -f $T diff --diff-args '--disable-validation'   # cluster mới: chưa có CRD
helmfile -e dev --kube-context $C -f $T sync

# 3. CA tự ký — chỉ cho cluster này (không nằm trong repo)
kubectl --context=$C apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: local-selfsigned }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: local-ca, namespace: infra }        # infra = namespace của cert-manager
spec:
  isCA: true
  commonName: self-managed-dev local CA
  secretName: local-ca
  duration: 87600h
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: local-selfsigned, kind: ClusterIssuer, group: cert-manager.io }
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: local-ca }
spec:
  ca: { secretName: local-ca }
EOF
kubectl --context=$C wait --for=condition=Ready clusterissuer/local-ca --timeout=60s

# 4. App dùng local-ca — override chỉ trên dòng lệnh, value trong git giữ letsencrypt-staging
O='ingress.annotations.cert-manager\.io/cluster-issuer=local-ca'
for a in devops-platform test-app; do
  helmfile -e dev -l name=$a diff --set "$O"        # chỉ đổi annotation của Ingress
  helmfile -e dev -l name=$a sync --set "$O"
done
kubectl --context=$C -n dev get certificate          # devops-platform-tls, test-app-tls: READY True
kubectl --context=$C -n dev get ingress              # ADDRESS 192.168.104.200

# 5. Kiểm tra: chứng chỉ Kong trả về do CA local ký, đúng tên miền
limactl shell k8s-worker1 -- bash -c 'echo | openssl s_client -connect 192.168.104.200:443 \
  -servername devops-platform.dev.example.com 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName'
# issuer=CN = self-managed-dev local CA · DNS:devops-platform.dev.example.com
```

⚠ Override `--set` không lưu vào git: lần `sync` app sau mà **quên** `--set "$O"` sẽ trả annotation về
`letsencrypt-staging`; Secret hiện có vẫn dùng được nhưng sẽ không gia hạn được. Muốn tin chứng chỉ trên máy bạn
thì thêm CA (`ca.crt` của Secret `infra/local-ca` — phần public) vào keychain; không xuất private key.

## Bước 10 — Kiểm tra cuối

```bash
bash scripts/cluster/preflight.sh --cluster self-managed-dev --context self-managed-dev   # FAIL 0
helm --kube-context self-managed-dev list -A               # cert-manager, devops-platform, kong, metrics-server,
                                                            # prometheus-operator-crds, test-app: deployed
kubectl --context=self-managed-dev -n dev get ingress       # ADDRESS 192.168.104.200
kubectl --context=self-managed-dev get nodes                # 2 node Ready
kubectl --context=self-managed-dev get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded   # rỗng
```

Đã biết (2026-10-23) — không chặn app, nhưng cần biết:

| Hiện tượng | Nguyên nhân | Ảnh hưởng |
|---|---|---|
| Bỏ qua bước 9b: Ingress không có ADDRESS; event `KongConfigurationTranslationFailed … Failed to fetch the secret (dev/<app>-tls)` | value `dev` của app cần Secret TLS do cert-manager cấp | HTTP qua Kong vẫn 200; HTTPS dùng chứng chỉ mặc định của Kong |
| ClusterIssuer `letsencrypt-staging` / `letsencrypt-prod` `READY False`: `invalidContact … contact email` | email ACME mặc định `platform@example.com` (`ACME_EMAIL` trong value cert-manager) bị Let's Encrypt từ chối | **mọi môi trường** cần `ACME_EMAIL` thật khi sync cert-manager, nếu không không cấp được chứng chỉ nào |
| `helmfile … kong … diff` không bao giờ sạch; mỗi `sync` tăng REVISION dù không đổi gì | chart kong tự sinh lại CA + cert cho admission webhook ở mỗi lần render (`caBundle`, Secret `kong-validation-webhook-*`) | chỉ ồn ào khi diff/history; webhook `failurePolicy: Ignore` nên không chặn gì |
| máy Mac không vào thẳng được `192.168.104.200` | mạng `user-v2` của Lima không route từ host | dùng `port-forward` |

Từ đây trở đi: đổi cấu hình, ra image mới, thêm app/tool, rollback, gỡ — làm theo
[`kubernetes-manual.md` Phần C](kubernetes-manual.md#phần-c--sau-khi-deploy) với `<ctx>` = `self-managed-dev`.

## Bước 11 — Vận hành cluster local

| Việc | Lệnh | Ghi chú |
|---|---|---|
| Dừng / bật lại | `limactl stop k8s-worker1 k8s-cp` · `limactl start k8s-cp && limactl start k8s-worker1` | bật control-plane trước. API server và etcd quảng bá IP của VM (`192.168.104.x`); **chưa kiểm chứng** IP giữ nguyên sau khi bật lại — nếu đổi, node không lên được |
| Thêm worker | bước 1 (tên mới) → 2 → 6 → 7 (thêm tên vào `awk`) | |
| Gỡ một worker ⚠ | `kubectl --context=$C drain lima-k8s-worker1 --ignore-daemonsets --delete-emptydir-data` → `kubectl --context=$C delete node lima-k8s-worker1` → `limactl delete -f k8s-worker1` | drain đuổi pod; dữ liệu emptyDir mất |
| StorageClass (cho tool có PVC: minio, postgresql, kafka…) | một provisioner, vd local-path-provisioner, đặt làm default | chưa cài trong lần chạy thật |
| Xoá cả cluster ⚠ | `limactl delete -f k8s-worker1 k8s-cp && rm ~/.kube/self-managed-dev.yaml` | không hoàn tác được; nhớ đổi `target.local.yaml` |
