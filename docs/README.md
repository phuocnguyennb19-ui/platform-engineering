# docs — lối vào

## Đọc theo thứ tự (người mới)

| # | Trang | Để biết |
|---|---|---|
| 00 | [`00-start-here.md`](00-start-here.md) | template vs value, môi trường, các lớp, luồng deploy, 5 quy tắc |
| 01 | [`01-platform-base.md`](01-platform-base.md) | base infra gồm gì, ai tạo, output là gì |
| 02 | [`02-local-setup.md`](02-local-setup.md) | công cụ, kiểm tra offline, age key, cluster local |
| 03 | [`03-values-mapping.md`](03-values-mapping.md) | value của từng lớp ở đâu, thứ tự ghép, cluster đích lấy từ đâu, xem value cuối |
| 10 | [`10-onboard-app.md`](10-onboard-app.md) | đưa một app mới lên (EKS hoặc ECS) |
| 20 | [`20-runbooks/platform.md`](20-runbooks/platform.md) | lệnh chạy từng phần: Terraform → platform → app |
| 20 | [`20-runbooks/local-docker-desktop.md`](20-runbooks/local-docker-desktop.md) | deploy lên Docker Desktop Kubernetes, từng lệnh: namespace → CRD → cert-manager → metrics-server → kong → app → gỡ sạch |
| 20 | [`20-runbooks/local-cluster-kubeadm.md`](20-runbooks/local-cluster-kubeadm.md) | tạo cluster local từ đầu: VM Lima → `kubeadm init` → join worker → Calico → deploy, từng bước |
| 20 | [`20-runbooks/kubernetes-manual.md`](20-runbooks/kubernetes-manual.md) | deploy tay bằng kubectl/helm/helmfile: Infra Base → Platform → Application, verify, rollback, gỡ |
| — | [`adr/`](adr/README.md) | vì sao repo được sắp như vậy |

## Muốn làm gì → đọc gì

| Muốn | Đọc |
|---|---|
| Đưa một app mới lên | [`10-onboard-app.md`](10-onboard-app.md), rồi `make new-app APP=<tên> RUNTIME=eks\|ecs` |
| Sửa value của base (sizing, retention, replica… của một tool) | [`../environments/README.md`](../environments/README.md) |
| Biết một key của chart `application` làm gì, mặc định bao nhiêu | [`reference/application-chart.md`](reference/application-chart.md) (sinh tự động) |
| Điền `app.yaml` / `<env>.yaml` cho app (ECS, hoặc ECR của app EKS) | [`reference/ecs-app.md`](reference/ecs-app.md) |
| Cấu hình riêng cho một app, lệnh thủ công | [`10-onboard-app.md` §7](10-onboard-app.md#7-tuỳ-biến-riêng-và-lệnh-thủ-công) |
| Biết môi trường đặt sẵn gì (registry, ingress, sizing, NetworkPolicy) | [`reference/env-values.md`](reference/env-values.md) |
| Chuẩn bị / kiểm tra một cluster (Docker Desktop, K3s, EKS) | [`clusters/README.md`](clusters/README.md) |
| Deploy / rollback tay (namespace, platform, app) | [`20-runbooks/kubernetes-manual.md`](20-runbooks/kubernetes-manual.md); chi tiết từng tool: [`../kubernetes/docs/DEPLOY.md`](../kubernetes/docs/DEPLOY.md) |
| Value nào thắng khi hai file cùng đặt một key | [`03-values-mapping.md`](03-values-mapping.md) |
| Pipeline: job nào, gate nào | [`../ci/README.md`](../ci/README.md) |
| Terraform: lớp, state, hợp đồng cấu hình | [`../terraform/README.md`](../terraform/README.md) |
| Xử lý sự cố k8s | [`../kubernetes/docs/TROUBLESHOOTING.md`](../kubernetes/docs/TROUBLESHOOTING.md) |
| Một script làm gì | [`../scripts/README.md`](../scripts/README.md) |

## Bản đồ repo

```text
environments/<dev|staging|prod>/   VALUE của base, mỗi môi trường một folder đầy đủ:
  kubernetes/            state.yaml, cluster/, namespace/, network/, tools|ingress|monitoring/<tool>/, app-values, secrets.enc.yaml
  terraform/             environment.yaml, core.yaml, backend.yaml (Terraform gọi prod là production)
applications/<app>/      VALUE của một app — terraform/ (ECR, ECS) và k8s/ (theo môi trường); _template/ = khuôn
terraform/               TEMPLATE AWS: modules/ → stacks/core → registry → service; schema/
kubernetes/              TEMPLATE Kubernetes: charts/application (chart chung), releases/platform|observability/<tool>/
                         (chart + version), argocd/, helmfile.yaml.gotmpl (thứ tự cài)
ci/                      pipeline repo này + deploy-template.gitlab-ci.yml cho repo app
docs/                    tài liệu này (đánh số theo thứ tự đọc); clusters/; adr/; schemas/ + reference/ (sinh tự động)
scripts/                 công cụ: cluster/ (preflight), deploy/ (release-guard), docs/ (generator)
```

## File sinh tự động

`reference/application-chart.md` và `schemas/application-values.overlay.schema.json` sinh từ
`kubernetes/charts/application/{values.yaml,values.schema.json}`. Đổi chart thì chạy
`make docs-reference`; `make docs-check` fail khi chúng cũ.
