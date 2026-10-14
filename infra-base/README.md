# infra-base — giá trị của base infra

Thư mục này **chỉ chứa value**. Template nằm ở chỗ khác: chart và helmfile release ở `k8s/` và
`monitoring/`, module/stack Terraform ở `terraform/`. Value ở đây được map vào template đó, giống như
`applications/<app>/` là value của app được map vào chart `application`.

```text
infra-base/
  k8s/
    env-values/                  giá trị chung của môi trường (state helmfile + mặc định cho mọi app)
      environments.yaml          env, platformName, eksClusterName, ingressDomain, storageClass…
      repositories.yaml          chart repo + helmDefaults
      app-values.yaml.gotmpl     mặc định cho mọi app, mọi môi trường
      <env>/app-values.yaml.gotmpl   mặc định cho mọi app trong <env> (registry, sizing, egress)
      <env>/secrets.enc.yaml     secret SOPS của platform
      onprem-<env>/app-values.yaml.gotmpl   lớp on-prem cho app (registry, issuer)
    platform/<tool>/             value của một tool platform (chart: k8s/platform/<tool>/helmfile.yaml.gotmpl)
      values.yaml.gotmpl         giống nhau ở mọi môi trường
      dev/ staging/ prod/        values.yaml.gotmpl — chỉ những gì khác theo môi trường
      files/                     file cấu hình đọc bằng readFile (redis.conf, pg_hba.conf…)
    monitoring/<tool>/           tương tự, cho observability (chart: monitoring/<tool>/helmfile.yaml.gotmpl)
      <tool có nhiều file>       vd kube-prometheus-stack: values, prometheus, scrape-configs, alertmanager
    monitoring/prometheus-rules/ rule cảnh báo platform (platform.yaml.gotmpl + <env>/)
  terraform/
    environments/<env>/          environment.yaml, core.yaml, backend.yaml — đọc bởi terraform/stacks
```

## Value được ghép thế nào

Một tool platform, ví dụ `ingress-nginx` ở môi trường `prod`:

```text
k8s/platform/ingress-nginx/helmfile.yaml.gotmpl    release: chart ingress-nginx/ingress-nginx, version
  values:
    infra-base/k8s/platform/ingress-nginx/values.yaml.gotmpl        chung
    infra-base/k8s/platform/ingress-nginx/prod/values.yaml.gotmpl   riêng prod (ghi đè)
```

Map gộp theo key, list bị thay thế cả list. Tool có nhiều file value (kube-prometheus-stack, loki,
mimir, grafana) ghép theo đúng thứ tự cũ: mỗi file chung ngay trước file `<env>/` cùng tên.

- File vẫn là `.gotmpl`: value có thể tham chiếu state (`{{ .Values.ingressDomain }}`), secret
  (`{{ .Values.secrets.<x> | quote }}`) và biến môi trường CI (`{{ requiredEnv "AWS_ACCOUNT_ID" }}`).
  Logic theo môi trường (bảng sizing, `if prod`) không còn: mỗi môi trường ghi giá trị của nó ra.
- `readFile` đọc tương đối so với **file value**: file chung dùng `files/x`, file `<env>/` dùng `../files/x`.
- Đổi sizing một môi trường: sửa `<tool>/<env>/values.yaml.gotmpl`. Đổi cho mọi môi trường: sửa
  `<tool>/values.yaml.gotmpl`. Một key chỉ nằm ở một trong hai chỗ.

Xem manifest cuối cùng của một tool: `cd k8s && helmfile -e <env> -f platform/<tool>/helmfile.yaml.gotmpl template`
(cần age key của môi trường đó).
