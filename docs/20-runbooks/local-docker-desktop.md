# Deploy lên Docker Desktop Kubernetes — hướng dẫn chi tiết từng bước

Môi trường `dev` của repo, chạy trên Kubernetes của Docker Desktop (kind, 3 node). Thứ tự luôn là
**Infra Base → Platform → Application**. Mỗi bước dưới đây có cùng khung:

- **Mục đích** — bước này tạo ra gì, vì sao phải đứng ở vị trí đó.
- **Lệnh** — chạy từ gốc repo, theo thứ tự.
- **Kết quả đúng** — thứ bạn phải thấy trước khi sang bước sau.
- **Nếu lỗi** — nguyên nhân hay gặp và cách xử lý.

Quy tắc chung cho mọi bước:

1. Mọi lệnh đều chỉ rõ cluster: `kubectl --context=…`, `helm --kube-context …`, `helmfile --kube-context …`.
   Không dùng `kubectl config use-context` — một context ngầm sai là deploy nhầm cluster.
2. Luôn `diff` trước `sync`. `diff` không đổi gì trên cluster; `sync` thì có.
3. Không dùng `helmfile deps` (ghi `helmfile.lock` vào từng thư mục tool) — dùng `repos`.
4. Mọi override `--set` trong file này **chỉ cho máy local**, không lưu vào git. Lần `sync` sau phải truyền lại.

Lý thuyết chung (value đến từ đâu, merge thế nào, guard, prod): [`kubernetes-manual.md`](kubernetes-manual.md),
[`../03-values-mapping.md`](../03-values-mapping.md). Cluster tự dựng bằng Lima + kubeadm: [`local-cluster-kubeadm.md`](local-cluster-kubeadm.md).

## Mục lục và trạng thái kiểm chứng

| Bước | Việc | Bắt buộc? | Đã chạy thật trên Docker Desktop |
|---|---|---|---|
| [0](#bước-0--chuẩn-bị-máy) | Công cụ, bật Kubernetes, age key, chart repo | có | ✅ |
| [1](#bước-1--kiểm-tra-cluster-chỉ-đọc) | Kiểm tra cluster + preflight | có | ✅ 2026-10-22, 2026-10-27 |
| [2](#bước-2--chọn-docker-desktop-làm-target-của-dev) | Chọn Docker Desktop làm target `dev` cho app | có (cho bước 8) | ✅ 2026-10-22 |
| [3](#bước-3--infra-base-namespace--psa) | Namespace + Pod Security | có | ✅ 2026-10-27 |
| [4](#bước-4--crd-monitoring) | CRD monitoring (`prometheus-operator-crds`) | có | ✅ 2026-10-27 |
| [5](#bước-5--cert-manager--ca-local) | cert-manager + CA local | cho HTTPS | cert-manager ✅ 2026-10-27 · CA local: ✅ trên Lima, chưa trên Docker Desktop |
| [6](#bước-6--metrics-server) | metrics-server | cho HPA / `kubectl top` | ✅ 2026-10-22 |
| [7](#bước-7--kong-ingress-controller) | kong (ingress controller) | cho truy cập qua Ingress | ❌ 2026-10-22: không kéo được `kong:3.9` từ Docker Hub |
| [8](#bước-8--deploy-app) | App `devops-platform`, `test-app` | có | `devops-platform` ✅ 2026-10-22 · `test-app` + HTTPS ✅ trên Lima |
| [9](#bước-9--networkpolicy-tuỳ-chọn) | NetworkPolicy | không | không có tác dụng trên kind |
| [10](#bước-10--kiểm-tra-tổng-thể) | Kiểm tra tổng thể, rollback | có | ✅ |
| [11](#bước-11--gỡ-sạch) | Gỡ sạch | khi cần | ✅ 2026-10-27 |

Đường tối thiểu để có một app chạy: 0 → 1 → 2 → 3 → 4 → 8 (truy cập bằng port-forward).
Đường đầy đủ có Ingress + HTTPS: 0 → 10 theo thứ tự.

---

## Bước 0 — Chuẩn bị máy

**Mục đích.** Có đủ công cụ đúng phiên bản, cluster đang chạy, và giải mã được secret của platform.

**Lệnh.**

```bash
# 0.1 Công cụ — CI dùng: helm 3.20.1, helmfile 1.4.2, helm-diff 3.15.10, helm-secrets 4.7.7, sops 3.13.3, kubectl 1.34.1
helm version --short
helmfile --version
helm plugin list                  # phải có: diff, secrets
sops --version
kubectl version --client

# 0.2 Bật Kubernetes: Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply & restart.
#     Chờ biểu tượng Kubernetes trong Docker Desktop chuyển xanh (1–3 phút).

# 0.3 Age key — mọi platform helmfile nạp environments/dev/kubernetes/secrets.enc.yaml, kể cả khi chỉ `diff`.
#     Trên macOS, sops KHÔNG tự tìm ~/.config/sops/age/keys.txt (nó tìm ~/Library/Application Support/sops/age/).
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops filestatus environments/dev/kubernetes/secrets.enc.yaml

# 0.4 Biến dùng cho cả hướng dẫn
C=docker-desktop

# 0.5 Tải index của các chart repo
helmfile -e dev -f kubernetes/helmfile.yaml.gotmpl repos
```

**Kết quả đúng.**
- `helm plugin list` có `diff` và `secrets`.
- `sops filestatus` in `{"encrypted":true}`.
- `repos` kết thúc không lỗi.

**Nếu lỗi.**

| Triệu chứng | Xử lý |
|---|---|
| `helm plugin list` thiếu `diff` / `secrets` | `helm plugin install https://github.com/databus23/helm-diff --version v3.15.10`; `helm plugin install https://github.com/jkroepke/helm-secrets --version v4.7.7` |
| Về sau gặp `Failed to get the data key required to decrypt the SOPS file` | chưa `export SOPS_AGE_KEY_FILE` trong shell đang dùng, hoặc key không phải recipient của file |
| Lệnh `export`/`C=` mất khi mở terminal mới | chạy lại 0.3 và 0.4 trong mỗi terminal |

---

## Bước 1 — Kiểm tra cluster (chỉ đọc)

**Mục đích.** Chắc chắn context `docker-desktop` trỏ đúng cluster local, cluster khoẻ, và biết trên đó đang có gì
trước khi thay đổi bất cứ thứ gì.

**Lệnh.**

```bash
kubectl config view --minify --context=$C -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
kubectl --context=$C get nodes -o wide
helm --kube-context $C list -A
kubectl --context=$C get ns
bash scripts/cluster/preflight.sh --cluster docker-desktop-dev --context $C
```

**Kết quả đúng.**
- Server là `https://127.0.0.1:<port>` — loopback, tức cluster trên máy bạn. Port đổi mỗi lần bật lại Kubernetes.
- 3 node `Ready`: `desktop-control-plane`, `desktop-worker`, `desktop-worker2` (arm64 trên Apple silicon).
- Cluster mới: `helm list -A` trống; namespace chỉ có `default`, `kube-*`, `local-path-storage`.
- Preflight: `FAIL 0`. Các `WARN` bình thường trên cluster mới: namespace `dev` chưa có, không có DaemonSet CNI riêng,
  chưa có ingress controller, chưa có CRD Prometheus Operator — các bước sau sẽ lấp.

**Nếu lỗi.**

| Triệu chứng | Xử lý |
|---|---|
| `connection refused` tới `127.0.0.1:<port>` | Kubernetes của Docker Desktop đang tắt → bước 0.2. `docker ps` trống cũng là dấu hiệu này |
| `context "docker-desktop" does not exist` | Kubernetes chưa từng được bật; bật rồi chạy lại |
| Server không phải `127.0.0.1` | **dừng lại** — context đang trỏ cluster khác |

---

## Bước 2 — Chọn Docker Desktop làm target của `dev`

**Mục đích.** Platform tool nhận cluster qua `--kube-context` trên dòng lệnh. App thì **không**: lệnh
`helmfile -e dev -l name=<app>` lấy cluster và context từ file target, để không ai deploy app nhầm cluster vì context ngầm.
Thứ tự ưu tiên: biến `KUBE_CONTEXT_DEV` > `target.local.yaml` (gitignored, chỉ máy bạn) > `target.yaml` (trong git).

**Lệnh.** Sửa `environments/dev/kubernetes/cluster/target.local.yaml` thành:

```yaml
schema: kubernetes-target/v1alpha1
cluster: docker-desktop-dev     # context lấy từ cluster/docker-desktop-dev.yaml → docker-desktop
```

Rồi kiểm tra:

```bash
cat environments/dev/kubernetes/cluster/target.local.yaml
grep -E '^(context|  owner):' environments/dev/kubernetes/cluster/docker-desktop-dev.yaml   # context: docker-desktop · owner: helmfile
env | grep -E '^KUBE_CONTEXT' || echo "không có KUBE_CONTEXT* — tốt"
```

**Kết quả đúng.** `cluster: docker-desktop-dev`, không có dòng `context:` khác, không có biến `KUBE_CONTEXT` nào được set.

**Nếu lỗi.**
- Có `KUBE_CONTEXT=...` trong shell → guard từ chối ở bước 8. `unset KUBE_CONTEXT`.
- Quay lại cluster Lima: `cluster: self-managed-dev` + `context: self-managed-dev`.

---

## Bước 3 — Infra Base: namespace + PSA

**Mục đích.** Tạo namespace của platform và namespace `dev` của app, kèm nhãn Pod Security Admission. Phải làm trước
helm: `--create-namespace` của helm tạo namespace **không** có nhãn PSA, nên bỏ bước này là không namespace nào
được thực thi Pod Security.

| Namespace | PSA `enforce` | Dùng cho |
|---|---|---|
| `infra` | baseline | cert-manager, kong |
| `observability` | privileged | monitoring |
| `database` | restricted | minio, postgresql, redis, kafka, clickhouse |
| `dev` | restricted | app |
| `velero`, `trivy-system`, `falco` | privileged | backup, scan, runtime security |
| `vault`, `argocd` | baseline | |
| `harbor`, `keda` | restricted | |

**Lệnh.**

```bash
kubectl --context=$C diff  -f environments/dev/kubernetes/namespace/namespaces.yaml   # xem sẽ tạo gì
kubectl --context=$C apply -f environments/dev/kubernetes/namespace/namespaces.yaml
kubectl --context=$C get ns -L pod-security.kubernetes.io/enforce
```

**Kết quả đúng.** 11 dòng `namespace/... created` (hoặc `unchanged` nếu chạy lại); cột `ENFORCE` khớp bảng trên.

**Nếu lỗi.** `diff` trả exit code 1 khi **có** khác biệt — đó không phải lỗi. Lỗi thật in `error:`.

---

## Bước 4 — CRD monitoring

**Mục đích.** Cài 10 CRD `monitoring.coreos.com` (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Probe`, …).
cert-manager và ~18 tool khác render một `ServiceMonitor`; không có CRD thì chúng cài lỗi. Release này chỉ có CRD,
không chạy Prometheus, không đọc secret. CRD được gắn `helm.sh/resource-policy: keep`: gỡ release **không** xoá CRD
(xoá CRD là xoá mọi ServiceMonitor trong cluster).

**Lệnh.**

```bash
T=kubernetes/releases/observability/prometheus-operator-crds/helmfile.yaml.gotmpl
helmfile -e dev --kube-context $C -f $T diff        # 10 CustomResourceDefinition "has been added"
helmfile -e dev --kube-context $C -f $T sync
helm --kube-context $C -n kube-system list
kubectl --context=$C get crd | grep monitoring.coreos.com
```

**Kết quả đúng.**
- `UPDATED RELEASES: prometheus-operator-crds kube-system … 30.0.1`.
- `helm list`: `prometheus-operator-crds` `deployed`, chart `prometheus-operator-crds-30.0.1`, app `v0.92.1`.
- 10 CRD `*.monitoring.coreos.com`.

**Nếu lỗi.**

| Triệu chứng | Xử lý |
|---|---|
| `invalid ownership metadata` | CRD đã có từ một cài đặt khác (vd. kube-prometheus-stack cũ) — xem [README của release](../../kubernetes/releases/observability/prometheus-operator-crds/README.md#existing-cluster-whose-crds-came-from-kube-prometheus-stack) |
| Diff in rất dài | bình thường: nó in toàn bộ schema của 10 CRD |

---

## Bước 5 — cert-manager + CA local

**Mục đích.** cert-manager cấp chứng chỉ TLS cho Ingress. Release cài CRD của cert-manager, 3 deployment
(controller, webhook, cainjector) và 2 ClusterIssuer `letsencrypt-staging`, `letsencrypt-prod`.
Hai ClusterIssuer là **hook** `post-install,post-upgrade`: helm tạo chúng sau khi CRD đã có và webhook đã Ready, nên
**một lần `sync`** là đủ trên cluster mới. Mỗi lần sync sau, hai issuer bị xoá và tạo lại — đúng thiết kế.

Let's Encrypt **không** dùng được trên máy local (email `example.com` bị từ chối; domain `*.dev.example.com` không trỏ về
máy bạn). Vì vậy tạo thêm một CA tự ký chỉ cho cluster này.

**Lệnh — 5a. cert-manager.**

```bash
T=kubernetes/releases/platform/cert-manager/helmfile.yaml.gotmpl
# lần đầu trên cluster mới: chưa có CRD ClusterIssuer nên phải tắt validation của diff
helmfile -e dev --kube-context $C -f $T diff --diff-args '--disable-validation'
helmfile -e dev --kube-context $C -f $T sync          # ~35 s
kubectl --context=$C -n infra get pods
kubectl --context=$C get crd | grep cert-manager.io
kubectl --context=$C get clusterissuer
```

**Kết quả đúng (5a).**
- `cert-manager v1.21.0 has been deployed successfully!`, release `deployed`.
- 3 pod `cert-manager-…`, `cert-manager-cainjector-…`, `cert-manager-webhook-…`: `1/1 Running`.
- 6 CRD `*.cert-manager.io`.
- `letsencrypt-prod`, `letsencrypt-staging` tồn tại với `READY False` và
  `invalidContact … forbidden domain "example.com"` — **dự kiến**, không phải lỗi của bước này.

**Lệnh — 5b. CA local** (không nằm trong repo, chỉ cho cluster này).

```bash
kubectl --context=$C apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: local-selfsigned }        # issuer tự ký, chỉ dùng để ký CA bên dưới
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: local-ca, namespace: infra }   # CA nằm trong namespace của cert-manager
spec:
  isCA: true
  commonName: docker-desktop local CA
  secretName: local-ca
  duration: 87600h                          # 10 năm
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: local-selfsigned, kind: ClusterIssuer, group: cert-manager.io }
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: local-ca }                # issuer mà app sẽ dùng ở bước 8
spec:
  ca: { secretName: local-ca }
EOF
kubectl --context=$C -n infra get certificate local-ca
kubectl --context=$C wait --for=condition=Ready clusterissuer/local-ca --timeout=60s
```

**Kết quả đúng (5b).** Certificate `local-ca` `READY True`; `clusterissuer.cert-manager.io/local-ca condition met`.

**Nếu lỗi.**

| Triệu chứng | Xử lý |
|---|---|
| `no matches for kind "ServiceMonitor"` | chưa làm bước 4 |
| `diff` lỗi `no matches for kind "ClusterIssuer"` | thiếu `--diff-args '--disable-validation'` ở lần đầu |
| `sync` lỗi `no matches for kind "ClusterIssuer"` | code cũ (issuer chưa là hook) — cập nhật repo |
| 5b lỗi `failed calling webhook "webhook.cert-manager.io"` | webhook chưa Ready; chờ 30 s rồi chạy lại |
| `ImagePullBackOff` | image ở `quay.io`; kiểm tra mạng của Docker Desktop |

---

## Bước 6 — metrics-server

**Mục đích.** Cung cấp API `metrics.k8s.io` cho HPA và `kubectl top`. Không cần thì bỏ qua.
Chứng chỉ kubelet của kind không có IP SAN, nên với value gốc metrics-server không bao giờ Ready. Trên máy này
thêm `--kubelet-insecure-tls` **trên dòng lệnh** — không sửa value trong git (EKS dev dùng chung value).
Cờ này bỏ kiểm tra chứng chỉ kubelet: chấp nhận được trên cluster một người dùng, không dùng ở nơi khác.

**Lệnh.**

```bash
T=kubernetes/releases/platform/metrics-server/helmfile.yaml.gotmpl
LOCAL='args={--kubelet-preferred-address-types=InternalIP\,Hostname\,ExternalIP,--kubelet-insecure-tls}'
helmfile -e dev --kube-context $C -f $T diff --set "$LOCAL"
helmfile -e dev --kube-context $C -f $T sync --set "$LOCAL"
kubectl --context=$C -n kube-system rollout status deploy/metrics-server --timeout=120s
kubectl --context=$C get apiservice v1beta1.metrics.k8s.io
kubectl --context=$C top nodes
```

**Kết quả đúng.** APIService `AVAILABLE True`; `kubectl top nodes` in CPU/RAM của 3 node (có thể mất ~1 phút sau khi Ready).

**Nếu lỗi.**
- Pod không Ready, log `x509: cannot validate certificate … doesn't contain any IP SANs` → quên `--set "$LOCAL"`.
- `error: Metrics API not available` ngay sau khi cài → chờ 60 s.

---

## Bước 7 — kong (ingress controller)

**Mục đích.** Kong là ingress controller của mọi môi trường (IngressClass `kong`, namespace `infra`). Không có kong thì
Ingress của app không có đường vào — app vẫn chạy, chỉ truy cập bằng port-forward.
Value `dev` đặt Service `kong-proxy` là `type: LoadBalancer`, cổng 80 + 443.

**Lệnh.**

```bash
# 7.1 Kiểm tra mạng trước — lần chạy 2026-10-22 hỏng ở đây (engine Docker không ra được Docker Hub)
docker pull kong:3.9

# 7.2 Cài
T=kubernetes/releases/platform/kong/helmfile.yaml.gotmpl
helmfile -e dev --kube-context $C -f $T diff --diff-args '--disable-validation'   # lần đầu: chưa có CRD KongClusterPlugin
helmfile -e dev --kube-context $C -f $T sync
kubectl --context=$C -n infra get pods -l app.kubernetes.io/instance=kong
kubectl --context=$C get ingressclass
kubectl --context=$C -n infra get svc kong-proxy
```

**Kết quả đúng.**
- Pod kong `Running`; IngressClass `kong`.
- `kong-proxy` có `EXTERNAL-IP`. Docker Desktop (kind) có `kind-cloud-provider` để cấp địa chỉ LoadBalancer —
  **chưa kiểm chứng** trong repo này. Địa chỉ đó có thể không truy cập được từ macOS; dùng port-forward ở bước 10.

**Nếu lỗi.**

| Triệu chứng | Xử lý |
|---|---|
| `docker pull` timeout / `ImagePullBackOff` | engine Docker không ra được Docker Hub: kiểm tra VPN, proxy trong Docker Desktop → Settings → Resources → Proxies |
| `kong-proxy` `<pending>`, `sync` treo tới 900 s | không có địa chỉ LB. Chạy lại `sync --set proxy.type=ClusterIP` (chỉ local) và vào bằng port-forward |
| Mỗi lần `diff` đều có thay đổi ở webhook | chart sinh lại CA của webhook mỗi lần render — bình thường, không cần xử lý |

---

## Bước 8 — Deploy app

**Mục đích.** Cài app bằng chart `kubernetes/charts/application`, value gộp từ 3 lớp: value mặc định của chart →
`environments/dev/kubernetes/app-values.yaml.gotmpl` → `applications/<app>/k8s/dev/values.yaml`. Release nằm ở
namespace `dev`, cluster lấy từ bước 2.

Trước mỗi `sync`, `scripts/deploy/release-guard.sh` chạy và **từ chối** nếu:
- không có `-l name=<app>` (không cho sync hàng loạt app);
- owner của cluster không phải `helmfile`, hoặc đã có Argo CD Application `<app>-dev` (Argo đang quản lý app đó);
- không xác định được context, context không có trong kubeconfig, hoặc có `KUBE_CONTEXT` khác;
- value còn chuỗi `REPLACE_WITH_` (vd. `frontend-html`: registry ECR chưa điền — bị chặn là đúng).

`devops-platform` và `test-app` dùng image `docker.io`, chạy được trên máy local.

**Lệnh.**

```bash
# Chỉ khi đã làm bước 5b: đổi issuer của Ingress sang CA local. Không có 5b thì bỏ --set "$O" ở mọi lệnh dưới.
O='ingress.annotations.cert-manager\.io/cluster-issuer=local-ca'

helmfile -e dev -l name=devops-platform diff --set "$O"
helmfile -e dev -l name=devops-platform sync --set "$O"
helmfile -e dev -l name=test-app diff --set "$O"
helmfile -e dev -l name=test-app sync --set "$O"

kubectl --context=$C -n dev rollout status deploy/devops-platform-application --timeout=120s
kubectl --context=$C -n dev rollout status deploy/test-app-application --timeout=120s
kubectl --context=$C -n dev get pods,svc,ingress
kubectl --context=$C -n dev get certificate
helm --kube-context $C -n dev test devops-platform
```

**Kết quả đúng.**
- Dòng đầu của mỗi `sync`: `[OK] <app> @ dev → cluster 'docker-desktop-dev' context 'docker-desktop'`.
  Thấy cluster/context khác → **Ctrl-C ngay**.
- Rollout `successfully rolled out`; pod `Running`, không restart.
- Có kong + 5b: certificate `devops-platform-tls`, `test-app-tls` `READY True`; Ingress có `ADDRESS`.
  Không có kong: Ingress không có `ADDRESS` — bình thường.
- `helm test`: `Phase: Succeeded`.

**Nếu lỗi.**

| Triệu chứng | Xử lý |
|---|---|
| `[BLOCKED] … no selector` / `every selector must name the app` | thiếu hoặc sai `-l name=<app>` |
| `[BLOCKED] … kube context … is not in kubeconfig` | bước 2 sai, hoặc Kubernetes của Docker Desktop đang tắt |
| `[BLOCKED] … KUBE_CONTEXT=… is set` | `unset KUBE_CONTEXT` |
| `[BLOCKED] … REPLACE_WITH_ placeholder` | app chưa có registry thật (vd. `frontend-html`) — chọn app khác |
| `[BLOCKED] … could not check for an Argo CD Application` | không đọc được API của cluster — kiểm tra bước 1 |
| Pod bị từ chối vì Pod Security | namespace `dev` là `restricted`; chart mặc định đã đạt — kiểm tra value app có bật thứ gì cần quyền cao |
| Certificate `READY False` | thiếu bước 5b, hoặc quên `--set "$O"` (issuer vẫn là `letsencrypt-staging`) |

Lần `sync` app sau mà quên `--set "$O"`: annotation trở về `letsencrypt-staging`; chứng chỉ hiện có vẫn dùng được
nhưng sẽ không gia hạn.

---

## Bước 9 — NetworkPolicy (tuỳ chọn)

**Mục đích.** Áp default-deny cho các namespace và các luật cho phép (ingress controller → app, DNS, …).

```bash
kubectl --context=$C apply --dry-run=server -f environments/dev/kubernetes/network/
kubectl --context=$C apply -f environments/dev/kubernetes/network/
kubectl --context=$C get networkpolicy -A
```

CNI mặc định của kind **không thực thi** NetworkPolicy: object được tạo nhưng không chặn gì. Muốn kiểm chứng
NetworkPolicy thật, dùng cluster Lima + Calico ([`local-cluster-kubeadm.md`](local-cluster-kubeadm.md)).

---

## Bước 10 — Kiểm tra tổng thể

**Lệnh — trạng thái.**

```bash
helm --kube-context $C list -A                                    # mọi release: deployed
kubectl --context=$C get pods -A | grep -vE 'Running|Completed'    # chỉ còn dòng tiêu đề
kubectl --context=$C get events -A --field-selector type=Warning | tail -20
bash scripts/cluster/preflight.sh --cluster docker-desktop-dev --context $C   # FAIL 0, ít WARN hơn bước 1
```

**Lệnh — gọi app qua kong** (khi bước 7 chạy được):

```bash
kubectl --context=$C -n infra port-forward svc/kong-proxy 8443:443 >/dev/null &
sleep 2
curl -sk -o /dev/null -w '%{http_code}\n' --resolve devops-platform.dev.example.com:8443:127.0.0.1 \
  https://devops-platform.dev.example.com:8443/health          # 200
curl -sk -o /dev/null -w '%{http_code}\n' --resolve test-app.dev.example.com:8443:127.0.0.1 \
  https://test-app.dev.example.com:8443/healthz                # 200
kill %1
```

**Lệnh — gọi app thẳng vào Service** (không có kong):

```bash
kubectl --context=$C -n dev port-forward svc/devops-platform-application 8080:80 >/dev/null &
sleep 2
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/health   # 200
kill %1
```

`-k` vì CA local không nằm trong keychain của máy. Muốn trình duyệt tin chứng chỉ, thêm **phần public** của CA
(`ca.crt` trong Secret `infra/local-ca`) vào keychain; không xuất private key.

**Rollback một release.**

```bash
helm --kube-context $C -n <namespace> history <release>
helm --kube-context $C -n <namespace> rollback <release> <revision> --wait
```

`helmDefaults` đặt `atomic: false`: release lỗi được giữ nguyên để điều tra, không có gì tự rollback.

---

## Bước 11 — Gỡ sạch

**Mục đích.** Trả cluster về trạng thái vừa bật Kubernetes. Chỉ làm trên cluster local. Thứ tự ngược với lúc cài:
app → platform → CRD → namespace. Release nào chưa cài thì `helm uninstall` báo `not found` — bỏ qua.

```bash
# 11.1 App
helm --kube-context $C -n dev uninstall test-app --wait
helm --kube-context $C -n dev uninstall devops-platform --wait

# 11.2 Platform
helm --kube-context $C -n infra uninstall kong --wait
helm --kube-context $C -n kube-system uninstall metrics-server --wait
kubectl --context=$C delete clusterissuer local-ca local-selfsigned letsencrypt-prod letsencrypt-staging --ignore-not-found
helm --kube-context $C -n infra uninstall cert-manager --wait                     # in "kept due to the resource policy": 6 CRD
helm --kube-context $C -n kube-system uninstall prometheus-operator-crds --wait   # in "kept due to the resource policy": 10 CRD

# 11.3 CRD còn lại — kiểm tra không còn object nào dùng chúng, rồi xoá
kubectl --context=$C get servicemonitors.monitoring.coreos.com,certificates.cert-manager.io,issuers.cert-manager.io -A
kubectl --context=$C get crd -o name | grep -E 'monitoring.coreos.com|cert-manager.io|konghq.com' \
  | xargs kubectl --context=$C delete

# 11.4 Namespace — xoá luôn mọi Secret, PVC bên trong
kubectl --context=$C delete -f environments/dev/kubernetes/namespace/namespaces.yaml --wait=true --timeout=180s

# 11.5 Xác nhận
helm --kube-context $C list -A          # trống
kubectl --context=$C get ns             # default, kube-node-lease, kube-public, kube-system, local-path-storage
kubectl --context=$C get crd            # No resources found
```

Cách nhanh hơn, xoá **toàn bộ** cluster: Docker Desktop → Settings → Kubernetes → Reset Kubernetes Cluster.
Sau đó bắt đầu lại từ bước 1 (port của server sẽ đổi).

---

## Tóm tắt lỗi theo triệu chứng

| Triệu chứng | Bước |
|---|---|
| `connection refused` tới `127.0.0.1:<port>` | [1](#bước-1--kiểm-tra-cluster-chỉ-đọc) |
| `Failed to get the data key required to decrypt the SOPS file` | [0](#bước-0--chuẩn-bị-máy) |
| `no matches for kind "ServiceMonitor"` | [4](#bước-4--crd-monitoring) |
| `diff` lần đầu lỗi `no matches for kind …` | thêm `--diff-args '--disable-validation'` |
| `[BLOCKED] …` từ release guard | [8](#bước-8--deploy-app) |
| metrics-server không Ready, `x509 … IP SANs` | [6](#bước-6--metrics-server) |
| `ImagePullBackOff` tới `registry-1.docker.io` | [7](#bước-7--kong-ingress-controller) |
| `kong-proxy` `<pending>`, sync treo | [7](#bước-7--kong-ingress-controller) |
| Ingress không có ADDRESS / certificate không Ready | [5](#bước-5--cert-manager--ca-local), [7](#bước-7--kong-ingress-controller), [8](#bước-8--deploy-app) |
