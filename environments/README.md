# environments — value của base, mỗi môi trường một folder

| | |
|---|---|
| **Chứa gì** | Mỗi môi trường một folder đầy đủ: `<dev\|staging\|prod>/kubernetes/` (value + manifest của base k8s) và `<dev\|staging\|prod>/terraform/` (value AWS). |
| **Owner** | platform team (`prod/`, secret, network: + security team — CODEOWNERS) |
| **Sửa thế nào** | sửa file của đúng môi trường; đổi cho mọi môi trường thì sửa cả ba và review diff giữa chúng |
| **Validate** | `make platform-template ENV=<env>` (cần age key) · `make k8s-env-test` · `make sops-check` · `make stacks-validate` (Terraform ≥ 1.10) |

Thư mục này chứa **value và manifest của base infra** (AWS + Kubernetes), mỗi môi trường một folder **đầy đủ** — không có
folder dùng chung. Template nằm ở chỗ khác: chart và helmfile release ở `kubernetes/`,
module/stack Terraform ở `terraform/`. Value ở đây map thẳng vào chart, giống như
`applications/<app>/k8s/<env>/values.yaml` map vào chart `application`.

```text
environments/
  dev/ staging/ prod/            một môi trường (tên Helm: dev | staging | prod), tự đủ
    kubernetes/
      state.yaml                 state helmfile: env, platformName, eksClusterName, ingressDomain, storageClass…
      cluster/
        target.yaml              cluster mà app của môi trường này deploy lên (+ target.local.yaml, gitignored)
        environment.yaml         tên, chính sách deploy, mức PSA mong đợi
        <cluster>.yaml           metadata từng cluster của môi trường: context, owner, capability
      namespace/namespaces.yaml  namespace platform (infra, observability, database…) + namespace `<env>`, nhãn PSA
      network/                   NetworkPolicy: 00-baseline … 50-security (platform + namespace `<env>`)
      ingress/<tool>/            ingress-nginx, kong
      tools/<tool>/              tool platform (+ files/ đọc bằng readFile)
      monitoring/<tool>/         observability; monitoring/prometheus-rules/ rule cảnh báo platform
      app-values.yaml.gotmpl     mặc định cho mọi app của môi trường (registry, bảo mật, sizing, egress)
      secrets.enc.yaml           secret SOPS của platform (chỉ key của môi trường đó giải mã được)
    terraform/
      environment.yaml           account, region, name_prefix, tags, chính sách release; `environment:` = tên Terraform
      core.yaml                  hạ tầng chung: vpc, eks, ecs, alb, dns, iam, ecr, logs
      backend.yaml               state bucket, region, encrypt, use_lockfile
```

Không phải value nên không nằm ở đây: repo chart + `helmDefaults` (`kubernetes/repositories.yaml`), công cụ
metadata cluster — schemas, hướng dẫn provider, preflight (`scripts/cluster/`, hướng dẫn `docs/clusters/`), tài liệu namespace và
NetworkPolicy (`kubernetes/docs/NAMESPACES.md`, `kubernetes/docs/NETWORK-POLICIES.md`).

Dựng base k8s cho một môi trường, theo thứ tự (lệnh ghi lên cluster — luôn ghi rõ `--context`):

```bash
kubectl --context=<ctx> apply -f environments/<env>/kubernetes/namespace/   # 1. namespace + PSA
helmfile -e <env> --kube-context <ctx> -f kubernetes/helmfile.yaml.gotmpl -l layer=platform sync   # 2. tool, theo thứ tự helmfiles:
kubectl --context=<ctx> apply -f environments/<env>/kubernetes/network/     # 3. NetworkPolicy, sau cùng
```

Helmfile platform không ghim kube context: thiếu `--kube-context` thì helm dùng current-context.
Từng bước (render → diff → sync, từng tool): [`docs/20-runbooks/kubernetes-manual.md`](../docs/20-runbooks/kubernetes-manual.md).

CNI không nằm ở đây: nó thuộc cluster (EKS: addon `vpc-cni` trong `terraform/stacks/core`; local: chọn khi
tạo cluster, xem `docs/clusters/providers/`). NetworkPolicy chỉ có tác dụng khi CNI thực thi nó.

## Value map vào chart thế nào

Một tool platform, ví dụ `ingress-nginx` ở môi trường `prod`:

```text
kubernetes/releases/platform/ingress-nginx/helmfile.yaml.gotmpl    release: chart ingress-nginx/ingress-nginx, version
  environments.prod.values: environments/prod/kubernetes/state.yaml   (+ secrets: environments/prod/kubernetes/secrets.enc.yaml)
  values:
    environments/prod/kubernetes/ingress/ingress-nginx/values.yaml.gotmpl   toàn bộ value của tool ở prod
```

Mỗi file là **toàn bộ** value của tool ở môi trường đó, ghép trên mặc định của chart. Tool có nhiều file
value (kube-prometheus-stack, loki, mimir, grafana) giữ các file đó, mỗi file đầy đủ.

- File vẫn là `.gotmpl`: value có thể tham chiếu state (`{{ .Values.ingressDomain }}`), secret
  (`{{ .Values.secrets.<x> | quote }}`) và biến môi trường CI (`{{ requiredEnv "AWS_ACCOUNT_ID" }}`).
- `readFile` đọc tương đối so với file value: `files/x` trong folder của tool ở môi trường đó.
- Đổi một môi trường: sửa file của môi trường đó. Đổi cho mọi môi trường: sửa cả ba file — giữ chúng
  giống nhau ở những key không phụ thuộc môi trường, và review diff giữa `dev/`, `staging/`, `prod/`.

Xem manifest cuối cùng của một tool: `cd kubernetes && helmfile -e <env> -f releases/platform/<tool>/helmfile.yaml.gotmpl template`
(cần age key của môi trường đó).

## Tên môi trường

Folder mang tên Helm (`dev`, `staging`, `prod`). Terraform gọi `prod` là `production`: nó tìm folder qua
trường `environment:` trong `<dir>/terraform/environment.yaml` (`terraform/shared/config`), CI ánh xạ
`ENVIRONMENT=production` → `prod/` ở một chỗ (`ci/terraform/platform.yml`). Không đổi tên bên nào —
xem [ADR 0005](../docs/adr/0005-environments-folder.md).
