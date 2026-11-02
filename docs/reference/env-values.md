# Tham chiếu — giá trị môi trường (platform)

Những giá trị **platform** đặt một lần cho cả môi trường. App không sửa các file này;
app đọc chúng để biết mình được cấp gì. Đổi ở đây ảnh hưởng mọi app trong môi trường.

## Tên môi trường không giống nhau giữa các phần

| | dev | staging | production |
|---|---|---|---|
| Terraform (`ENVIRONMENT`, `environments/<env>/terraform/`, `applications/<app>/terraform/<env>.yaml`) | `dev` | `staging` | `production` |
| Helm / Argo (`helmfile -e`, `DEPLOY_ENV`, `environments/<env>/kubernetes/`, namespace, `applications/<app>/k8s/<env>/`) | `dev` | `staging` | `prod` |
| EKS cluster | `platform-dev-eks` | `platform-staging-eks` | `platform-production-eks` |
| ECS cluster | `platform-dev-ecs` | `platform-staging-ecs` | `platform-production-ecs` |
| Branch của repo app (`ci/deploy-template.gitlab-ci.yml`) | `dev`, `develop`, `feature/*` | `staging`, `release/*` | `main`, `master` (manual) |

## Terraform — `environments/<env>/terraform/`

| File | Key chính | Chi tiết |
|---|---|---|
| `environment.yaml` | `account.id`, `region.name`, `name_prefix`, `tags`, `release.image_tag_source` (`pipeline`/`config`), `release.promote_from` | [terraform/README → environment.yaml](../../terraform/README.md#environmentyaml) |
| `core.yaml` | `vpc`, `ecs.enabled`, `eks.*` (`addon_roles`, `access_entries`), `alb`, `dns`, `ecr.mirror_repositories`, `sops.kms_key`, `logs.retention_days`, `alerts.subscriptions` | [terraform/README → core.yaml](../../terraform/README.md#coreyaml) |
| `backend.yaml` | bucket/region của state | |

Trạng thái hiện tại (đọc từ các file trên):

| | dev | staging | production |
|---|---|---|---|
| `account.id`, backend bucket | **trống** (chưa plan được) | **trống** | **trống** |
| ECS / EKS | bật / bật | bật / bật | bật / bật |
| ALB / DNS zone | tắt / không | tắt / không | tắt / không |
| IRSA add-on roles | external-dns, cluster-autoscaler, velero | như dev | như dev |
| SOPS KMS key | không | không | có |
| Tag image deploy | `IMAGE_TAG` của pipeline | tag ghim trong `staging.yaml` | tag ghim trong `production.yaml` |
| Promote image từ | — | dev | staging |

## Kubernetes — `environments/<env>/kubernetes/`

| File | Ai đọc | Chứa |
|---|---|---|
| `environments.yaml` | mọi helmfile platform | `env`, `platformName`, `eksClusterName` (khớp tên Terraform), `namespace` (observability), `storageClass` (`""` = class mặc định), `ingressClass` (`nginx-<env>`), `ingressDomain` |
| `repositories.yaml` | mọi helmfile | chart repo + `helmDefaults` (`wait`, `timeout: 900`, `atomic: false`) |
| `<env>/secrets.enc.yaml` | helmfile platform | secret SOPS của platform (mật khẩu DB, MinIO…) — **không phải** secret của app |
| `app-values.yaml.gotmpl` | mọi app, mọi môi trường | securityContext cứng, ServiceAccount không mount token, NetworkPolicy mặc định |
| `<env>/app-values.yaml.gotmpl` | mọi app trong `<env>` | `global.imageRegistry` (ECR của môi trường), IngressClass, issuer, replica/HPA/PDB/resources theo tier, egress được phép |

`ingressDomain` hiện tại: dev `dev.example.com`, staging `staging.example.com`, prod `example.com` —
external-dns chỉ tạo bản ghi trong domain này, nên host của Ingress phải nằm trong nó.

App-values theo tier (tóm tắt; nguồn là file):

| | dev | staging | prod |
|---|---|---|---|
| `global.imageRegistry` | `<dev-account>.dkr.ecr.ap-southeast-1.amazonaws.com` (đang là `REPLACE_WITH_…`) | tương tự staging | tương tự production |
| Ingress class / issuer | `nginx-dev` / không đặt | `nginx-staging` / không đặt | `nginx-prod` / `letsencrypt-prod` |
| Replica / HPA | 1 / tắt | 2 / tắt (2–5 nếu bật) | 3 / 3–10 |
| Resources mặc định | 50m/128Mi, limit 300m/256Mi | 100m/256Mi, limit 500m/512Mi | 200m/512Mi, limit memory 1Gi |
| PDB | tắt | tắt | `maxUnavailable: 1` |
| NetworkPolicy ingress | từ `infra` (ingress-nginx) + cùng namespace | + `observability` (scrape 9090), cổng 8080/9090 | như staging |
| NetworkPolicy egress | không giới hạn | DNS, API server 443, `database` (5432, 6379, 9092, 9000), OTLP (4317/4318), HTTPS ra ngoài | như staging + 26379 (redis sentinel) |

Thứ tự các lớp này ghép với value của app: [`../app-onboarding.md`](../10-onboard-app.md#value-nào-đã-có-sẵn).
