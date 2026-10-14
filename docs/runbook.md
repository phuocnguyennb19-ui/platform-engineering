# Runbook — chạy từng phần, từng bước

Thứ tự: **0 kiểm tra offline → 1 Terraform (AWS) → 2 platform k8s → 3 app → 4 local**.
Mọi lệnh ghi rõ môi trường (`-e dev`, `--kube-context …`) — không dựa vào context đang chọn.
Ví dụ dùng `dev`. Staging/prod: cùng lệnh, nhưng chạy qua pipeline GitLab và cần duyệt tay;
không `sync`/`apply` prod từ máy cá nhân.

Ký hiệu: 🟢 chỉ đọc / offline · 🟡 thay đổi dev · 🔴 staging/prod — qua CI + duyệt.

---

## 0. Kiểm tra offline (không cần cloud, không cần key) 🟢

```bash
cd ~/Dylan/project-monorepo
helm version --short && helmfile --version && terraform version | head -1 && yq --version   # công cụ
make validate                      # chart matrix, render app, SOPS shape, terraform fmt
make docs-check                    # tài liệu sinh tự động còn khớp chart
make stacks-validate               # yamllint + schema + terraform validate/test (Terraform >= 1.10,
                                   #   cần yamllint, check-jsonschema)
make argocd-render                 # mọi app × dev/staging/prod (+ onprem-* nếu app có)
make app-render APP=frontend-html ENV=dev        # manifest cuối của 1 app
make app-values APP=frontend-html ENV=prod       # value cuối (mọi lớp đã ghép); ENV=all để so các môi trường
```

---

## 1. Terraform — base AWS (`terraform/`, value ở `infra-base/terraform/environments/<env>/`)

Thật sự **apply chỉ qua pipeline** (`ci/terraform/platform.yml`: plan lưu `tfplan` → apply đúng plan đó).
Ở máy local chỉ chạy plan để xem trước.

### 1.1 Điền value của môi trường (một lần) 🟡

```bash
$EDITOR infra-base/terraform/environments/dev/environment.yaml   # account.id (12 số, có nháy)
$EDITOR infra-base/terraform/environments/dev/backend.yaml       # bucket, region của state
make stacks-config                                               # schema check
```

### 1.2 Plan từng stack (cần credentials AWS của dev) 🟢

```bash
cd terraform
aws sts get-caller-identity                                      # đúng account dev chưa
export ENVIRONMENT=dev
BACKEND="$PWD/../infra-base/terraform/environments/$ENVIRONMENT/backend.yaml"
init() { terraform init -backend-config="bucket=$(yq '.bucket' $BACKEND)" -backend-config="region=$(yq '.region' $BACKEND)" \
           -backend-config="encrypt=true" -backend-config="use_lockfile=true" -backend-config="key=$1"; }

(cd stacks/core     && init "$ENVIRONMENT/core/core.tfstate"         && terraform plan -var="environment=$ENVIRONMENT")
(cd stacks/registry && init "$ENVIRONMENT/registry/registry.tfstate" && terraform plan -var="environment=$ENVIRONMENT")
cd ..
```

### 1.3 Apply 🟡 dev / 🔴 staging, production

Pipeline với `ENVIRONMENT=<env>` chạy `plan:core` → `apply:core` (manual trừ chỗ ghi trong `terraform/CLAUDE.md`),
rồi `plan:registry` → `apply:registry`. Thứ tự luôn **core → registry → service**.

### 1.4 Kiểm tra sau apply 🟢

```bash
aws eks describe-cluster --name platform-dev-eks --region ap-southeast-1 --query cluster.status
aws ecr describe-repositories --region ap-southeast-1 --query 'repositories[].repositoryName'
```

---

## 2. Platform k8s (`k8s/` + `monitoring/` = template, value ở `infra-base/k8s/`)

### 2.1 Kết nối cluster và key SOPS 🟢

```bash
aws eks update-kubeconfig --name platform-dev-eks --region ap-southeast-1 --alias platform-dev-eks
kubectl --context=platform-dev-eks get nodes
export SOPS_AGE_KEY_FILE=~/.config/sops/age/dev.agekey          # key age của dev, không dùng chung
sops filestatus infra-base/k8s/env-values/dev/secrets.enc.yaml  # {"encrypted":true}
export AWS_ACCOUNT_ID=<dev-account-id>                           # value dựng ARN IRSA / ECR mirror
cd k8s
```

### 2.2 Namespace + Pod Security (một lần) 🟡

```bash
kubectl --context=platform-dev-eks apply -f platform/bootstrap/manifests/namespaces.yaml
```

### 2.3 Tải chart và render thử (không đụng cluster) 🟢

```bash
helmfile -e dev deps
helmfile -e dev -l layer=platform template > /dev/null && echo "render OK"
helmfile -e dev -f platform/ingress-nginx/helmfile.yaml.gotmpl template | less    # xem 1 tool
```

### 2.4 Xem khác biệt với cluster 🟢

```bash
helmfile --kube-context platform-dev-eks -e dev -l layer=platform diff
```

### 2.5 Cài theo nhóm, đúng thứ tự trong `k8s/helmfile.yaml.gotmpl` 🟡

```bash
H="helmfile --kube-context platform-dev-eks -e dev"
sync_tool() { $H -f "$1/helmfile.yaml.gotmpl" sync; }

# cluster base — kube-prometheus-stack trước (CRD mà các tool khác dùng)
sync_tool ../monitoring/kube-prometheus-stack
for t in metrics-server reloader keda; do sync_tool platform/$t; done       # karpenter / cluster-autoscaler: tắt mặc định
# data
for t in minio postgresql redis kafka clickhouse; do sync_tool platform/$t; done
# observability
for t in loki tempo mimir; do sync_tool ../monitoring/$t; done
for t in opensearch opensearch-dashboards; do sync_tool platform/$t; done
for t in opentelemetry-collector alloy grafana; do sync_tool ../monitoring/$t; done
# networking
for t in cert-manager ingress-nginx kong external-dns; do sync_tool platform/$t; done
# security
kubectl --context=platform-dev-eks apply -f platform/vault/manifests/certificate.yaml   # staging/prod (dev chạy HTTP)
for t in vault external-secrets sealed-secrets kyverno trivy-operator falco; do sync_tool platform/$t; done
# delivery
for t in argocd velero harbor; do sync_tool platform/$t; done
```

Hoặc cả tầng một lần (cùng thứ tự): `$H -l layer=platform sync`.

### 2.6 Policy và NetworkPolicy (kubectl, ngoài helmfile) 🟡

```bash
kubectl --context=platform-dev-eks apply -f platform/kyverno/manifests/policies.yaml
kubectl --context=platform-dev-eks apply -f platform/kyverno/manifests/policies-supplychain.yaml
kubectl --context=platform-dev-eks apply -f platform/network-policies/manifests/    # LUÔN sau cùng
```

### 2.7 Kiểm tra 🟢

```bash
helm --kube-context=platform-dev-eks list -A
kubectl --context=platform-dev-eks get pods -A | grep -vE 'Running|Completed'        # không còn dòng nào là tốt
kubectl --context=platform-dev-eks -n infra get svc ingress-nginx-controller          # EXTERNAL-IP của NLB
kubectl --context=platform-dev-eks get clusterissuer
cd ..
```

Đổi value một tool: sửa `infra-base/k8s/platform/<tool>/values.yaml.gotmpl` (mọi môi trường) hoặc
`infra-base/k8s/platform/<tool>/dev/values.yaml.gotmpl` (chỉ dev) → lặp lại 2.3 → 2.4 → `sync_tool platform/<tool>`.
Staging/prod 🔴: push lên branch `staging` / merge `main` → job `helmfile:sync:<env>` (prod manual).

---

## 3. Application (ví dụ `frontend-html`)

### 3.1 Tạo / sửa value 🟢

```bash
make new-app APP=<tên> RUNTIME=eks          # app mới; frontend-html đã có sẵn
$EDITOR applications/frontend-html/k8s/values.yaml          # chung
$EDITOR applications/frontend-html/k8s/dev/values.yaml      # dev: host, tag
make app-render APP=frontend-html ENV=dev && make argocd-render && make stacks-config
```

### 3.2 Repo ECR + image (dev) 🟡

```bash
# repo ECR có sau khi merge applications/frontend-html/terraform/dev.yaml (pipeline registry, mục 1.3)
aws ecr get-login-password --region ap-southeast-1 | crane auth login <dev-account>.dkr.ecr.ap-southeast-1.amazonaws.com -u AWS --password-stdin
crane copy docker.io/nginxinc/nginx-unprivileged@sha256:7f79f463c6eb0d0bf8782992bb9636434398e3e5848398805aef2c9b025d8609 \
  <dev-account>.dkr.ecr.ap-southeast-1.amazonaws.com/frontend-html:1.30.5-alpine-slim
```

### 3.3 Deploy bằng Argo CD (một lần cho cluster) 🟡

```bash
kubectl --context=platform-dev-eks apply -f argocd/root-app.yaml       # App-of-Apps → ApplicationSet
argocd app list | grep frontend-html                                   # frontend-html-dev
argocd app diff frontend-html-dev
argocd app sync frontend-html-dev                                      # dev/staging tự sync; prod sync tay
```

### 3.4 Kiểm tra 🟢

```bash
kubectl --context=platform-dev-eks -n dev rollout status deploy/frontend-html-application --timeout=120s
kubectl --context=platform-dev-eks -n dev get pods,svc,ingress -l app.kubernetes.io/instance=frontend-html
curl -s https://frontend-html.dev.example.com/healthz                    # ok
```

### 3.5 Rollback

```bash
argocd app history frontend-html-dev
argocd app rollback frontend-html-dev <id>          # hoặc revert commit đổi tag rồi để Argo sync lại
```

App ECS: không dùng Argo — sửa `applications/<app>/terraform/*.yaml`, pipeline repo app trigger repo này
với `APP_NAME`, `ENVIRONMENT`, `IMAGE_TAG` → `plan:service` → `apply:service`.

---

## 4. Local (minikube) — không cần AWS, không cần SOPS 🟡

```bash
minikube start --kubernetes-version=v1.32.12 --addons=ingress --addons=metrics-server
kubectl --context=minikube -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
cd local
helmfile -e local list                               # thấy frontend-html (có k8s/local/values.yaml)
helmfile -e local -l layer=platform sync             # CRD + namespace `local`
helmfile -e local -l name=frontend-html template | less
helmfile -e local -l name=frontend-html sync
kubectl --context=minikube -n local rollout status deploy/frontend-html-application --timeout=120s
minikube tunnel                                      # terminal khác
curl -s http://frontend-html.localhost/healthz      # ok
# đổi HTML/config: sửa applications/frontend-html/k8s/values.yaml, sync lại, rồi
kubectl --context=minikube -n local rollout restart deploy/frontend-html-application
helmfile -e local -l name=frontend-html destroy      # gỡ
cd ..
```
