# scripts — công cụ của repo

| | |
|---|---|
| **Chứa gì** | Mọi script dùng bởi `Makefile`, CI và hook helmfile — không có value, không có template. |
| **Owner** | platform team (`deploy/` cần thêm security review — CODEOWNERS) |
| **Sửa thế nào** | Gọi qua `make` khi có target; script chạy từ thư mục gốc repo. |
| **Validate** | `make k8s-env-test` (cluster) · `make docs-check` (docs) · `bash -n <file>` |

```text
scripts/
├── cluster/                 metadata cluster + preflight CHỈ ĐỌC (make k8s-preflight CLUSTER=…)
│   ├── preflight.sh         kiểm tra cluster thật: chỉ get/list/auth can-i, luôn --context
│   ├── check-metadata.sh    luật offline của environments/<env>/kubernetes/cluster/*.yaml
│   ├── lib/metadata.sh      đọc YAML dùng chung cho hai script trên
│   ├── schemas/             JSON Schema của <cluster>.yaml và environment.yaml
│   └── tests/               preflight chạy với kubectl giả (make k8s-env-test)
├── deploy/
│   └── release-guard.sh     hook trước mọi install/upgrade/uninstall app (applications/helmfile.yaml.gotmpl)
└── docs/                    sinh file tự động (make docs-reference) + xem value cuối của app
    ├── gen-chart-reference.sh   docs/reference/application-chart.md + docs/schemas/
    ├── gen-app-template.sh      applications/_template/k8s/<env>/values.yaml
    ├── eks-app-values.base.yaml, eks-app-env/   phần riêng của app trong khuôn
    ├── gen-app-values.py, strip-notes.py         in mọi key của chart cho một file value
    ├── app-values.sh            value cuối của một app (make app-values)
    └── check-argocd-layers.sh   lớp value của Argo CD = của helmfile
```
