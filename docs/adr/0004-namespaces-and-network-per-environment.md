# 0004 — Namespace và NetworkPolicy nằm trong value của môi trường

- Status: Accepted
- Date: 2026-10-21

## Bối cảnh

Namespace (nhãn PSA) và NetworkPolicy nền là manifest `kubectl`, không thuộc release Helm nào: release
sở hữu namespace thì `helm uninstall` sẽ xoá cả namespace. Trước đây một file tạo cả `dev`, `staging`,
`prod` trên mọi cluster, dù mỗi môi trường là một cluster riêng.

## Quyết định

- `environments/<env>/kubernetes/namespace/namespaces.yaml`: namespace platform + đúng namespace `<env>`.
- `environments/<env>/kubernetes/network/`: NetworkPolicy của namespace platform và namespace `<env>`.
- Thứ tự dựng: namespace → `helmfile -e <env> sync` → NetworkPolicy; mọi lệnh ghi rõ `--context`.
- Tài liệu: `kubernetes/docs/NAMESPACES.md`, `kubernetes/docs/NETWORK-POLICIES.md`.

## Hệ quả

- Cluster của một môi trường không còn namespace của môi trường khác.
- NetworkPolicy chỉ có tác dụng khi CNI thực thi nó (EKS: VPC CNI với network policy bật; local:
  Calico/Cilium) — không thuộc repo này quyết định.
