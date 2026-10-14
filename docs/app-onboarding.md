# Đưa một application lên platform

Mọi thứ của một app nằm trong `applications/<app>/`, mỗi môi trường một chỗ. Ví dụ đầy đủ,
chạy được: [`applications/frontend-html/`](../applications/frontend-html/).

```text
applications/<app>/
  README.md                 ghi chú vận hành của app
  k8s/                      (chỉ app eks) value của chart application
    values.yaml             chung mọi môi trường: image, probe, resources, config
    dev/values.yaml         môi trường dev: host, tag, replica…
    staging/values.yaml
    prod/values.yaml
    local/values.yaml       minikube — có file này là app được deploy local
    onprem-dev/values.yaml  cluster on-prem (tuỳ chọn): chỉ phần site khác — host, issuer
    onprem-staging/values.yaml
    onprem-prod/values.yaml
  terraform/                Terraform đọc (tên môi trường kiểu Terraform)
    app.yaml                chung: runtime, image.repository, container
    dev.yaml                có file = app có ở dev (ECR; ECS service với app ecs)
    staging.yaml
    production.yaml
```

Terraform giữ một file mỗi môi trường trong `terraform/` vì `terraform/shared/config` đọc đúng
đường dẫn đó và dùng tên `production` (không phải `prod`). Đổi chỗ này là sửa code Terraform
dùng chung cho cả ba stack.

Base mà app dùng (cluster, registry, ingress, DB, observability…): [`platform-base.md`](platform-base.md).

## 0. Chọn runtime

| | `eks` | `ecs` |
|---|---|---|
| Chạy trên | `platform-<env>-eks`, namespace `dev` \| `staging` \| `prod` | ECS Fargate `platform-<env>-ecs` |
| Deploy bởi | Argo CD (ApplicationSet đọc `applications/*/k8s`) | `terraform/stacks/service` (pipeline của repo này) |
| Value | chart [`application`](reference/application-chart.md) | [`app.yaml` / `<env>.yaml`](reference/ecs-app.md) |
| Đường vào HTTP | Ingress `nginx-<env>` (có sẵn) | ALB của core — **đang tắt** |
| Dùng DB/Redis/Kafka trong cluster | được | không (ClusterIP) |

## 1. Tạo khung

```bash
make new-app APP=<tên> RUNTIME=eks     # hoặc RUNTIME=ecs
```

Tên: `^[a-z0-9][a-z0-9-]{0,52}$`, trùng tên release, tên repo ECR và thường là tên repo code.
Khung lấy từ [`docs/templates/`](templates/), mọi chỗ cần điền đánh dấu `REPLACE_WITH_`.
File value chỉ có key/value, chia block theo thành phần (`# ── Image ──`, `# ── Service ──`, …):
`k8s/values.yaml` có **đủ mọi option của chart**, option chưa dùng để `# ` kèm giá trị mặc định — bỏ `# `
để bật; `k8s/<env>/values.yaml` có block `# ── Tuỳ chọn ──` (replica, HPA, resources, PDB, env); file
Terraform: key đang bật là bắt buộc, key `# ` là tuỳ chọn. Ý nghĩa từng key: [tham chiếu chart](reference/application-chart.md),
[tham chiếu ECS](reference/ecs-app.md). App đã có sẵn:
`python3 docs/tools/gen-app-values.py applications/<app>/k8s/values.yaml | python3 docs/tools/strip-notes.py -`
in ra bản đủ option.
VS Code (extension YAML trong `.vscode/extensions.json`) gợi ý key và báo sai kiểu ngay khi gõ
cho các file trong `applications/*/k8s` và `applications/*/terraform`.

## 2. App EKS

1. **`terraform/app.yaml`**: `runtime.type: eks`, `image.repository`, `container.port`.
   `dev.yaml` / `staging.yaml` / `production.yaml` để `{}` — có file thì có repo ECR ở môi trường đó.
2. **`k8s/values.yaml`**: những gì giống nhau mọi môi trường: `image.repository` (trùng bên trên),
   probes, resources, cổng phụ, `env`, `serviceMonitor`. Mọi key: [tham chiếu chart](reference/application-chart.md).
3. **`k8s/<env>/values.yaml`** (`dev`, `staging`, `prod`): `image.tag` (hoặc `image.digest`), host Ingress, replica nếu khác tier.
   Host phải nằm trong `ingressDomain` của môi trường (`dev.example.com`, `staging.example.com`, `example.com`),
   nếu không external-dns bỏ qua và cert-manager không cấp được chứng chỉ.
4. **Secret**: tạo Secret `<app>` trong namespace của môi trường (SealedSecrets / External Secrets),
   rồi bật `extraEnvFrom` trong `values.yaml`. Không ghi secret vào file value.
5. **Kiểm tra offline**:
   ```bash
   make argocd-render                 # render app × dev/staging/prod với đủ các lớp value
   make stacks-lint stacks-config     # file terraform của app (cần yamllint, check-jsonschema)
   ```
6. **Repo code của app**: include `ci/deploy-template.gitlab-ci.yml` (biến ở [mục 5](#5-biến-ci-của-repo-app)).
   Pipeline build → push vào ECR dev → promote **theo digest** sang staging/prod (không build lại).
7. **Deploy**: merge thay đổi `k8s/<env>/values.yaml` (tag mới) vào `main` của repo này. Argo CD
   tự sync dev và staging; prod sync tay sau review.

## 3. App ECS

1. **`terraform/app.yaml`**: `runtime.type: ecs`, `image.repository`, `container.*`.
2. **`terraform/dev.yaml`**: `resources.cpu/memory`, `deployment.replicas`, `environment`, `secrets` (ARN).
3. **`staging.yaml` / `production.yaml`**: thêm `image.tag` ghim (bắt buộc).
4. Kiểm tra: `make stacks-lint stacks-config`.
5. Merge → pipeline dev plan registry (tạo ECR). Repo app build, push, rồi trigger repo này với
   `APP_NAME`, `ENVIRONMENT`, `IMAGE_TAG` → `plan:service` → `apply:service` (staging/production duyệt tay).
   Chi tiết: [terraform/README → Adding an application](../terraform/README.md#adding-an-application).

Chưa có đường vào từ ngoài cho đến khi core bật `alb` (xem [platform-base](platform-base.md#1-tầng-aws--terraformstackscore-dùng-chung-mọi-app)).

## 4. Value nào đã có sẵn

App EKS được render từ các lớp sau, **lớp sau ghi đè lớp trước** (Argo CD ApplicationSet,
`make argocd-render` và CI `argocd:validate` dùng cùng thứ tự):

| # | File | Ai sở hữu | Đặt sẵn |
|---|---|---|---|
| 1 | `k8s/charts/application/values.yaml` | platform (chart) | mặc định của chart — [tham chiếu](reference/application-chart.md) |
| 2 | `infra-base/k8s/env-values/app-values.yaml.gotmpl` | platform | securityContext cứng (non-root, read-only rootfs, drop ALL), ServiceAccount không mount token, NetworkPolicy cơ bản |
| 3 | `infra-base/k8s/env-values/<env>/app-values.yaml.gotmpl` | platform | `global.imageRegistry`, IngressClass, issuer (prod), replica/HPA/PDB/resources theo tier, egress — [bảng theo tier](reference/env-values.md#kubernetes--k8senv-values) |
| 4 | `applications/<app>/k8s/values.yaml` | app | phần riêng của app |
| 5 | `applications/<app>/k8s/<env>/values.yaml` | app | tag, host, khác biệt theo môi trường |

Local dùng cùng thứ tự, thay lớp 3 bằng `local/values/app-values.yaml` và lớp 5 bằng `applications/<app>/k8s/local/values.yaml`.

On-prem (`onprem-<env>`) dùng **đúng** các lớp của `<env>` rồi thêm hai lớp: sau lớp 3 là
`infra-base/k8s/env-values/onprem-<env>/app-values.yaml.gotmpl` (registry của site, issuer CA nội bộ),
và cuối cùng là `applications/<app>/k8s/onprem-<env>/values.yaml` (host trong zone DNS của site).
Vì vậy cùng một release (image digest, ConfigMap, probe, sizing theo tier) chạy trên cả hai target;
`make app-render APP=<app> ENV=prod` và `ENV=onprem-prod` chỉ khác registry, host và issuer.
Argo CD trên cluster on-prem chỉ dùng các lớp này sau khi phần platform on-prem được duyệt và áp
(ApplicationSet chọn target theo label cluster) — trước đó chúng được render và kiểm tra trong
`make argocd-render` / CI `argocd:validate`.

Vì vậy **không** cần (và không nên) ghi lại trong file của app: registry, securityContext,
IngressClass, NetworkPolicy cơ bản. Chỉ ghi khi app thật sự khác. Map gộp theo key; list bị
thay thế cả list (vd `ingress.hosts`, `networkPolicy.egress.customRules`).

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
| Bất kỳ key nào của chart, mọi môi trường | `k8s/values.yaml` | probes, resources, `env`, `command`/`args` |
| Khác theo môi trường | `k8s/<env>/values.yaml` | host, replica, tag |
| File cấu hình (nginx.conf, config.json, HTML…) | `extraConfigMaps` + `extraVolumes`/`extraVolumeMounts` | `applications/frontend-html` |
| Object Kubernetes chart không có sẵn | `extraObjects` | PodMonitor, ConfigMap ngoài |
| Init container, sidecar, worker, cronjob | `initContainers`, `extraContainers`, `workers`, `cronjobs` | migration, consumer |
| Chỉ khi chạy local (minikube) | `k8s/local/values.yaml` — có file này là app được deploy local | registry upstream thay ECR, host `*.localhost` |
| Ghi chú vận hành riêng của app | `applications/<app>/README.md` | lệnh, phụ thuộc, người phụ trách |

Hai bẫy đã gặp trong chart:
- **Nhiều mục trong `extraConfigMaps`:** chart in các ConfigMap không có `---` ngăn cách, nên chỉ mục cuối còn lại sau khi render. Cách tránh: dùng **một** ConfigMap nhiều key, mount từng key bằng `items`.
- **Thay đổi `extraConfigMaps` không tự restart pod:** chart không gắn checksum cho chúng. Bật `reloader.enabled: true` (cluster AWS có Reloader); ở local thì restart tay.

Value đi qua `tpl`, nên nội dung có cặp ngoặc nhọn kép của Go template sẽ bị render.

### Lệnh thủ công cho một app

Không thay đổi gì (đọc, render, kiểm tra):

```bash
make app-render APP=<app> ENV=dev            # manifest cuối cùng của 1 app ở 1 môi trường
make app-values APP=<app> ENV=prod           # value cuối cùng (mọi lớp đã ghép), dạng YAML kiểu JSON
make app-values APP=<app> ENV=all            # dev, staging, prod, local, onprem-* liên tiếp để so sánh
make argocd-render                           # mọi app × mọi môi trường
make stacks-lint stacks-config               # file terraform của app
```

Local (minikube; context ghim trong `local/defaults.yaml.gotmpl`):

```bash
minikube start --kubernetes-version=v1.32.12 --addons=ingress --addons=metrics-server
cd local
helmfile -e local -l layer=platform sync            # CRD + namespace `local`, một lần
helmfile -e local -l name=<app> template            # xem trước
helmfile -e local -l name=<app> sync                # deploy
kubectl --context=minikube -n local get pods,svc,ingress
kubectl --context=minikube -n local rollout restart deploy/<app>-application   # sau khi đổi ConfigMap
minikube tunnel                                     # rồi mở http://<app>.localhost
helmfile -e local -l name=<app> destroy             # gỡ
```

AWS (Argo CD sở hữu app; không `helm install` tay):

```bash
# image vào ECR của môi trường, theo digest (không build lại)
crane copy <nguồn>@sha256:<digest> <account>.dkr.ecr.ap-southeast-1.amazonaws.com/<repo>:<tag>
argocd app diff <app>-<env>                  # xem thay đổi
argocd app sync <app>-<env>                  # prod: chỉ sau review (prod không auto-sync)
argocd app rollback <app>-<env> <history-id> # hoặc revert commit trong repo này
```
