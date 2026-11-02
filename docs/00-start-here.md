# 00 — Bắt đầu từ đây

Đọc trang này trước mọi trang khác (khoảng 10 phút). Nó giải thích 5 khái niệm mà cả repo dựa vào;
hiểu chúng thì mọi folder còn lại tự giải thích được.

## 1. Template và value

| | Là gì | Ở đâu | Ai thường sửa |
|---|---|---|---|
| **Template** | *cách* dựng: chart Helm, helmfile release, module/stack Terraform, pipeline | `terraform/`, `kubernetes/`, `ci/` | platform team |
| **Value** | *giá trị* đổ vào template: sizing, domain, image, bật/tắt tính năng | `environments/` (của base, mỗi môi trường một folder), `applications/` (của app) | platform team / app team |

Quy tắc: thêm một tính năng là sửa **template**; cấu hình một môi trường hay một app là sửa **value**.
Sửa template ảnh hưởng mọi nơi dùng nó — ví dụ `kubernetes/charts/application` là chart của **mọi** app.

## 2. Môi trường

Ba môi trường, mỗi môi trường một AWS account và một EKS cluster riêng:

| | dev | staging | prod |
|---|---|---|---|
| Tên trong Helm / namespace / folder `environments/<env>/kubernetes/` | `dev` | `staging` | `prod` |
| Tên trong Terraform (`ENVIRONMENT`) | `dev` | `staging` | `production` |
| Deploy | tự do (vẫn qua guard) | cần duyệt | cần duyệt + `CONFIRM_DEPLOY=<app>@prod` |

`prod` (Helm) và `production` (Terraform) **không** thay cho nhau được — đừng đổi tên bên nào.

Mỗi môi trường là **một folder đầy đủ**: `environments/<env>/kubernetes/` chứa toàn bộ value của môi trường đó
(không có lớp chung) — xem [ADR 0002](adr/0002-no-shared-value-layer.md).

## 3. Các lớp, từ dưới lên

```text
AWS (Terraform: VPC, EKS, IAM, ECR)          terraform/stacks/core → registry → service
  └─ Platform trên cluster (Helm)            kubernetes/releases/{platform,observability}/<tool>   ← value: environments/<env>/kubernetes/
       namespace + NetworkPolicy (kubectl)                                           ← environments/<env>/kubernetes/{namespace,network}/
       └─ App (chart application)            applications/<app>/k8s/<env>/values.yaml
```

Một app **dùng** những gì base đã có (ingress controller, namespace, NetworkPolicy, monitoring) —
không tự tạo lại.

## 4. Luồng deploy một app

```bash
make new-app APP=<tên> RUNTIME=eks        # khuôn từ applications/_template
helmfile -e dev -l name=<tên> diff        # từ thư mục gốc repo: xem thay đổi
helmfile -e dev -l name=<tên> sync        # deploy — guard kiểm tra trước (scripts/deploy/release-guard.sh)
```

Cluster đích lấy từ `environments/<env>/kubernetes/cluster/target.yaml` (máy cá nhân: `target.local.yaml`).
`make new-app` chỉ tạo khung; mọi lệnh kiểm tra và deploy là `kubectl`/`helm`/`helmfile` gõ trực tiếp —
[`20-runbooks/kubernetes-manual.md`](20-runbooks/kubernetes-manual.md). Value ghép thế nào: [`03-values-mapping.md`](03-values-mapping.md).

## 5. Năm quy tắc không được phá

1. Không deploy khi chưa `diff`; không bao giờ `helmfile sync` thiếu `-l name=<app>` (guard sẽ chặn).
2. Không in, giải mã hay commit secret (`secrets.enc.yaml`, kubeconfig, age key).
3. Không nới IAM / RBAC / NetworkPolicy / security context chỉ để "cho chạy được".
4. Lệnh lên cluster luôn ghi rõ `--context=<ctx>` / `-e <env>`; không dựa vào context đang chọn.
5. File **sinh tự động** (`docs/reference/`, `docs/schemas/`, `applications/_template/k8s/`) không sửa tay —
   chạy `make docs-reference`.

## Đọc tiếp

[`01-platform-base.md`](01-platform-base.md) → [`02-local-setup.md`](02-local-setup.md) →
[`03-values-mapping.md`](03-values-mapping.md) → [`10-onboard-app.md`](10-onboard-app.md) → [`20-runbooks/`](20-runbooks/platform.md).
Vì sao repo được sắp như thế này: [`adr/`](adr/README.md).
