# 0005 — Một folder `environments/<env>/` cho cả Kubernetes và Terraform

- Status: Accepted
- Date: 2026-10-21

## Bối cảnh

Value của base nằm rải ở `infra-base/k8s/<env>/`, `infra-base/terraform/environments/<env>/` và metadata
cluster ở `infras/kubernetes/`. Người mới phải ghép nhiều chỗ để biết một môi trường gồm gì.

## Quyết định

- `environments/<dev|staging|prod>/` chứa mọi value của môi trường: `kubernetes/` (state helmfile, cluster
  đích, namespace, NetworkPolicy, value của tool, mặc định app, secret SOPS) và `terraform/`
  (`environment.yaml`, `core.yaml`, `backend.yaml`).
- Template ở `kubernetes/` (chart, release `releases/{platform,observability}/<tool>/`, Argo CD) và
  `terraform/`; công cụ ở `scripts/`.
- Folder mang tên Helm. Terraform vẫn gọi môi trường là `production`: `terraform/shared/config` chọn folder
  theo trường `environment:` của `environment.yaml`; CI ánh xạ `production` → `prod` ở một chỗ. State key
  (`production/...`) không đổi.

Chuyển đổi được kiểm chứng offline: output của `terraform/shared/config` cho dev, staging, production (có và
không có app) giống hệt trước khi chuyển; `terraform test` 22/22; `terraform validate` cả 3 stack; value đã gộp
của 32 release platform × 3 môi trường và render của mọi app không đổi.

## Hệ quả

- Một môi trường = một folder; CODEOWNERS bảo vệ `environments/prod/` cả hai phần.
- Đường dẫn trong Argo CD (`kubernetes/argocd/`, `kubernetes/charts/application`) đổi: một Argo CD đang chạy
  phải sync lại `root-app` sau khi merge (hiện app tier do Helmfile sở hữu, Argo CD chưa chạy).
