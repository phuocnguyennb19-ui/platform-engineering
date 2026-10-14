# Tham chiếu — `applications/<app>/terraform/*.yaml`

Mỗi app có thư mục `applications/<app>/terraform/`. Terraform (`terraform/stacks/registry`,
`terraform/stacks/service`) đọc các file này, không ai sửa Terraform cho một app.

| File | Nghĩa | Schema |
|---|---|---|
| `app.yaml` | thứ không đổi theo môi trường | [`terraform/schema/app.schema.json`](../../terraform/schema/app.schema.json) |
| `dev.yaml`, `staging.yaml`, `production.yaml` | ghi đè theo môi trường; **có file = app được bật ở môi trường đó** | [`terraform/schema/app-environment.schema.json`](../../terraform/schema/app-environment.schema.json) |

Tên file môi trường là tên **Terraform**: `production`, không phải `prod` (`prd.yaml` bị từ chối).
Khung có sẵn: `make new-app APP=<tên> RUNTIME=ecs|eks` (từ [`docs/templates/`](../templates/)).
Kiểm tra: `make stacks-lint stacks-config` (yamllint + schema; cần `yamllint`, `check-jsonschema`).

## `app.yaml`

| Key | Bắt buộc | Kiểu / ràng buộc | Ý nghĩa |
|---|---|---|---|
| `application.name` | ✅ | `^[a-z0-9][a-z0-9-]{0,62}$`, **trùng tên thư mục** | tên app; ECS service là `platform-<env>-<name>` |
| `runtime.type` | ✅ | `ecs` \| `eks` | `ecs`: stacks/service deploy lên ECS. `eks`: Terraform **chỉ tạo ECR**, k8s/ (Argo CD) deploy |
| `image.repository` | ✅ | tên repo ECR (chữ thường, `.`/`_`/`-`, có thể có `/`) | khai báo **duy nhất ở đây**; registry tạo repo này |
| `image.tag` | | `^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$`, không được `latest` | thường đặt theo môi trường, không đặt ở đây |
| `container.port` | ✅ (ecs) | 1–65535 | cổng container; với ALB phải là 8080 hoặc trong `alb.target_port_range` của core |
| `container.health_check_command` | | list string, ≥ 1 phần tử | health check của container ECS, vd `["CMD", "/server", "-healthcheck"]` |
| `container.health_check_path` | | bắt đầu bằng `/` | health check của target group ALB (mặc định `/`) |
| `container.readonly_root_filesystem` | | bool | root filesystem chỉ đọc |
| `network` | | xem [network](#network) | định tuyến ALB; có thể đặt ở đây hoặc theo môi trường |

Bị từ chối trong `app.yaml` (vì là theo môi trường): `resources`, `deployment`, `environment`, `secrets`, `cpu`, `memory`, `replicas`.

## `<env>.yaml`

| Key | Bắt buộc | Kiểu / ràng buộc | Ý nghĩa |
|---|---|---|---|
| `resources.cpu` | ✅ ecs | số nguyên ≥ 64; 1024 = 1 vCPU | phải là cặp CPU/memory hợp lệ của Fargate |
| `resources.memory` | ✅ ecs | số nguyên MiB ≥ 64 | |
| `deployment.replicas` | ✅ ecs | số nguyên ≥ 1 | số task |
| `deployment.autoscaling.min`, `.max` | | số nguyên ≥ 1 | có thì bật autoscaling |
| `image.tag` | theo môi trường | như trên | **bắt buộc ở staging/production** (`release.image_tag_source: config`); dev lấy `IMAGE_TAG` của pipeline |
| `environment` | | map `TÊN: string/number/bool`, tên `^[A-Za-z_][A-Za-z0-9_]*$` | biến thường — **không bao giờ là credential** |
| `secrets` | | map `TÊN: ARN` của Secrets Manager hoặc SSM parameter | ECS nạp lúc chạy; giá trị không nằm trong Git |
| `runtime`, `container`, `network` | | như `app.yaml` | ghi đè `app.yaml` |

Với app `eks`, file môi trường có thể chỉ là `{}`: sự có mặt của nó tạo repo ECR ở môi trường đó.
`application` và `image.repository` bị từ chối trong file môi trường.

## `network`

Chỉ cho app `ecs`; app `eks` định tuyến bằng Ingress của chart.

| Key | Ràng buộc | Ý nghĩa |
|---|---|---|
| `network.host` | DNS chữ thường; bắt buộc khi có `network` | host của listener rule |
| `network.path` | `/` hoặc `/a/b`; mặc định `/` | `/api` khớp `/api` và `/api/*` |
| `network.priority` | 1–9999 | bắt buộc khi hai app dùng chung host; không đặt thì hash vào 10000–49999 |

**Hiện tại `alb.enabled: false` ở cả dev, staging, production** (`infra-base/terraform/environments/*/core.yaml`):
đặt `network` thì plan fail. App ECS hiện chỉ chạy nội bộ (private subnet, không có route vào)
cho tới khi core bật `alb` (và `dns` nếu ALB public).

## Ghép `app.yaml` + `<env>.yaml`

Bởi `terraform/shared/deep-merge`: giá trị môi trường thắng; map gộp theo key (tối đa 4 cấp);
list và scalar bị **thay thế**, không nối thêm; `null` trong `<env>.yaml` = "không đặt", giữ giá trị `app.yaml`.

## Ví dụ đầy đủ

[`docs/templates/ecs-app/terraform/`](../templates/ecs-app/terraform/) (ECS) và
[`applications/frontend-html/terraform/`](../../applications/frontend-html/terraform/) (ECR của một app EKS).
Hợp đồng gốc (tiếng Anh): [`terraform/README.md` → Configuration contract](../../terraform/README.md#configuration-contract).
