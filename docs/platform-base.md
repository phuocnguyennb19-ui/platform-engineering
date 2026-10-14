# Base infra — ai tạo cái gì, output là gì, app dùng thế nào

App không tự tạo hạ tầng: app **dùng** base. Tài liệu này trả lời ba câu:
base gồm những gì, nằm ở đâu trong repo, và app nhận được gì từ nó.

```text
                      (mỗi môi trường: dev | staging | production)
terraform/stacks/core ─────────────┬──────────────────────────────┐
  VPC, subnet, SG                  │ remote state                 │ khớp theo TÊN
  EKS  platform-<env>-eks          ▼                              ▼ (không đọc state)
  ECS  platform-<env>-ecs     terraform/stacks/service       infra-base/k8s/env-values/environments.yaml
  IRSA <cluster>-irsa-<addon>   app ECS                        platformName, eksClusterName
  ALB/DNS/ACM (nếu bật)                                              │
  SNS cảnh báo, bucket Velero,                                       ▼
  KMS cho SOPS (prod)                                    k8s/platform/* + monitoring/*  (helmfile)
terraform/stacks/registry                                  ingress, cert, DNS, data, observability
  ECR cho mỗi image.repository + mirror bitnami                      │
                                                                     ▼
                                                     argocd/ ApplicationSet → app EKS
```

Thứ tự dựng một môi trường: `core` → `registry` → platform k8s (`helmfile -e <env> -l layer=platform`) → app.

## 1. Tầng AWS — `terraform/stacks/core` (dùng chung mọi app)

Cấu hình: `infra-base/terraform/environments/<env>/core.yaml` ([tham chiếu](reference/env-values.md#terraform--terraformenvironmentsenv)).
State: `<env>/core/core.tfstate`. Chạy qua CI (`ci/terraform/platform.yml`), không chạy tay.

Output (nguồn: [`terraform/stacks/core/outputs.tf`](../terraform/stacks/core/outputs.tf)):

| Output | Giá trị | Ai dùng |
|---|---|---|
| `environment`, `name` | `<env>`, `platform-<env>` | mọi stack; tiền tố tên tài nguyên |
| `vpc_id`, `private_subnet_ids`, `public_subnet_ids` | VPC | **service** (ECS chạy ở private subnet) |
| `ecs_enabled`, `ecs_cluster_arn`, `ecs_cluster_name` | cluster `platform-<env>-ecs` | **service** |
| `ecs_security_group_id` | SG của task ECS | **service** |
| `enable_execute_command` | `ecs.enable_execute_command` | **service** |
| `eks_enabled`, `eks_cluster_name`, `eks_cluster_endpoint`, `eks_cluster_certificate_authority_data` | cluster `platform-<env>-eks` | CI (`aws eks update-kubeconfig`), k8s/ khớp theo tên |
| `addon_role_arns` | IRSA role `<cluster>-irsa-<addon>` cho external-dns, cluster-autoscaler, velero | k8s/platform (dựng ARN theo tên + `AWS_ACCOUNT_ID`) |
| `velero_bucket` | `platform-<env>-velero-<account>` | k8s/platform/velero (dựng theo tên) |
| `sops_kms_key_arn` | KMS key (prod) | `.sops.yaml` |
| `alb_arn`, `alb_dns_name`, `alb_zone_id`, `alb_security_group_id`, `alb_listener_arn`, `alb_https_listener_arn`, `alb_target_ports` | ALB chung (khi `alb.enabled`) | **service** (listener rule + target group của app ECS) |
| `certificate_arn`, `dns_zone_name`, `route53_zone_id` | ACM + Route53 (khi có `dns`) | **service** (bản ghi alias cho host của app) |
| `alarm_topic_arn` | SNS cảnh báo | CloudWatch alarm |
| `log_retention_days` | mặc định 90 | **service** (log group của app) |

`terraform/stacks/registry` → `repository_urls`, `repository_names`, `repository_arns`, `registry_id`:
một repo ECR cho mỗi `image.repository` của app được bật trong môi trường đó, cộng các repo
mirror `bitnami/*` mà platform k8s kéo image từ đó.

Xem giá trị thật: chỉ trong CI (job `plan:*` có quyền đọc state). Hiện `account.id` và bucket
backend của cả ba môi trường đều **trống**, nên chưa có state và chưa có output nào tồn tại.

**Đang tắt ở mọi môi trường:** `alb` và `dns`. App ECS chạy nhưng chưa có đường vào từ ngoài;
đặt `network` trong file của app thì plan fail.

## 2. Tầng platform k8s — `k8s/platform/*`, `monitoring/*`

Cài bằng helmfile theo thứ tự trong [`k8s/helmfile.yaml.gotmpl`](../k8s/helmfile.yaml.gotmpl),
value của từng tool ở [`infra-base/k8s/platform/<tool>/`](../infra-base/README.md) (chung + `<env>/`),
giá trị theo môi trường ở [`infra-base/k8s/env-values/`](../infra-base/k8s/env-values/). k8s **không đọc** state
Terraform: nó khớp theo tên (`eksClusterName`, `platformName` trong `environments.yaml`) và
`AWS_ACCOUNT_ID` do CI cấp. Đổi tên ở một bên mà không đổi bên kia là hỏng.

Những gì một app EKS được cấp:

| Nhu cầu | Platform cung cấp | Dùng trong value của app |
|---|---|---|
| Namespace | `dev`, `staging`, `prod` (PSA `restricted`, `k8s/platform/bootstrap`) | Argo CD đặt theo môi trường |
| Image registry | ECR của môi trường | `global.imageRegistry` đã đặt sẵn; app chỉ ghi `image.repository` + tag |
| HTTP vào | ingress-nginx, IngressClass `nginx-<env>`, NLB | `ingress.hosts` (class đã đặt sẵn) |
| DNS | external-dns → Route53, chỉ trong `ingressDomain` (`dev.example.com`, `staging.example.com`, `example.com`) | host của Ingress phải nằm trong domain đó |
| TLS | cert-manager, ClusterIssuer `letsencrypt-staging`, `letsencrypt-prod` | `ingress.tls` + annotation `cert-manager.io/cluster-issuer` (prod đã đặt sẵn) |
| PostgreSQL | dev/staging: `postgresql.database.svc:5432`; prod: `postgresql-primary` (ghi), `postgresql-read` (đọc) | biến môi trường của app |
| Redis | dev/staging: `redis-master.database.svc:6379`; prod: `redis.database.svc:6379` + sentinel `26379` | |
| Kafka | `kafka.database.svc:9092` | |
| Object storage (S3 API) | MinIO `minio.database.svc:9000` | |
| ClickHouse | `clickhouse.database.svc:8123` (HTTP), `:9000` (native) | |
| Trace | OTLP `opentelemetry-collector.observability.svc:4317` (gRPC) / `:4318` (HTTP) | `env.OTEL_EXPORTER_OTLP_ENDPOINT` |
| Metric | Prometheus scrape ServiceMonitor có label `release: kube-prometheus-stack` | `serviceMonitor.labels` |
| Log | stdout → Alloy → Loki | không cần cấu hình |
| Secret của app | Secret tên `<app>` trong namespace (External Secrets / SealedSecrets) | `extraEnvFrom: [{secretRef: {name: <app>}}]` |
| Chính sách | Kyverno (cấm tag `latest`, yêu cầu requests/limits…), NetworkPolicy mặc định | xem [env-values](reference/env-values.md#kubernetes--k8senv-values) |

Tên service lấy từ render thật của platform; prod khác dev/staging ở PostgreSQL (replication)
và Redis (sentinel).

**Chưa có, cần biết trước khi onboard:**
- Chưa có `ClusterSecretStore` thật (chỉ `k8s/platform/external-secrets/manifests/example-secretstore.yaml`), nên Secret `<app>` hiện phải tạo bằng SealedSecrets hoặc bổ sung store.
- User/database riêng cho từng app trong PostgreSQL chưa có quy trình tạo; mật khẩu platform nằm trong SOPS của platform, không cấp cho app.
- Dev: NetworkPolicy chưa cho `observability` vào, nên Prometheus không scrape được app ở dev.
- Đường deploy app qua CI (`deploy:apply`) đang có lỗi đã biết (review §H1, §H2). Argo CD là đường deploy app thực tế.

## 3. App ECS — `terraform/stacks/service`

Mỗi app một state `<env>/services/<app>.tfstate`. Service đọc output `core` + `registry` qua
remote state và tạo cho app: ECS service `platform-<env>-<app>`, task definition (image từ ECR,
`environment`, `secrets` theo ARN), log group (retention theo core), và nếu có `network` +
core bật `alb`: target group, listener rule, bản ghi Route53.

Output: `application`, `runtime`, `image`, `image_digest`, `ecs_service_name`,
`ecs_task_definition_arn`, `route`.

App ECS **không** dùng được các dịch vụ trong cluster EKS (PostgreSQL, Redis… ở namespace
`database`): chúng là Service `ClusterIP`, chỉ truy cập được từ trong cluster.

## 4. On-prem

Thiết kế target on-prem (cùng platform k8s, không có tầng Terraform) nằm trong change set
chưa áp: `.ai/architecture/hybrid-platform.md` sau khi áp `hybrid.patch`.
