# 02 — Chuẩn bị máy

Mục tiêu: chạy được mọi kiểm tra offline, rồi (tuỳ chọn) có một cluster local để thử app ở môi trường `dev`.

## 1. Công cụ

| Công cụ | Dùng cho | Phiên bản |
|---|---|---|
| `helm` + plugin `helm-secrets`, `helm-diff` | render, diff, giải mã SOPS khi render | như CI: `HELM_VERSION` trong [`ci/images/Dockerfile.ci`](../ci/images/Dockerfile.ci) |
| `helmfile` | thứ tự release, value theo môi trường | bản trong image CI |
| `kubectl` | manifest namespace / NetworkPolicy, kiểm tra cluster | lệch tối đa 1 minor so với cluster |
| `yq` v4 (mikefarah) | script trong `scripts/` | v4 |
| `sops` + `age` | secret của platform | — |
| `terraform` | `make stacks-validate` | **≥ 1.10** (module test: ≥ 1.7) |
| tuỳ chọn: `yamllint`, `check-jsonschema`, `shellcheck`, `kubeconform`, `gitleaks` | các check còn lại của CI | `ci/terraform/requirements.txt` |

Thiếu công cụ nào thì target `make` tương ứng báo thiếu — không giả lập kết quả.

## 2. Kiểm tra offline (không cần cloud, không cần key)

```bash
make help          # mọi target
make validate      # chart, render app, SOPS shape, cluster metadata, terraform fmt
make docs-check    # file sinh tự động còn khớp chart không
```

## 3. Secret (age key)

Render platform cần age key **của đúng môi trường** — xin platform lead, đặt ở
`~/.config/sops/age/keys.txt`, không bao giờ commit hay gửi qua chat. App không cần key.

## 4. Cluster local (tuỳ chọn)

1. Tạo cluster theo [`clusters/providers/`](clusters/providers/) (Docker Desktop, K3s, self-managed).
   Muốn NetworkPolicy có tác dụng thì cần CNI thực thi nó (Calico/Cilium) — CNI mặc định của
   Docker Desktop thì không.
2. Trỏ `dev` về cluster đó trên máy bạn (file gitignored):
   ```yaml
   # environments/dev/kubernetes/cluster/target.local.yaml
   schema: kubernetes-target/v1alpha1
   cluster: docker-desktop-dev
   ```
3. Kiểm tra chỉ-đọc: `make k8s-preflight CLUSTER=docker-desktop-dev`.
4. Dựng base của `dev` theo thứ tự trong [`../environments/README.md`](../environments/README.md), rồi
   `helmfile -e dev -l name=<app> diff` → `sync`.

Chi tiết và xử lý lỗi: [`clusters/README.md`](clusters/README.md).
