# docs — lối vào

## Muốn làm gì → đọc gì

| Muốn | Đọc |
|---|---|
| Đưa một app mới lên (EKS hoặc ECS) | [`app-onboarding.md`](app-onboarding.md), rồi `make new-app APP=<tên> RUNTIME=eks\|ecs` |
| Biết base infra gồm gì, ai tạo, output là gì | [`platform-base.md`](platform-base.md) |
| Sửa value của base (sizing, retention, replica… của một tool) | [`../infra-base/README.md`](../infra-base/README.md) |
| Biết một key của chart `application` làm gì, mặc định bao nhiêu | [`reference/application-chart.md`](reference/application-chart.md) (sinh tự động) |
| Điền `app.yaml` / `<env>.yaml` cho app (ECS, hoặc ECR của app EKS) | [`reference/ecs-app.md`](reference/ecs-app.md) |
| Lệnh chạy từng phần, từng bước (Terraform → platform → app → local) | [`runbook.md`](runbook.md) |
| Cấu hình riêng cho một app, lệnh thủ công (render, local, Argo) | [`app-onboarding.md` §7](app-onboarding.md#7-tuỳ-biến-riêng-và-lệnh-thủ-công) |
| Biết môi trường đặt sẵn gì (registry, ingress, sizing, NetworkPolicy) | [`reference/env-values.md`](reference/env-values.md) |
| Deploy / rollback tầng platform k8s | [`../k8s/docs/DEPLOY.md`](../k8s/docs/DEPLOY.md), [`../k8s/README.md`](../k8s/README.md) |
| Pipeline: job nào, gate nào | [`../ci/README.md`](../ci/README.md) |
| Terraform: lớp, state, hợp đồng cấu hình | [`../terraform/README.md`](../terraform/README.md) |
| Xử lý sự cố k8s | [`../k8s/docs/TROUBLESHOOTING.md`](../k8s/docs/TROUBLESHOOTING.md) |

## Bản đồ repo

```text
infra-base/              VALUE của base (không có template) — xem infra-base/README.md
  terraform/environments/<env>/     cấu hình AWS mỗi môi trường
  k8s/env-values/                   giá trị chung môi trường, mặc định cho app, secret SOPS
  k8s/platform/<tool>/              value của tool: values.yaml.gotmpl + <env>/values.yaml.gotmpl
  k8s/monitoring/<tool>/            value của observability
applications/<app>/      VALUE của một app — terraform/ (ECR, ECS) và k8s/ (theo môi trường)
terraform/               TEMPLATE AWS: modules/ → stacks/core → registry → service; schema/
k8s/                     TEMPLATE Kubernetes: charts/application (chart chung), platform/<tool>/ (chart + version),
                         helmfile.yaml.gotmpl (thứ tự cài)
monitoring/              TEMPLATE observability (Prometheus, Grafana, Loki, Tempo, Mimir, Alloy, OTel)
argocd/                  ApplicationSet sinh Application cho mỗi app × môi trường
ci/                      pipeline repo này + deploy-template.gitlab-ci.yml cho repo app
local/                   cluster laptop (minikube)
docs/                    tài liệu này; templates/ (khung app); schemas/ + reference/ (sinh tự động)
```

## File sinh tự động

`reference/application-chart.md` và `schemas/application-values.overlay.schema.json` sinh từ
`k8s/charts/application/{values.yaml,values.schema.json}`. Đổi chart thì chạy
`make docs-reference`; `make docs-check` fail khi chúng cũ.
