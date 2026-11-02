# applications — value của từng app

| | |
|---|---|
| **Chứa gì** | Một folder mỗi app: `k8s/<dev\|staging\|prod>/values.yaml` (value đầy đủ cho chart `kubernetes/charts/application`) và `terraform/` (ECR của app EKS, hoặc service ECS). `_template/` là khuôn duy nhất. |
| **Owner** | app team (app của mình) · platform team (`_template/`, `helmfile.yaml.gotmpl`) |
| **Sửa thế nào** | App mới: `make new-app APP=<tên> RUNTIME=eks\|ecs` — không copy app khác. Đổi cấu hình: sửa file của đúng môi trường. |
| **Validate** | `make app-render APP=<tên> ENV=<env>` · `make argocd-render` · deploy: `helmfile -e <env> -l name=<tên> diff` |

```text
applications/
├── helmfile.yaml.gotmpl     sinh một release cho mỗi <app>/k8s/<env>/values.yaml (không khai báo tay)
├── _template/               khuôn (folder bắt đầu bằng `_` không phải app)
│   ├── k8s/<env>/values.yaml   mọi key của chart — SINH TỰ ĐỘNG (make docs-reference)
│   ├── terraform/              EKS: app.yaml + <env>.yaml (ECR)
│   └── terraform-ecs/          ECS
└── <app>/
    ├── k8s/<env>/values.yaml
    └── terraform/
```

Thứ tự ghép value của một app: mặc định của chart → `environments/<env>/kubernetes/app-values.yaml.gotmpl`
→ `<app>/k8s/<env>/values.yaml`. Hướng dẫn đầy đủ: [`docs/10-onboard-app.md`](../docs/10-onboard-app.md).
