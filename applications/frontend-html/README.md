# frontend-html

Frontend HTML tĩnh do nginx phục vụ. Dùng để thử deploy một frontend từ đầu đến cuối trên
AWS (Argo CD: dev/staging/prod) và trên cluster local (minikube). App không có code để
build: trang HTML và cấu hình nginx nằm trong ConfigMap, server là image upstream.

| | |
|---|---|
| Image | `nginxinc/nginx-unprivileged:1.30.5-alpine-slim`, ghim digest `sha256:7f79f463c6eb0d0bf8782992bb9636434398e3e5848398805aef2c9b025d8609` |
| Cổng | 8080 (`http`); `/healthz` cho probe |
| Host | dev `frontend-html.dev.example.com` · staging `frontend-html.staging.example.com` · prod `frontend-html.example.com` · local `frontend-html.localhost` |
| Nội dung | `extraConfigMaps.site` trong mỗi `k8s/<env>/values.yaml` (`index.html`, `default.conf`); ngoài `/healthz`, mọi đường dẫn đều trả `index.html` (fallback cho SPA) |

## Các file

| File | Nội dung |
|---|---|
| `k8s/<env>/values.yaml` | **toàn bộ** value của app ở môi trường đó — mỗi file đầy đủ: image, ConfigMap (HTML + nginx), volume, probe, resources, Reloader, Ingress. Sửa phần chung (vd HTML) thì sửa ở mọi file |
| `k8s/dev/`, `k8s/staging/`, `k8s/prod/` | môi trường AWS: Ingress (host, TLS, issuer) riêng |
| `terraform/app.yaml`, `terraform/<env>.yaml` | repository ECR `frontend-html` ở dev/staging/production |

## Thử trên cluster laptop

Chỉ có value dev/staging/prod. Chạy trên laptop = trỏ `dev` vào cluster laptop trong
`environments/<env>/kubernetes/cluster/target.local.yaml` (vd `dev: { cluster: docker-desktop-dev }`), rồi từ gốc repo:

```bash
helmfile -e dev -l name=frontend-html diff
helmfile -e dev -l name=frontend-html sync
```

Value dev kéo image từ ECR của dev (`global.imageRegistry`): cluster laptop cần quyền pull ECR,
hoặc đặt `image.registry` cho image công khai trong `k8s/dev/values.yaml`.

## Thử trên AWS (dev)

Cần sẵn: core + registry đã apply ở dev (repo ECR `frontend-html` tồn tại),
platform dev đã sync, Argo CD đang chạy ApplicationSet.

1. Copy image vào ECR dev theo digest:
   ```bash
   crane copy docker.io/nginxinc/nginx-unprivileged@sha256:7f79f463c6eb0d0bf8782992bb9636434398e3e5848398805aef2c9b025d8609 \
     <dev-account>.dkr.ecr.ap-southeast-1.amazonaws.com/frontend-html:1.30.5-alpine-slim
   ```
2. Merge thư mục này vào `main`. Argo CD sinh Application `frontend-html-dev` và tự sync.
3. Kiểm tra:
   ```bash
   argocd app get frontend-html-dev
   curl -s https://frontend-html.dev.example.com/healthz
   ```

Prod không tự sync: `argocd app diff frontend-html-prod`, sau đó sync tay.

## Đã biết

- `global.imageRegistry` của dev/staging/prod vẫn là `REPLACE_WITH_*_AWS_ACCOUNT_ID`. Pipeline deploy từ chối chạy cho tới khi điền account ID thật.
- Kyverno `require-trusted-registry` (Enforce) chưa cho phép ECR, nên pod sẽ bị chặn trên AWS cho tới khi policy thêm host ECR. Lỗi này ảnh hưởng mọi app, đã nêu trong review.
- Resources của app (10m/32Mi) thấp hơn mức sàn tier prod: app này cố ý chỉ dùng để thử.

## Cluster khác (on-prem, K3s…)

Không có value riêng cho on-prem: cluster đó là deploy target của `dev`/`staging`/`prod`
trong `environments/<env>/kubernetes/cluster/target.local.yaml`. Image phải pull được từ cluster đó (ECR của
môi trường, hoặc `image.registry` trỏ registry khác trong `k8s/<env>/values.yaml`).

## Vì sao config như vậy

File value chỉ còn key/value; lý do của các lựa chọn ở đây.

- `extraConfigMaps.site` gom `index.html` và `default.conf` vào **một** ConfigMap, mount từng file bằng `items`:
  chart in các ConfigMap trong `extraConfigMaps` không có `---` ngăn cách, nên hai mục thì chỉ còn mục cuối.
- Value đi qua `tpl`: không đặt cặp ngoặc nhọn kép của Go template vào HTML.
- `/tmp` là emptyDir: root filesystem chỉ đọc, nginx ghi pid và file tạm vào `/tmp`. `extraVolumes`
  thay cả list của tier, nên `tmp` phải có ở đây.
- `reloader.enabled: true`: `extraConfigMaps` không có checksum annotation; Reloader cuộn pod khi nội dung đổi.
  Local không có Reloader → `kubectl --context=minikube -n local rollout restart deploy/frontend-html-application`.
- Cổng 8080 là `service.targetPort` mặc định và là cổng NetworkPolicy mở; nginx không có endpoint metrics
  nên không có ServiceMonitor.
- Resources 10m/32Mi thấp hơn sàn tier prod: app chỉ dùng để thử.
