# 03 — Value đến từ đâu và được ghép thế nào

Trang này trả lời: value của mỗi lớp nằm ở file nào, ghép theo thứ tự nào, cluster đích lấy từ đâu,
và làm sao xem value cuối cùng đi vào chart. Mọi ví dụ lấy từ repo và đã render thật
(app `devops-platform`, môi trường `dev`). Lệnh deploy từng bước:
[`20-runbooks/kubernetes-manual.md`](20-runbooks/kubernetes-manual.md).

## 1. Ba khái niệm — đừng lẫn

| | Là gì | Ở đâu |
|---|---|---|
| **Template** | cách dựng, dùng chung mọi môi trường và mọi cluster | chart `kubernetes/charts/application`, release `kubernetes/releases/<group>/<tool>/helmfile.yaml.gotmpl`, release app sinh trong `applications/helmfile.yaml.gotmpl` |
| **Môi trường Helmfile** (`-e`) | `dev`, `staging`, `prod` — **chỉ ba cái này** được khai báo | `environments:` trong `helmfile.yaml.gotmpl` (gốc), `applications/helmfile.yaml.gotmpl`, `kubernetes/helmfile.yaml.gotmpl` và từng helmfile tool |
| **Target cluster** | cluster thật mà một môi trường chạy lên (EKS, Docker Desktop, K3s…) | app: `environments/<env>/kubernetes/cluster/target(.local).yaml` → `<cluster>.yaml`; platform: cờ `--kube-context` |
| **Override theo môi trường** | value khác nhau thật sự giữa dev/staging/prod | `environments/<env>/kubernetes/…`, `applications/<app>/k8s/<env>/values.yaml` |

`applications/_template/` là **khuôn** để tạo app (`make new-app` chỉ copy và thay tên), **không phải**
một môi trường: `helmfile -e template` không tồn tại, và folder bắt đầu bằng `_` bị Helmfile,
Argo CD và Terraform bỏ qua.

Cùng một template chạy trên nhiều cluster vì **cluster không nằm trong value**: đổi cluster là đổi
target (file target hoặc `--kube-context`), không phải copy template. Value chỉ khác theo
**môi trường** (`dev`/`staging`/`prod`); hai cluster cùng là `dev` (vd EKS dev và Docker Desktop
của bạn) nhận đúng cùng value.

## 2. Lớp Infra Base — không có value, là manifest thuần

`environments/<env>/kubernetes/namespace/namespaces.yaml` (Namespace + nhãn PSA) và
`environments/<env>/kubernetes/network/*.yaml` (NetworkPolicy) là YAML thuần, `kubectl apply` thẳng.
Không có template, không ghép gì: file nào ở môi trường nào là đúng thứ được apply.
Repo **không** có RBAC, ResourceQuota hay LimitRange cho namespace — muốn có thì thêm vào đây.

## 3. Lớp Platform — `kubernetes/releases/<group>/<tool>/`

```text
kubernetes/repositories.yaml                       repo chart + helmDefaults (bases:)
environments/<env>/kubernetes/state.yaml           value của STATE helmfile: env, ingressClass, ingressDomain,
                                                    storageClass, nodeAutoscaler, ingressNginx…  → {{ .Values.<key> }}
environments/<env>/kubernetes/secrets.enc.yaml     SOPS, ghép vào cùng state                     → {{ .Values.secrets.<x> }}
biến môi trường shell                               AWS_ACCOUNT_ID (requiredEnv), AWS_REGION, ACME_EMAIL → {{ requiredEnv/env }}
        │  (helmfile render file .gotmpl)
        ▼
environments/<env>/kubernetes/{tools,ingress,monitoring}/<tool>/values.yaml.gotmpl   value của CHART, đầy đủ cho môi trường đó
        │  (helm ghép lên)
        ▼
values.yaml mặc định của chart upstream (version ghim trong helmfile của tool)
```

Ví dụ thật — `kubernetes/releases/platform/metrics-server/helmfile.yaml.gotmpl`:

```yaml
environments:
  dev: { values: [ ../../../../environments/dev/kubernetes/state.yaml ],
         secrets: [ ../../../../environments/dev/kubernetes/secrets.enc.yaml ] }
releases:
  - name: metrics-server
    namespace: kube-system
    chart: metrics-server/metrics-server
    version: 3.13.1
    labels: { name: metrics-server, layer: platform, tier: infra, component: metrics, env: "{{ $env }}" }
    values:
      - ../../../../environments/{{ .Environment.Name }}/kubernetes/tools/metrics-server/values.yaml.gotmpl
```

Hệ quả cần biết:

- **Mỗi tool chỉ có một file value cho mỗi môi trường** (không có file chung — [ADR 0002](adr/0002-no-shared-value-layer.md)).
  Đổi cho mọi môi trường = sửa cả ba file `dev/`, `staging/`, `prod/`.
- **Mọi** helmfile tool đều nạp `secrets.enc.yaml`, nên kể cả `template` của tool không dùng secret
  (metrics-server) cũng cần age key của môi trường đó.
- `requiredEnv "AWS_ACCOUNT_ID"` có trong value của clickhouse, postgresql, redis, kafka, velero,
  external-dns, karpenter, cluster-autoscaler: render cả lớp platform mà thiếu biến này thì lỗi.
- **Helmfile platform không ghim kube context.** Không có `kubeContext` trong `kubernetes/`; `diff`/`sync`
  dùng `--kube-context` bạn truyền, hoặc — nếu quên — *current-context* của kubeconfig. Luôn truyền
  `--kube-context <ctx>`.

## 4. Lớp Application — `applications/<app>/k8s/<env>/values.yaml`

Định nghĩa **một chỗ duy nhất**: `applications/helmfile.yaml.gotmpl`. Nó sinh một release cho mỗi
file `applications/<app>/k8s/<env>/values.yaml` tồn tại (không khai báo release bằng tay):

```text
#  lớp (thấp → cao)                                           ai sở hữu    đặt gì
1  kubernetes/charts/application/values.yaml                  platform     mặc định của chart (+ values.schema.json kiểm kiểu)
2  environments/<env>/kubernetes/app-values.yaml.gotmpl       platform     mặc định cho MỌI app của môi trường: global.imageRegistry,
                                                                           securityContext, NetworkPolicy, ingress.className + annotation,
                                                                           replica/HPA/PDB/resources, topologySpread
3  applications/<app>/k8s/<env>/values.yaml                   app team     toàn bộ cấu hình của app ở môi trường đó
        ▼
   chart application → manifest (release <app>, namespace <env>, object <app>-application)
```

Argo CD không đọc được helmfile: `kubernetes/argocd/bootstrap/applicationset-apps.yaml` lặp lại đúng
lớp 2 và 3 (`valueFiles`), và `scripts/docs/check-argocd-layers.sh` báo lỗi khi hai bên lệch.
File lớp 2 có đuôi `.gotmpl` nhưng là YAML thuần (Argo CD đọc nó như YAML) — không đặt `{{ }}` trong đó.

### 4.1 Khi hai file cùng khai báo một key

Helm ghép **map theo từng key** (lớp sau thắng), còn **list và giá trị đơn bị thay cả cục**.
Kết quả thật của `devops-platform` ở `dev` (`helmfile -e dev -l name=devops-platform write-values`):

| Key | Lớp 2 (`environments/dev/…/app-values`) | Lớp 3 (`applications/devops-platform/k8s/dev`) | Kết quả | Vì sao |
|---|---|---|---|---|
| `ingress.annotations` | `konghq.com/protocols`, `konghq.com/plugins` | `cert-manager.io/cluster-issuer` | **cả ba** annotation | map → gộp |
| `ingress.className` | `kong` | không đặt | `kong` | lớp dưới giữ nguyên |
| `resources.requests.cpu` | `50m` | `10m` | `10m` | lớp sau thắng |
| `resources.limits` | `{memory: 256Mi}` | `{cpu: 200m, memory: 128Mi}` | `{cpu: 200m, memory: 128Mi}` | map gộp, key trùng lớp sau thắng |
| `extraVolumes` | `[tmp (128Mi)]` | `[tmp (32Mi), nginx-conf]` | **chỉ** list của app | list → thay cả list |
| `replicaCount` | `1` | không đặt | `1` | |
| `global.imageRegistry` | `REPLACE_WITH_DEV_AWS_ACCOUNT_ID…` | không đặt, nhưng `image.registry: docker.io` | image `docker.io/…` | `image.registry` của app ưu tiên hơn registry chung |

Vì list bị thay cả cục: app nào đặt `extraVolumes` phải tự giữ lại volume `tmp` (bắt buộc khi
`readOnlyRootFilesystem: true`). Muốn **xoá** một key map của lớp dưới, đặt nó thành `null` ở lớp trên.

### 4.2 Placeholder `REPLACE_WITH_`

Helmfile quét các file value của từng release: còn dòng không-comment chứa `REPLACE_WITH_` thì
`release-guard.sh` chặn `sync`/`apply`/`destroy` (template và diff vẫn chạy). App tự đặt
`image.registry` thì dòng `imageRegistry:` của lớp 2 được bỏ qua khi quét — vì thế `devops-platform`
và `test-app` (registry `docker.io`) deploy được ở `dev` ngay, còn `frontend-html` (dùng ECR của môi
trường) bị chặn cho tới khi `global.imageRegistry` của `dev` được điền account thật.

## 5. Cluster đích (kube context) lấy từ đâu

**App** (`applications/helmfile.yaml.gotmpl`, cho từng môi trường):

```text
cluster  = target.yaml  ← ghi đè bởi target.local.yaml (gitignored, chỉ máy bạn)      (environments/<env>/kubernetes/cluster/)
context  = KUBE_CONTEXT_<ENV>  >  context: trong target.local.yaml/target.yaml  >  context: trong <cluster>.yaml
owner    = APP_TIER_OWNER      >  delivery.owner trong <cluster>.yaml
```

Context còn dạng `<placeholder>` (vd `eks-dev.yaml`: `context: <eks-dev-context-alias>`) coi như
chưa cấu hình → guard chặn. `KUBE_CONTEXT` (không có hậu tố môi trường) **không** được đọc cho app;
nếu nó đang export và khác context đã chọn, guard chặn. `target.local.yaml` có cùng dạng với
`target.yaml` — khoá `cluster:` ở cấp gốc:

```yaml
# environments/dev/kubernetes/cluster/target.local.yaml   (gitignored)
schema: kubernetes-target/v1alpha1
cluster: docker-desktop-dev      # → docker-desktop-dev.yaml: context docker-desktop, owner helmfile
# context: my-alias              # tuỳ chọn: ghi đè context của file cluster
```

**Platform** (`kubernetes/`): không có cơ chế target — luôn `--kube-context <ctx>` trên dòng lệnh.

**Infra Base** (`kubectl`): luôn `--context=<ctx>` trên dòng lệnh.

## 6. Xem value và manifest cuối cùng (không chạm cluster)

Chạy từ gốc repo.

```bash
# App — value của lớp 2 + 3 đã ghép, ghi ra file (chưa gồm mặc định của chart):
helmfile -e dev -l name=devops-platform write-values --skip-deps \
  --output-file-template '/tmp/{{ .Release.Name }}-{{ .Environment.Name }}.yaml'

# App — manifest cuối cùng (đủ 3 lớp):
helmfile -e dev -l name=devops-platform template --skip-deps

# Cùng kết quả bằng helm thuần — đúng thứ tự -f như helmfile và Argo CD:
helm template devops-platform kubernetes/charts/application -n dev \
  -f environments/dev/kubernetes/app-values.yaml.gotmpl \
  -f applications/devops-platform/k8s/dev/values.yaml

# Value một key cụ thể sau khi ghép:
yq '.ingress' /tmp/devops-platform-dev.yaml

# Platform — manifest của một tool (cần age key của môi trường; tool có requiredEnv cần AWS_ACCOUNT_ID):
helmfile -e dev -f kubernetes/releases/platform/metrics-server/helmfile.yaml.gotmpl template

# Đã deploy — value mà release đang chạy thật sự nhận (chỉ đọc):
helm --kube-context <ctx> -n dev get values devops-platform            # chỉ phần người dùng truyền vào
helm --kube-context <ctx> -n dev get values devops-platform --all      # gồm cả mặc định của chart
```

`helm template` thuần **chỉ để xem**: nó bỏ qua `release-guard.sh`. Deploy app luôn qua `helmfile`.
