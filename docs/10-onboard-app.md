# Đưa một application lên platform

Mọi thứ của một app nằm trong `applications/<app>/`, mỗi môi trường một chỗ. Ví dụ đầy đủ,
chạy được: [`applications/frontend-html/`](../applications/frontend-html/).

```text
applications/<app>/
  README.md                 ghi chú vận hành của app
  k8s/                      (chỉ app eks) value của chart application — KHÔNG có file chung của app
    dev/values.yaml         toàn bộ value của app ở dev: image, probe, resources, host, tag, replica…
    staging/values.yaml     toàn bộ value ở staging
    prod/values.yaml        toàn bộ value ở prod (chỉ dev/staging/prod; chạy ở cluster nào là deploy target, không phải value)
  terraform/                Terraform đọc (tên môi trường kiểu Terraform)
    app.yaml                chung: runtime, image.repository, container
    dev.yaml                có file = app có ở dev (ECR; ECS service với app ecs)
    staging.yaml
    production.yaml
```

Terraform giữ một file mỗi môi trường trong `terraform/` vì `terraform/shared/config` đọc đúng
đường dẫn đó và dùng tên `production` (không phải `prod`). Đổi chỗ này là sửa code Terraform
dùng chung cho cả ba stack.

Base mà app dùng (cluster, registry, ingress, DB, observability…): [`platform-base.md`](01-platform-base.md).

## 0. Chọn runtime

| | `eks` | `ecs` |
|---|---|---|
| Chạy trên | `platform-<env>-eks`, namespace `dev` \| `staging` \| `prod` | ECS Fargate `platform-<env>-ecs` |
| Deploy bởi | owner của cluster đích: Helmfile tay (`helmfile -e <env> -l name=<app> sync`, mọi cluster dev hiện tại) hoặc Argo CD (ApplicationSet đọc `applications/*/k8s`) — không bao giờ cả hai | `terraform/stacks/service` (pipeline của repo này) |
| Value | chart [`application`](reference/application-chart.md) | [`app.yaml` / `<env>.yaml`](reference/ecs-app.md) |
| Đường vào HTTP | Ingress class `kong` (có sẵn) | ALB của core — **đang tắt** |
| Dùng DB/Redis/Kafka trong cluster | được | không (ClusterIP) |

## 1. Tạo khung

```bash
make new-app APP=<tên> RUNTIME=eks     # hoặc RUNTIME=ecs
```

Tên: `^[a-z0-9][a-z0-9-]{0,52}$`, trùng tên release, tên repo ECR và thường là tên repo code.
Khung lấy từ [`applications/_template/`](../applications/_template/) (folder bắt đầu bằng `_` không phải app:
Helmfile, Argo CD và Terraform đều bỏ qua), mọi chỗ cần điền đánh dấu `REPLACE_WITH_`.
File value chỉ có key/value, chia block theo thành phần (`# ── Image ──`, `# ── Service ──`, …), mỗi block một dòng note:
mỗi `k8s/<env>/values.yaml` là **toàn bộ** value của app ở môi trường đó (không có file chung của app),
gồm **mọi key của chart**, đang bật, với đúng giá trị app nhận ở môi trường đó — render ra giống hệt một app
chỉ đặt phần riêng của nó. Sửa key nào app cần khác ngay trong file của môi trường đó. Đổi giá trị nền
(`environments/<env>/kubernetes/`) sau khi tạo app **không** tự đổi theo trong app này. File
Terraform: key đang bật là bắt buộc, key `# ` là tuỳ chọn. Ý nghĩa từng key: [tham chiếu chart](reference/application-chart.md),
[tham chiếu ECS](reference/ecs-app.md). Xem mọi option kèm mặc định cho một file:
`python3 scripts/docs/gen-app-values.py applications/<app>/k8s/<env>/values.yaml | python3 scripts/docs/strip-notes.py -`.
VS Code (extension YAML trong `.vscode/extensions.json`) gợi ý key và báo sai kiểu ngay khi gõ
cho các file trong `applications/*/k8s` và `applications/*/terraform`.

## 2. App EKS

1. **`terraform/app.yaml`**: `runtime.type: eks`, `image.repository`, `container.port`.
   `dev.yaml` / `staging.yaml` / `production.yaml` để `{}` — có file thì có repo ECR ở môi trường đó.
2. **`k8s/<env>/values.yaml`** (`dev`, `staging`, `prod`) — mỗi file đầy đủ,
   độc lập với file môi trường khác: `image.repository` (trùng bên trên), `image.tag` (hoặc `image.digest`),
   probes, resources, cổng phụ, `env`, `serviceMonitor`, host Ingress, replica nếu khác tier. Một thay đổi
   cho mọi môi trường phải sửa ở mọi file. Mọi key: [tham chiếu chart](reference/application-chart.md).
3. **Host Ingress**: phải nằm trong `ingressDomain` của môi trường (`dev.example.com`, `staging.example.com`, `example.com`),
   nếu không external-dns bỏ qua và cert-manager không cấp được chứng chỉ.
4. **Secret**: tạo Secret `<app>` trong namespace của môi trường (SealedSecrets / External Secrets),
   rồi bật `extraEnvFrom` trong `k8s/<env>/values.yaml`. Không ghi secret vào file value.
5. **Kiểm tra offline**:
   ```bash
   make argocd-render                 # render app × dev/staging/prod với đủ các lớp value
   make stacks-lint stacks-config     # file terraform của app (cần yamllint, check-jsonschema)
   ```
6. **Repo code của app**: include `ci/deploy-template.gitlab-ci.yml` (biến ở [mục 5](#5-biến-ci-của-repo-app)).
   Pipeline build → push vào ECR dev → promote **theo digest** sang staging/prod (không build lại).
7. **Deploy**: theo owner của cluster đích (`delivery.owner` trong `environments/<env>/kubernetes/cluster/<cluster>.yaml`).
   `helmfile` (mọi cluster dev hiện tại): từ gốc repo `helmfile -e <env> -l name=<app> diff` rồi `sync` —
   [`20-runbooks/kubernetes-manual.md`](20-runbooks/kubernetes-manual.md). `argocd`: merge thay đổi
   `k8s/<env>/values.yaml` vào `main`; Argo CD tự sync dev và staging, prod sync tay sau review.

## 3. App ECS

1. **`terraform/app.yaml`**: `runtime.type: ecs`, `image.repository`, `container.*`.
2. **`terraform/dev.yaml`**: `resources.cpu/memory`, `deployment.replicas`, `environment`, `secrets` (ARN).
3. **`staging.yaml` / `production.yaml`**: thêm `image.tag` ghim (bắt buộc).
4. Kiểm tra: `make stacks-lint stacks-config`.
5. Merge → pipeline dev plan registry (tạo ECR). Repo app build, push, rồi trigger repo này với
   `APP_NAME`, `ENVIRONMENT`, `IMAGE_TAG` → `plan:service` → `apply:service` (staging/production duyệt tay).
   Chi tiết: [terraform/README → Adding an application](../terraform/README.md#adding-an-application).

Chưa có đường vào từ ngoài cho đến khi core bật `alb` (xem [platform-base](01-platform-base.md#1-tầng-aws--terraformstackscore-dùng-chung-mọi-app)).

## 4. Value nào đã có sẵn

App EKS được render từ các lớp sau, **lớp sau ghi đè lớp trước**. Thứ tự này định nghĩa
**một chỗ duy nhất**: `applications/helmfile.yaml.gotmpl` (`make argocd-render`, `make app-render`,
CI `argocd:validate`, local đều đi qua file này); Argo CD ApplicationSet giữ một bản sao và
`make argocd-render` báo lỗi khi hai bên lệch:

| # | File | Ai sở hữu | Đặt sẵn |
|---|---|---|---|
| 1 | `kubernetes/charts/application/values.yaml` | platform (chart) | mặc định của chart — [tham chiếu](reference/application-chart.md) |
| 2 | `environments/<env>/kubernetes/app-values.yaml.gotmpl` | platform | securityContext cứng (non-root, read-only rootfs, drop ALL), ServiceAccount không mount token, NetworkPolicy cơ bản, `global.imageRegistry`, IngressClass, issuer (prod), replica/HPA/PDB/resources, egress — [bảng theo tier](reference/env-values.md#kubernetes--k8senv-values) |
| 3 | `applications/<app>/k8s/<env>/values.yaml` | app | **toàn bộ** value của app ở môi trường này (một file / môi trường, không có file chung của app) |

Cluster nào chạy môi trường đó (EKS, Docker Desktop, K3s, self-managed) không nằm trong value:
đó là deploy target trong `environments/<env>/kubernetes/cluster/target.yaml` (+ `target.local.yaml` riêng máy bạn).
Argo CD trên cluster on-prem chỉ dùng các lớp này sau khi phần platform on-prem được duyệt và áp
(ApplicationSet chọn target theo label cluster) — trước đó chúng được render và kiểm tra trong
`make argocd-render` / CI `argocd:validate`.

Vì vậy **không** cần (và không nên) ghi lại trong file của app: registry, securityContext,
IngressClass, NetworkPolicy cơ bản. Chỉ ghi khi app thật sự khác. Map gộp theo key; list bị
thay thế cả list (vd `ingress.hosts`, `networkPolicy.egress.customRules`). Ví dụ thật từng key:
[`03-values-mapping.md` §4.1](03-values-mapping.md#41-khi-hai-file-cùng-khai-báo-một-key).

## 5. Biến CI của repo app

Đặt ở group/project của repo app (nguồn: `ci/deploy-template.gitlab-ci.yml`):

| Biến | Bắt buộc | Ý nghĩa |
|---|---|---|
| `DEV_AWS_ACCOUNT_ID`, `STAGING_AWS_ACCOUNT_ID`, `PRODUCTION_AWS_ACCOUNT_ID` | ✅ | account mỗi môi trường; job assume `gitlab-deploy-<env>` bằng OIDC, không có AWS key |
| `HELM_PROJECT_ID`, `HELM_TRIGGER_TOKEN` | ✅ | project ID và trigger token của repo platform này |
| `DEPLOY_TOOLS_IMAGE`, `CI_IMAGE` | ✅ | image công cụ (build từ `ci/images/`) |
| `SERVICE_NAME` | | mặc định `$CI_PROJECT_NAME`; phải trùng tên app |
| `MIGRATION_ENABLED`, `MIGRATION_COMMAND`, `MIGRATION_TIMEOUT` | | migration DB (`false`, `./app migrate --up`, `300`) |

Branch → môi trường: `dev`/`develop`/`feature/*` → dev, `staging`/`release/*` → staging, `main`/`master` → prod (manual).

## 6. Trước khi lên prod

- [ ] `image.digest` hoặc tag bất biến, đã promote (không build lại)
- [ ] `probes.readiness` (và startup nếu khởi động chậm), `resources` đo theo thực tế
- [ ] Host trong `example.com`, có `tls`
- [ ] Secret `<app>` tồn tại ở namespace `prod`
- [ ] `serviceMonitor` bật; có alert cho app (PrometheusRule) và người nhận
- [ ] `make argocd-render` sạch; Argo CD diff đã xem
- [ ] Rollback: tag trước đó trong `k8s/prod/values.yaml` (revert commit) hoặc rollback trong Argo CD

## 7. Tuỳ biến riêng và lệnh thủ công

`make new-app` chỉ tạo **điểm bắt đầu**. Sau đó các file trong `applications/<app>/` là của app:
sửa, thêm key tuỳ ý. Không có gì sinh lại hay ghi đè chúng.

### Đặt cấu hình riêng ở đâu

| Cần | Đặt ở | Ví dụ |
|---|---|---|
| Bất kỳ key nào của chart | `k8s/<env>/values.yaml` — mỗi môi trường một file đầy đủ; key chung phải ghi ở mọi file | probes, resources, `env`, host, replica, tag |
| File cấu hình (nginx.conf, config.json, HTML…) | `extraConfigMaps` + `extraVolumes`/`extraVolumeMounts` | `applications/frontend-html` |
| Object Kubernetes chart không có sẵn | `extraObjects` | PodMonitor, ConfigMap ngoài |
| Init container, sidecar, worker, cronjob | `initContainers`, `extraContainers`, `workers`, `cronjobs` | migration, consumer |
| Ghi chú vận hành riêng của app | `applications/<app>/README.md` | lệnh, phụ thuộc, người phụ trách |

Hai bẫy đã gặp trong chart:
- **Nhiều mục trong `extraConfigMaps`:** chart in các ConfigMap không có `---` ngăn cách, nên chỉ mục cuối còn lại sau khi render. Cách tránh: dùng **một** ConfigMap nhiều key, mount từng key bằng `items`.
- **Thay đổi `extraConfigMaps` không tự restart pod:** chart không gắn checksum cho chúng. Bật `reloader.enabled: true` (cluster AWS có Reloader); ở local thì restart tay.

Value đi qua `tpl`, nên nội dung có cặp ngoặc nhọn kép của Go template sẽ bị render.

### Lệnh thủ công cho một app

Không thay đổi gì (đọc, render, kiểm tra):

```bash
helmfile -e dev -l name=<app> template --skip-deps       # manifest cuối cùng của 1 app ở 1 môi trường
helmfile -e prod -l name=<app> write-values --skip-deps \
  --output-file-template '/tmp/{{ .Release.Name }}-{{ .Environment.Name }}.yaml'   # value lớp 2 + 3 đã ghép
helm lint kubernetes/charts/application \
  -f environments/dev/kubernetes/app-values.yaml.gotmpl -f applications/<app>/k8s/dev/values.yaml
helmfile -e staging template --skip-deps > /dev/null     # mọi app của một môi trường render được
```

Lối tắt tương đương (tuỳ chọn): `make app-render`, `make app-values`, `make argocd-render` (thêm kiểm tra
lớp value của ApplicationSet), `make stacks-lint stacks-config` (file terraform của app).

Deploy tay một app (từ gốc repo; cluster lấy từ `environments/<env>/kubernetes/cluster/target(.local).yaml`):

```bash
helmfile -e dev -l name=<app> template              # xem trước, không chạm cluster
helmfile -e dev -l name=<app> diff
helmfile -e dev -l name=<app> sync                  # chỉ release có name=<app>; prod cần CONFIRM_DEPLOY=<app>@prod
helmfile -e dev -l name=<app> destroy               # gỡ — xác nhận đúng release/namespace/context trước
```

Từng bước, kiểm tra sau deploy, rollback: [`20-runbooks/kubernetes-manual.md`](20-runbooks/kubernetes-manual.md#b4-application).

AWS (Argo CD sở hữu app; không `helm install` tay):

```bash
# image vào ECR của môi trường, theo digest (không build lại)
crane copy <nguồn>@sha256:<digest> <account>.dkr.ecr.ap-southeast-1.amazonaws.com/<repo>:<tag>
argocd app diff <app>-<env>                  # xem thay đổi
argocd app sync <app>-<env>                  # prod: chỉ sau review (prod không auto-sync)
argocd app rollback <app>-<env> <history-id> # hoặc revert commit trong repo này
```
