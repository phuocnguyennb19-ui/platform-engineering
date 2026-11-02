# Runbook — chạy từng phần, từng bước

Thứ tự: **0 kiểm tra offline → 1 Terraform (AWS) → 2 platform k8s → 3 app**. Phần Kubernetes chạy tay
(kubectl/helm/helmfile, kể cả cluster laptop): [`kubernetes-manual.md`](kubernetes-manual.md).
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
make argocd-render                 # mọi app × dev/staging/prod
make app-render APP=frontend-html ENV=dev        # manifest cuối của 1 app
make app-values APP=frontend-html ENV=prod       # value cuối (mọi lớp đã ghép); ENV=all để so các môi trường
```

---

## 1. Terraform — base AWS (`terraform/`, value ở `environments/<env>/terraform/`)

Thật sự **apply chỉ qua pipeline** (`ci/terraform/platform.yml`: plan lưu `tfplan` → apply đúng plan đó).
Ở máy local chỉ chạy plan để xem trước.

### 1.1 Điền value của môi trường (một lần) 🟡

```bash
$EDITOR environments/dev/terraform/environment.yaml   # account.id (12 số, có nháy)
$EDITOR environments/dev/terraform/backend.yaml       # bucket, region của state
make stacks-config                                               # schema check
```

### 1.2 Plan từng stack (cần credentials AWS của dev) 🟢

```bash
cd terraform
aws sts get-caller-identity                                      # đúng account dev chưa
export ENVIRONMENT=dev
BACKEND="$PWD/../environments/$ENVIRONMENT/terraform/backend.yaml"
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

## 2. Platform k8s (`kubernetes/releases/` = template, value ở `environments/<env>/kubernetes/`)

### 2.1 Kết nối cluster và key SOPS 🟢

```bash
aws eks update-kubeconfig --name platform-dev-eks --region ap-southeast-1 --alias platform-dev-eks
kubectl --context=platform-dev-eks get nodes
export SOPS_AGE_KEY_FILE=~/.config/sops/age/dev.agekey          # key age của dev, không dùng chung
sops filestatus environments/dev/kubernetes/secrets.enc.yaml  # {"encrypted":true}
export AWS_ACCOUNT_ID=<dev-account-id>                           # value dựng ARN IRSA / ECR mirror
```

#### 2.1.1 Tách key SOPS theo môi trường (một lần) 🔴

Hiện trạng: `dev`, `staging` và `prod/secrets.enc.yaml` cùng được mã hoá cho **một** age
recipient (key dev), còn `.sops.yaml` vẫn để `REPLACE_WITH_` cho staging và prod. Ai giữ key dev
đều đọc được secret prod. `make sops-recipients-check` báo trạng thái này và **chưa** nằm trong
`make validate` / CI cho tới khi làm xong các bước dưới. Lệnh này chỉ đọc metadata công khai,
không giải mã.

Mọi bước dưới đây nằm ngoài repo hoặc cần người giữ key. Không chạy khi chưa được duyệt.

1. **Staging:** người phụ trách tạo age key riêng (`age-keygen`). Private key chỉ lưu vào biến
   GitLab `SOPS_AGE_PRIVATE_KEY_STAGING` (protected, masked). Public key dùng ở bước 3.
2. **Production:** chủ hạ tầng xác nhận ARN KMS (`sops_kms_key_arn`, output của `stacks/core`
   production) và quyền `kms:Encrypt`/`kms:Decrypt` của role `gitlab-deploy-prod`. Nếu giữ age
   break-glass thì tạo key riêng và lưu vào `SOPS_AGE_PRIVATE_KEY_PRODUCTION` (protected).
3. Thay `REPLACE_WITH_*` trong `.sops.yaml` bằng recipient thật. Merge request riêng, có review.
4. Người được uỷ quyền, giữ key hiện tại, chạy `sops updatekeys` trên
   `environments/<env>/kubernetes/{staging,prod}/secrets.enc.yaml` từ máy an toàn. Không in hay ghi
   plaintext ra đĩa.
5. **Rotate mọi giá trị secret** của staging và prod (mật khẩu DB, token, …). Ciphertext cũ vẫn
   giải mã được bằng key dev trong lịch sử git, nên chỉ đổi key là chưa đủ.
6. `make sops-recipients-check` phải trả `[OK]`. Sau đó mới đưa nó vào `validate` và CI
   (`security:sops-encrypted`).
7. Thu hẹp phạm vi `SOPS_AGE_PRIVATE_KEY_DEV` để nó chỉ còn mở được secret dev.

### 2.2 – 2.7 Namespace, render, diff, cài theo thứ tự, NetworkPolicy, kiểm tra

Lệnh từng bước (Infra Base → Platform, từng tool theo thứ tự `helmfiles:`, luôn `--kube-context`):
[`kubernetes-manual.md` — B1 → B3](kubernetes-manual.md#b1-infra-base-namespace--psa).
Cách value của tool được ghép: [`../03-values-mapping.md` §3](../03-values-mapping.md#3-lớp-platform--kubernetesreleasesgrouptool).

Đổi value một tool: sửa `environments/<env>/kubernetes/{tools,ingress,monitoring}/<tool>/` của đúng môi trường
→ `template` → `diff` → `sync` tool đó. Staging/prod 🔴: push lên branch `staging` / merge `main` →
job `helmfile:sync:<env>` (prod manual).

---

### 2.x Sau khi đổi cấu trúc repo: chuyển đường dẫn Argo CD

Nếu một cluster đang chạy Argo CD App-of-Apps, `root-app` vẫn trỏ đường dẫn cũ sau khi merge. Làm theo
[`kubernetes/argocd/README.md` → Path cutover](../../kubernetes/argocd/README.md#-path-cutover-after-the-repository-restructure)
— kiểm tra chỉ-đọc trước khi merge, rồi apply lại `root-app.yaml` theo thứ tự dev → staging → prod.

## 3. Application

Cluster có owner `helmfile` (mọi cluster `dev` hiện tại, `delivery.owner` trong
`environments/<env>/kubernetes/cluster/<cluster>.yaml`): deploy, kiểm tra, rollback, gỡ bằng
`helmfile -e <env> -l name=<app> …` từ gốc repo —
[`kubernetes-manual.md` — B4, C1 → C6](kubernetes-manual.md#b4-application). Cluster laptop
(Docker Desktop, K3s, self-managed) là một target của `dev`, chọn trong `target.local.yaml`.

Cluster mà Argo CD sở hữu tầng app (owner `argocd`) — không dùng helmfile cho app ở đó:

```bash
kubectl --context=<ctx> apply -f kubernetes/argocd/root-app.yaml   # một lần: App-of-Apps → ApplicationSet
argocd app diff <app>-<env>
argocd app sync <app>-<env>                                        # prod không auto-sync: sync tay sau review
argocd app history <app>-<env>
argocd app rollback <app>-<env> <id>                               # hoặc revert commit rồi để Argo sync lại
```

App ECS: không dùng Argo — sửa `applications/<app>/terraform/*.yaml`, pipeline repo app trigger repo này
với `APP_NAME`, `ENVIRONMENT`, `IMAGE_TAG` → `plan:service` → `apply:service`.
