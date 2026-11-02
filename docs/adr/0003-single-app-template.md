# 0003 — Một khuôn app duy nhất

- Status: Accepted
- Date: 2026-10-21

## Bối cảnh

Khuôn app từng nằm ở nhiều chỗ (`docs/templates/eks-app`, `docs/templates/ecs-app`, mảnh rời trong
`docs/tools`), và người mới hay copy một app có sẵn — kéo theo cả cấu hình riêng của app đó.

## Quyết định

- Khuôn duy nhất: `applications/_template/` — `k8s/<env>/values.yaml` (EKS), `terraform/` (ECR của
  app EKS), `terraform-ecs/` (ECS). Tạo app: `make new-app APP=<tên> RUNTIME=eks|ecs`.
- `k8s/<env>/values.yaml` của khuôn chứa **mọi key** của chart, đang bật, với đúng giá trị app nhận ở
  môi trường đó; chia block theo thành phần, mỗi block một dòng note. Sinh bởi
  `scripts/docs/gen-app-template.sh` (`make docs-reference`), kiểm bởi `make docs-check`.
- Folder bắt đầu bằng `_` không phải app: Helmfile, Argo CD và Terraform đều bỏ qua.

## Hệ quả

- App mới render giống hệt một app chỉ khai báo phần riêng của nó.
- App giữ bản sao giá trị nền tại lúc tạo: đổi `environments/<env>/kubernetes/app-values.yaml.gotmpl` sau đó
  không tự đổi theo trong app đã tạo.
