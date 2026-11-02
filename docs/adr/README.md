# Architecture Decision Records

Mỗi file ghi **một** quyết định đã chốt: bối cảnh, quyết định, hệ quả. Đề xuất đổi một quyết định
thì viết ADR mới đánh dấu `Supersedes: NNNN`, không sửa ADR cũ.

| # | Quyết định | Trạng thái |
|---|---|---|
| [0001](0001-template-value-split.md) | Tách template và value | Accepted |
| [0002](0002-no-shared-value-layer.md) | Value theo môi trường, mỗi môi trường một folder đầy đủ, không có lớp chung | Accepted |
| [0003](0003-single-app-template.md) | Một khuôn app duy nhất: `applications/_template` | Accepted |
| [0004](0004-namespaces-and-network-per-environment.md) | Namespace và NetworkPolicy nằm trong value của môi trường | Accepted |
| [0005](0005-environments-folder.md) | Một folder `environments/<env>/` cho cả Kubernetes và Terraform | Accepted |

Khuôn cho ADR mới:

```markdown
# NNNN — <tiêu đề>
- Status: Proposed | Accepted | Superseded by NNNN
- Date: YYYY-MM-DD
## Bối cảnh
## Quyết định
## Hệ quả (được gì, mất gì, ai bị ảnh hưởng)
```
