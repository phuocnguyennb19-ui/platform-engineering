# 0001 — Tách template và value

- Status: Accepted
- Date: 2026-10-21

## Bối cảnh

Chart, helmfile và module Terraform được dùng bởi nhiều môi trường và nhiều app. Khi value nằm lẫn
trong template, sửa cấu hình một môi trường dễ vô tình đổi template của mọi môi trường.

## Quyết định

- Template: `terraform/`, `kubernetes/` (chart, release, Argo CD), `ci/`.
- Value: `environments/<env>/` (base: AWS + platform trên cluster), `applications/` (app).
- Template không chứa tên môi trường hay giá trị riêng của môi trường; value không chứa logic dựng.

## Hệ quả

- Blast radius đọc được từ đường dẫn: sửa `kubernetes/charts/application` ảnh hưởng mọi app; sửa
  `environments/prod/kubernetes/` chỉ ảnh hưởng prod.
- Một thay đổi tính năng thường chạm cả hai: template (thêm khả năng) và value (bật nó).
