# Guide deploy Kubernetes — từng bước, rồi làm gì tiếp

Một file cho cả vòng đời trên một cluster đã có: chuẩn bị → dựng một cluster theo thứ tự chuẩn (Infra Base → Platform →
Application) → kiểm tra → vận hành sau đó (đổi cấu hình, thêm app/tool, rollback, gỡ, lên môi trường cao hơn).

Mọi lệnh là `kubectl`, `helm`, `helmfile` gõ trực tiếp từ **gốc repo** — không `make`, không wrapper.
Value đến từ đâu và ghép thế nào: [`../03-values-mapping.md`](../03-values-mapping.md).

| Ký hiệu | Nghĩa |
|---|---|
| 🟢 | chỉ đọc / offline — chạy thoải mái |
| 🟡 | ghi lên cluster local/dev — xác nhận đúng context trước |
| 🔴 | staging/prod — không chạy từ máy cá nhân; qua pipeline + người duyệt |

Trong lệnh: `<env>` = `dev` \| `staging` \| `prod`; `<ctx>` = kube context của cluster đích
(vd `docker-desktop`). Ví dụ dùng `dev`.

**Mục lục**

- [Tổng quan: ba lớp](#tổng-quan-ba-lớp)
- Chưa có cluster: tạo cluster local + join node — file riêng [`local-cluster-kubeadm.md`](local-cluster-kubeadm.md)
- Docker Desktop, từng lệnh từ đầu tới gỡ sạch: [`local-docker-desktop.md`](local-docker-desktop.md)
- Phần A — Chuẩn bị (một lần): [A1 công cụ](#a1-công-cụ) · [A2 chọn cluster đích](#a2-chọn-cluster-đích) · [A3 key và biến](#a3-key-và-biến-môi-trường)
- Phần B — Deploy chuẩn: [B1 Infra Base](#b1-infra-base-namespace--psa) · [B2 Platform](#b2-platform) · [B3 Manifest ngoài Helm + NetworkPolicy](#b3-manifest-ngoài-helm-và-networkpolicy) · [B4 Application](#b4-application) · [B5 Kiểm tra toàn cục](#b5-kiểm-tra-toàn-cục)
- Phần C — Sau khi deploy: [C1 đổi cấu hình app](#c1-đổi-cấu-hình-một-app) · [C2 đổi image](#c2-ra-phiên-bản-image-mới) · [C3 thêm app](#c3-thêm-một-app-mới) · [C4 đổi/thêm tool platform](#c4-đổi-value-hoặc-nâng-version-một-tool-platform) · [C5 rollback](#c5-rollback) · [C6 gỡ](#c6-gỡ) · [C7 lên EKS, staging, prod](#c7-từ-local-lên-eks-dev--staging--prod) · [C8 lỗi thường gặp](#c8-lỗi-thường-gặp)
- Phụ lục: [P1 trạng thái hiện tại](#p1-trạng-thái-hiện-tại) · [P2 điều kiện từng tool](#p2-deploy-riêng-một-tool--cần-gì-trước) · [P3 Docker Desktop đã chạy thật](#p3-chuỗi-lệnh-đã-chạy-thật-trên-docker-desktop) · Lima + kubeadm đã chạy thật: [`local-cluster-kubeadm.md` bước 9](local-cluster-kubeadm.md#bước-9--deploy-infra-base--platform--app-lên-cluster-mới)

---

## Tổng quan: ba lớp

```text
Terraform core (chỉ EKS: VPC, EKS, IRSA, ECR)   terraform/stacks — qua CI, không chạy tay ở đây
        ▼
1. INFRA BASE   kubectl   environments/<env>/kubernetes/namespace/namespaces.yaml   Namespace + nhãn PSA
                          environments/<env>/kubernetes/network/*.yaml               NetworkPolicy (áp SAU platform)
        ▼
2. PLATFORM     helmfile  kubernetes/releases/{platform,observability}/<tool>/helmfile.yaml.gotmpl
                          value: environments/<env>/kubernetes/{tools,ingress,monitoring}/<tool>/
                          thứ tự: helmfiles: trong kubernetes/helmfile.yaml.gotmpl
        ▼
3. APPLICATION  helmfile  helmfile.yaml.gotmpl (gốc) → applications/helmfile.yaml.gotmpl
                          chart kubernetes/charts/application · value applications/<app>/k8s/<env>/values.yaml
```

| Lớp | Context lấy từ | Bảo vệ |
|---|---|---|
| Infra Base | `--context=<ctx>` trên dòng lệnh | không có — tự kiểm tra |
| Platform | `--kube-context <ctx>` trên dòng lệnh — **không** ghim trong helmfile; quên thì helm dùng current-context | CI gate cho staging/prod |
| Application | `environments/<env>/kubernetes/cluster/target(.local).yaml` | `scripts/deploy/release-guard.sh` |

App chỉ **dùng** những gì base có (namespace, ingress controller, NetworkPolicy, monitoring) — không tự tạo lại.

---

**Chưa có cluster?** Tạo một cluster local thật (Lima + kubeadm, 1 control-plane + 1 worker join vào,
Calico) theo file riêng [`local-cluster-kubeadm.md`](local-cluster-kubeadm.md), rồi quay lại Phần A.

---

# Phần A — Chuẩn bị (một lần mỗi máy)

## A1. Công cụ

```bash
kubectl version --client
helm version --short
helm plugin list            # cần: diff, secrets
helmfile --version
yq --version                # mikefarah v4
sops --version
```

CI dùng (`ci/images/Dockerfile`): helm 3.20.1, helmfile 1.4.2, helm-diff 3.15.10, helm-secrets 4.7.7,
sops 3.13.3, kubectl 1.34.1. kubectl lệch tối đa một minor so với cluster.

## A2. Chọn cluster đích

```bash
kubectl config get-contexts -o name
kubectl --context=<ctx> cluster-info
kubectl config view --minify --context=<ctx> -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

- Local = tên `docker-desktop` / `minikube` / `kind-*` **và** URL `127.0.0.1`. Tên chứa `staging`, `prod`,
  `production` → 🔴, dừng.
- Không `kubectl config use-context`; mọi lệnh ghi đều tự mang context.
- Cho **app**: trỏ môi trường `dev` về cluster của bạn trong file gitignored
  `environments/dev/kubernetes/cluster/target.local.yaml`:

  ```yaml
  schema: kubernetes-target/v1alpha1
  cluster: docker-desktop-dev       # tên file trong environments/dev/kubernetes/cluster/
  # context: my-alias               # tuỳ chọn, ghi đè context của file cluster
  ```

- Kiểm tra cluster, chỉ đọc 🟢: `bash scripts/cluster/preflight.sh --cluster docker-desktop-dev` → cần `FAIL 0`.

Docker Desktop: bật Settings → Kubernetes trước. Chi tiết provider: [`../clusters/README.md`](../clusters/README.md).

## A3. Key và biến môi trường

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt   # key age của ĐÚNG môi trường — không in, không commit
export AWS_ACCOUNT_ID=<account-id>                       # tool cần requiredEnv (P2); local chỉ cần giá trị bất kỳ khi đã override image
helmfile -e dev -f kubernetes/helmfile.yaml.gotmpl repos # thêm repo chart (cần mạng)
```

- Mọi helmfile platform nạp `environments/<env>/kubernetes/secrets.enc.yaml` → thiếu key thì cả `template` cũng lỗi.
  App **không** cần key.
- Không chạy `helmfile deps` ở máy cá nhân: nó ghi `helmfile.lock` vào folder tool (repo không giữ file này).

---

# Phần B — Deploy chuẩn (dựng một cluster)

Mỗi bước có cùng nhịp: **render (🟢) → diff (🟢) → apply/sync (🟡) → verify (🟢)**. Không bỏ diff.

## B1. Infra Base: namespace + PSA

**Làm gì:** tạo 11 namespace (`infra`, `observability`, `database`, `vault`, `velero`, `harbor`, `falco`,
`keda`, `trivy-system`, `argocd`, `<env>`) với nhãn `pod-security.kubernetes.io/*`.
Repo **chưa có** RBAC, ResourceQuota, LimitRange cho namespace.

```bash
F=environments/dev/kubernetes/namespace/namespaces.yaml
yq -N '.kind + " " + .metadata.name' $F                          # 🟢 offline: object sẽ tạo
kubectl --context=<ctx> apply --dry-run=server -f $F             # 🟢 qua API server + admission, không lưu
kubectl --context=<ctx> diff -f $F                               # 🟢 exit 1 = có khác biệt (không phải lỗi)
kubectl --context=<ctx> apply -f $F                              # 🟡
kubectl --context=<ctx> get ns -L pod-security.kubernetes.io/enforce   # 🟢 verify
```

`--dry-run=client` chỉ kiểm tra phía client, không đảm bảo API server/PSA chấp nhận — dùng `=server`.
Chi tiết: [`kubernetes/docs/NAMESPACES.md`](../../kubernetes/docs/NAMESPACES.md).

## B2. Platform

### Thứ tự chuẩn (nguồn: `helmfiles:` trong `kubernetes/helmfile.yaml.gotmpl`)

| # | Nhóm | Tool, theo thứ tự | Vì sao |
|---|---|---|---|
| 1 | Cluster base | **prometheus-operator-crds**, kube-prometheus-stack, metrics-server, karpenter\*, cluster-autoscaler\*, reloader, keda | prometheus-operator-crds mang CRD `ServiceMonitor` mà 19 tool sau cần (kube-prometheus-stack chạy `crds.enabled: false`) |
| 2 | Networking | cert-manager, ingress-nginx\*, kong, external-dns | kong trước mọi tool có Ingress (class `kong`) |
| 3 | Data | minio, postgresql, redis, kafka, clickhouse | minio là object store của mimir/harbor |
| 4 | Observability | loki, tempo, mimir, opensearch, opensearch-dashboards, opentelemetry-collector, alloy, grafana | backend trước client |
| 5 | Security | vault, external-secrets, sealed-secrets, kyverno, trivy-operator, falco | cần ingress + TLS |
| 6 | Delivery | argocd, velero, harbor | harbor cần postgresql, redis, minio, kong |

\* bật/tắt trong `environments/<env>/kubernetes/state.yaml` (`nodeAutoscaler`, `ingressNginx`). Release bị
tắt có `installed: false` → `sync` **gỡ** nó nếu đang cài.

Không cần cài hết: chọn tool cần dùng, nhưng giữ thứ tự và điều kiện ở [P2](#p2-deploy-riêng-một-tool--cần-gì-trước).

### Cài một tool (lặp cho từng tool theo bảng)

```bash
T=kubernetes/releases/<group>/<tool>/helmfile.yaml.gotmpl       # group: platform | observability

helmfile -e dev -f $T template > /dev/null && echo render OK     # 🟢
helmfile -e dev --kube-context <ctx> -f $T diff                  # 🟢
helmfile -e dev --kube-context <ctx> -f $T sync                  # 🟡 chờ tới Ready (wait: true, tối đa 900 s)
helm --kube-context <ctx> -n <ns> status <tool>                  # 🟢 STATUS: deployed
kubectl --context=<ctx> -n <ns> get pods                         # 🟢 Running + Ready
```

`atomic: false` (`kubernetes/repositories.yaml`): sync lỗi **không** tự rollback — xem [C8](#c8-lỗi-thường-gặp).

**Ví dụ: metrics-server** (ns `kube-system`, không phụ thuộc tool nào):

```bash
T=kubernetes/releases/platform/metrics-server/helmfile.yaml.gotmpl
helmfile -e dev --kube-context <ctx> -f $T diff
helmfile -e dev --kube-context <ctx> -f $T sync
kubectl --context=<ctx> get apiservice v1beta1.metrics.k8s.io    # AVAILABLE True
kubectl --context=<ctx> top nodes
```

Cluster kubeadm của [`local-cluster-kubeadm.md`](local-cluster-kubeadm.md) (`serverTLSBootstrap: true` + CSR đã duyệt) chạy được với value gốc, kiểm TLS đầy đủ.
Docker Desktop cần thêm cờ chỉ cho local — xem [C8](#c8-lỗi-thường-gặp) (x509).

**Cả lớp một lần** (chỉ khi đã quen từng tool):

```bash
P="helmfile -e dev --kube-context <ctx> -f kubernetes/helmfile.yaml.gotmpl"
$P -l layer=platform diff
$P -l layer=platform sync          # 🟡 mọi tool, đúng thứ tự helmfiles:
```

`helmfile` ở gốc repo **không** có `-f kubernetes/helmfile.yaml.gotmpl` chỉ thấy app — `-l layer=platform` ở đó không khớp gì.

## B3. Manifest ngoài Helm và NetworkPolicy

Sau khi tool tương ứng chạy; mỗi file `diff` trước `apply`:

```bash
kubectl --context=<ctx> diff  -f kubernetes/releases/platform/kyverno/manifests/policies.yaml       # sau kyverno
kubectl --context=<ctx> apply -f kubernetes/releases/platform/kyverno/manifests/policies.yaml
kubectl --context=<ctx> apply -f kubernetes/releases/platform/kyverno/manifests/policies-supplychain.yaml
kubectl --context=<ctx> apply -f kubernetes/releases/platform/vault/manifests/certificate.yaml      # staging/prod

# NetworkPolicy — SAU CÙNG (default-deny áp sớm sẽ chặn chính các tool đang cài)
kubectl --context=<ctx> diff  -f environments/dev/kubernetes/network/
kubectl --context=<ctx> apply -f environments/dev/kubernetes/network/
kubectl --context=<ctx> get networkpolicy -A
```

CNI của Docker Desktop không thực thi NetworkPolicy (object có, không tác dụng). Gateway API (không app nào dùng):
[`gateway-api/README.md`](../../kubernetes/releases/platform/gateway-api/README.md).
Chi tiết: [`kubernetes/docs/NETWORK-POLICIES.md`](../../kubernetes/docs/NETWORK-POLICIES.md).

## B4. Application

Ví dụ: `devops-platform`. Điều kiện: namespace `<env>` có (B1); `delivery.owner: helmfile` trong file cluster
của target; app dùng Ingress cần kong (không có thì dùng `port-forward`); app dùng HPA cần metrics-server.

```bash
helm lint kubernetes/charts/application \
  -f environments/dev/kubernetes/app-values.yaml.gotmpl \
  -f applications/devops-platform/k8s/dev/values.yaml           # 🟢 chart + value đúng thứ tự lớp
helmfile -e dev -l name=devops-platform template --skip-deps     # 🟢 manifest cuối
helmfile -e dev -l name=devops-platform diff                     # 🟢
helmfile -e dev -l name=devops-platform sync                     # 🟡 guard chạy trước
```

Guard in `[OK] <app> @ <env> → cluster '…' context '…'` hoặc `[BLOCKED] …` kèm cách sửa ([C8](#c8-lỗi-thường-gặp)).
Nó chặn khi: thiếu `-l name=<app>`; owner ≠ `helmfile`; context trống/placeholder/không có trong kubeconfig;
`KUBE_CONTEXT` export khác context đã chọn; còn `REPLACE_WITH_`; có Argo CD Application `<app>-<env>`;
`prod` thiếu `CONFIRM_DEPLOY=<app>@prod`.

Verify:

```bash
kubectl --context=<ctx> -n dev rollout status deploy/devops-platform-application --timeout=120s
kubectl --context=<ctx> -n dev get pods,svc,ingress -l app.kubernetes.io/instance=devops-platform
kubectl --context=<ctx> -n dev port-forward svc/devops-platform-application 8080:80   # curl localhost:8080/health → 200
helm --kube-context <ctx> -n dev test devops-platform                                  # Phase: Succeeded
```

Tên object là `<app>-application`. Exit code 0 của `sync` chưa phải bằng chứng — xem rollout và pod Ready.

## B5. Kiểm tra toàn cục

```bash
helm --kube-context <ctx> list -A                                                 # mọi release deployed, không failed
kubectl --context=<ctx> get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded   # rỗng là tốt
kubectl --context=<ctx> get events -A --sort-by=.metadata.creationTimestamp | tail -30
kubectl --context=<ctx> get ingressclass
```

---

# Phần C — Sau khi deploy

Quy tắc chung: **sửa git trước, cluster sau**. Mọi thay đổi đi qua `template → diff → sync → verify`;
không `kubectl edit` / `helm upgrade` tay (lần sync sau sẽ ghi đè).

## C1. Đổi cấu hình một app

Sửa `applications/<app>/k8s/<env>/values.yaml` (chỉ file của môi trường đó; đổi cho mọi môi trường = sửa cả 3):

| Muốn | Key |
|---|---|
| Tài nguyên | `resources.requests` / `resources.limits` |
| Ingress bật/tắt, host | `ingress.enabled`, `ingress.hosts`, `ingress.tls` (class `kong` có sẵn từ lớp môi trường) |
| Replica / HPA | `replicaCount`, `autoscaling.enabled` |
| Service | `service.port` (80), `service.targetPort` (8080) |
| Biến môi trường, file cấu hình | `env`, `extraConfigMaps` + `extraVolumes`/`extraVolumeMounts` |

Mọi key: [`../reference/application-chart.md`](../reference/application-chart.md). List (vd `extraVolumes`) bị
thay **cả list** — giữ volume `tmp`. Rồi: `template` → `diff` → `sync` (B4).

## C2. Ra phiên bản image mới

1. Image đã có trong registry mà value trỏ tới (môi trường AWS: copy theo digest vào ECR của môi trường,
   `crane copy <src>@sha256:<digest> <ecr>/<repo>:<tag>` — không build lại).
2. Sửa `image.tag` và `image.digest` trong `applications/<app>/k8s/<env>/values.yaml`, commit.
3. `diff` (chỉ thấy đổi image) → `sync` → verify rollout.

## C3. Thêm một app mới

```bash
make new-app APP=<tên> RUNTIME=eks      # chỉ tạo khung từ applications/_template (không deploy)
```

Điền `REPLACE_WITH_*` trong `applications/<tên>/k8s/{dev,staging,prod}/values.yaml` → `helm lint` + `template`
(B4) → `diff` → `sync`. Không copy app khác. Hướng dẫn đầy đủ: [`../10-onboard-app.md`](../10-onboard-app.md).

## C4. Đổi value hoặc nâng version một tool platform

- **Value:** sửa `environments/<env>/kubernetes/{tools,ingress,monitoring}/<tool>/…` của đúng môi trường.
- **Version chart:** sửa `version:` trong `kubernetes/releases/<group>/<tool>/helmfile.yaml.gotmpl` — ảnh hưởng
  **mọi** môi trường ở lần sync sau; đọc release note của chart (CRD, key đổi tên).
- **Bật/tắt** tool có cờ: `state.yaml` (`nodeAutoscaler`, `ingressNginx`).
- Rồi B2 cho đúng tool đó: `template` → `diff` (đọc kỹ) → `sync` → verify.

Thêm tool mới hoàn toàn: tạo `kubernetes/releases/<group>/<tool>/helmfile.yaml.gotmpl` (copy cấu trúc một tool
có sẵn: `bases`, `environments`, nhãn `name/layer/tier/component/env`), value ở `environments/<env>/…/<tool>/`
cho cả 3 môi trường, thêm vào `helmfiles:` đúng vị trí theo phụ thuộc.

## C5. Rollback

**Ưu tiên:** `git revert` commit gây lỗi → `diff` → `sync`. Git và cluster khớp nhau, đi qua guard.

**Khẩn cấp** 🟡:

```bash
helm --kube-context <ctx> -n <ns> history <release>            # chọn revision tốt
helm --kube-context <ctx> -n <ns> rollback <release> <rev>
```

`helm rollback` **không** qua release guard: tự xác nhận context, và release không do Argo CD quản lý.
Sau đó revert git — nếu không, sync kế tiếp đưa bản lỗi trở lại.

## C6. Gỡ

```bash
helmfile -e dev -l name=<app> destroy                                                   # app (guard chạy)
helmfile -e dev --kube-context <ctx> -f kubernetes/releases/<group>/<tool>/helmfile.yaml.gotmpl destroy   # tool
```

- Xác nhận đúng release, namespace, context trước khi chạy.
- Gỡ tool: kiểm tra ai phụ thuộc nó (P2) — gỡ kong làm mọi Ingress mất đường vào; gỡ minio làm mimir/harbor mất nơi ghi.
  CRD không bị xoá; PVC có thể còn; tool data có nguy cơ mất dữ liệu.
- Không `helm uninstall` app (bỏ qua guard), không `-l layer=platform destroy`,
  **không bao giờ** xoá namespace dùng chung để gỡ một thứ.

## C7. Từ local lên EKS dev → staging → prod

| # | Việc | Ở đâu |
|---|---|---|
| 1 | Điền `account.id`, `bucket` → pipeline `plan:core` → `apply:core` → `registry` | `environments/<env>/terraform/`, [platform.md §1](platform.md#1-terraform--base-aws-terraform-value-ở-environmentsenvterraform) |
| 2 | Thay `REPLACE_WITH_<ENV>_AWS_ACCOUNT_ID` của `global.imageRegistry` | `environments/<env>/kubernetes/app-values.yaml.gotmpl` |
| 3 | `aws eks update-kubeconfig --name platform-<env>-eks --alias <alias>`; đặt `context: <alias>` (alias, không bao giờ ARN) | `target.local.yaml` hoặc `eks-<env>.yaml` |
| 4 | Mirror image Bitnami vào ECR (job `images:mirror`) | `ci/k8s/main.yml` |
| 5 | B1 → B3 với context EKS; kong trước app | dev: tay; staging/prod: job `helmfile:sync:<env>` |
| 6 | B4 cho từng app | staging/prod: người duyệt; prod thêm `CONFIRM_DEPLOY=<app>@prod` |
| 7 | Staging/prod trước tiên: tách key SOPS | [platform.md §2.1.1](platform.md#211-tách-key-sops-theo-môi-trường-một-lần-) |

Đường CI deploy app (`deploy:setup`/`deploy:apply`) hiện **không dùng được**: nó tìm release `layer=app` trong
`kubernetes/` (không còn), mọi cluster có `ciDeployAllowed: false`, và value app ghim `image.tag` (CI truyền
`IMAGE_TAG` nhưng không value nào đọc). Bật lại là quyết định chính sách — ai deploy app (người, CI hay Argo CD),
tag đi vào git hay vào biến — rồi mới sửa `ci/k8s/main.yml`.

## C8. Lỗi thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `[BLOCKED] … no selector` / `every selector must name the app` | `sync` thiếu `-l name=<app>` | thêm `-l name=<app>` |
| `[BLOCKED] … kube context '…' is not in kubeconfig` / `<placeholder>` | target trỏ cluster chưa có context | sửa `target.local.yaml` (A2) |
| `[BLOCKED] … REPLACE_WITH_ placeholder` | `global.imageRegistry` của môi trường chưa điền | điền account (C7 #2), hoặc app tự đặt `image.registry` |
| `no matches for kind "ServiceMonitor"` | chưa có CRD monitoring | sync `prometheus-operator-crds` trước (P2) |
| metrics-server không Ready, log `x509 … doesn't contain any IP SANs` | Docker Desktop (kind): chứng chỉ kubelet không có IP SAN | **chỉ local**: `--set 'args={--kubelet-preferred-address-types=InternalIP\,Hostname\,ExternalIP,--kubelet-insecure-tls}'` ([docker-desktop guide](../clusters/providers/docker-desktop/README.md#4-deploy-an-app)); kubeadm/K3s: sửa chứng chỉ kubelet; EKS không cần |
| `kubectl logs`/`exec`, metrics-server lỗi `remote error: tls: internal error` | kubeadm + `serverTLSBootstrap`: CSR kubelet-serving chưa duyệt | [`local-cluster-kubeadm.md` bước 7](local-cluster-kubeadm.md#bước-7--duyệt-chứng-chỉ-kubelet-) |
| preflight `version skew … 3 minors apart` | kubectl trên máy bạn mới hơn server | lệnh đọc/apply thông thường vẫn chạy; muốn đúng mức hỗ trợ thì dùng kubectl cùng minor với cluster |
| cert-manager cài lần đầu lỗi `no matches for kind "ClusterIssuer"` | value cũ: ClusterIssuer là resource thường của release | value hiện tại đã sửa — ClusterIssuer là hook `post-install,post-upgrade`, một `sync` là đủ; kéo code mới rồi sync lại |
| ClusterIssuer `letsencrypt-*` `READY False`, `invalidContact … contact email` | `ACME_EMAIL` không đặt → mặc định `platform@example.com`, Let's Encrypt từ chối | `export ACME_EMAIL=<email thật>` rồi sync lại cert-manager |
| `diff` lần đầu lỗi `no matches for kind "KongClusterPlugin"` | CRD của chart chưa cài | `diff --diff-args '--disable-validation'` |
| sync `prometheus-operator-crds` lỗi `invalid ownership metadata` | CRD do kube-prometheus-stack cũ cài (`crds/`, không có nhãn helm) | gán nhãn/annotation một lần ([README](../../kubernetes/releases/observability/prometheus-operator-crds/README.md#existing-cluster-whose-crds-came-from-kube-prometheus-stack)) |
| `sync` treo ~900 s, Service `<pending>` | `type: LoadBalancer` trên cluster không cấp LB | cài một LB cho cluster (MetalLB — [`local-cluster-kubeadm.md` bước 7b](local-cluster-kubeadm.md#bước-7b--loadbalancer-metallb-)); Docker Desktop (kind) và EKS đã có sẵn |
| `ImagePullBackOff`, image `….dkr.ecr…/bitnami/*` | không có ECR mirror | local: `--set global.imageRegistry=docker.io --set image.repository=bitnamilegacy/<image>` |
| `ImagePullBackOff`, `context deadline exceeded` tới `registry-1.docker.io` | engine Docker Desktop không ra được Docker Hub | kiểm tra `docker pull <image>`; proxy/mạng Docker Desktop |
| `context deadline exceeded` khi sync | pod không Ready trong 900 s; release thành `failed` | `kubectl -n <ns> describe pod`, `logs`; sửa nguyên nhân rồi `sync` lại (release `failed` tự được nâng cấp) |
| `render` lỗi `requiredEnv AWS_ACCOUNT_ID` / không giải mã được | thiếu biến / age key | A3 |

Override `--set` chỉ dành cho cluster thử nghiệm: không lưu vào git, lần sync sau không có `--set` sẽ đưa
value của môi trường trở lại. Sự cố khác: [`kubernetes/docs/TROUBLESHOOTING.md`](../../kubernetes/docs/TROUBLESHOOTING.md).

---

# Phụ lục

## P1. Trạng thái hiện tại

Đúng tại thời điểm viết (2026-10-23) — kiểm tra lại bằng lệnh ở cột cuối.

| Target | Đã chạy | Còn chặn | Kiểm tra |
|---|---|---|---|
| Local Docker Desktop (`docker-desktop-dev`) — kind, 3 node, v1.36.1 | **trống** (2026-10-27: đã cài `prometheus-operator-crds` + cert-manager bằng một lần `sync`, sync lần 2 tạo lại ClusterIssuer qua hook, rồi gỡ sạch — [`local-docker-desktop.md`](local-docker-desktop.md) bước 11) | `letsencrypt-*` `Ready=False` (`invalidContact`: email `example.com`); kong chưa từng chạy được (Docker Hub) | `bash scripts/cluster/preflight.sh --cluster docker-desktop-dev`; `helm --kube-context docker-desktop list -A` |
| Local Lima + kubeadm (`self-managed-dev`) — target `dev` hiện tại của máy này | 2 node (control-plane + worker đã join), Calico; namespaces; metrics-server (value gốc, kiểm TLS đủ); MetalLB; CRD Prometheus Operator; cert-manager + ClusterIssuer `local-ca`; kong (LoadBalancer `192.168.104.200`, value gốc); `devops-platform`, `test-app` (HTTP + HTTPS qua Kong, chứng chỉ CA local, Ingress có ADDRESS); NetworkPolicy đã áp, Calico thực thi | app dùng `local-ca` qua override `--set` (không trong git); `frontend-html` chặn vì `REPLACE_WITH_`; chưa có StorageClass; kubectl lệch 3 minor | `bash scripts/cluster/preflight.sh --cluster self-managed-dev --context self-managed-dev` |
| EKS dev | — | `account.id`/`bucket` trống → chưa có cluster; context `eks-dev.yaml` còn placeholder | `yq '.account.id' environments/dev/terraform/environment.yaml` |
| EKS staging, prod | — | như dev; `.sops.yaml` còn `REPLACE_WITH_` (secret staging/prod đang mã hoá bằng key dev); `devops-platform` `tests.image` còn `REPLACE_WITH_` | `grep -rnE '^[^#]*REPLACE_WITH_' environments applications .sops.yaml` |

## P2. Deploy riêng một tool — cần gì trước

Mỗi tool là một helmfile state riêng; helmfile **không** kiểm tra phụ thuộc giữa các tool. Nguồn: render
`dev` của từng tool (2026-10-23).

| Điều kiện | Tool | Thiếu thì |
|---|---|---|
| Chỉ namespace + image public | prometheus-operator-crds (không cần age key), metrics-server, reloader, external-secrets, argocd, falco, loki, opensearch, opensearch-dashboards, kong | — |
| CRD `ServiceMonitor` (minio thêm `Probe`) — do **prometheus-operator-crds** cài | kube-prometheus-stack, keda, cert-manager, ingress-nginx, external-dns, minio, postgresql, redis, kafka, clickhouse, tempo, mimir, opentelemetry-collector, alloy, grafana, vault, sealed-secrets, kyverno, trivy-operator, harbor | sync lỗi `no matches for kind "ServiceMonitor"` |
| Image ECR mirror (`bitnami/*` từ `bitnamilegacy`) | postgresql, redis, kafka, clickhouse | ImagePullBackOff ngoài AWS |
| Chỉ chạy trên AWS | external-dns (IRSA + Route53), velero (IRSA + S3), karpenter / cluster-autoscaler (hiện `none` → 0 object) | không tác dụng / lỗi quyền |
| Service `LoadBalancer` | kong, ingress-nginx | treo 900 s nếu không có LB |
| Tool khác chạy trước | harbor → postgresql, redis, minio, kong · mimir → minio · grafana → kube-prometheus-stack, loki, tempo · alloy, opentelemetry-collector → loki, tempo · Ingress của grafana, minio, opensearch-dashboards, argocd, harbor → kong (argocd thêm ClusterIssuer) | pod lỗi kết nối / Ingress không có đường vào |
| `AWS_ACCOUNT_ID` | postgresql, redis, kafka, clickhouse, velero, external-dns, karpenter, cluster-autoscaler | render lỗi |
| Age key của môi trường | mọi tool | render lỗi |

## P3. Chuỗi lệnh đã chạy thật trên Docker Desktop

Docker Desktop Kubernetes (kind, 3 node, v1.36.1), 2026-10-22. `target.local.yaml`: `cluster: docker-desktop-dev`.

```bash
C=docker-desktop
kubectl config view --minify --context=$C -o jsonpath='{.clusters[0].cluster.server}{"\n"}'   # https://127.0.0.1:…
bash scripts/cluster/preflight.sh --cluster docker-desktop-dev                                   # FAIL 0

# B1 Infra Base
kubectl --context=$C diff  -f environments/dev/kubernetes/namespace/namespaces.yaml
kubectl --context=$C apply -f environments/dev/kubernetes/namespace/namespaces.yaml

# B2 Platform — metrics-server, override chỉ cho local
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
T=kubernetes/releases/platform/metrics-server/helmfile.yaml.gotmpl
LOCAL='args={--kubelet-preferred-address-types=InternalIP\,Hostname\,ExternalIP,--kubelet-insecure-tls}'
helmfile -e dev --kube-context $C -f $T diff --set "$LOCAL"
helmfile -e dev --kube-context $C -f $T sync --set "$LOCAL"

# B4 Application
helmfile -e dev -l name=devops-platform diff
helmfile -e dev -l name=devops-platform sync          # [OK] devops-platform @ dev → … context 'docker-desktop'

# Verify
kubectl --context=$C -n dev rollout status deploy/devops-platform-application --timeout=120s
helm --kube-context $C -n dev test devops-platform    # Phase: Succeeded
kubectl --context=$C top nodes
```
