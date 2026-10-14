# `application` chart

Generic production chart cho stateless/stateful app, background worker và scheduled job.

```bash
helm template <release> charts/application -f values.yaml
```

---

## Cấu trúc

Template gom theo **component**, không theo kind — layout của các chart nhiều
component (kube-prometheus-stack, loki, argo-cd). Câu hỏi thường gặp khi debug là
"worker sinh ra những gì?", chứ không phải "HPA nằm đâu".

```
charts/application/
├── Chart.yaml
├── values.yaml                    ← contract chính, comment theo từng khối
├── values.schema.json             ← chặn key gõ sai lúc render
├── .helmignore
├── README.md · UPGRADING.md
│
├── ci/                            ← test matrix (convention chart-testing)
│   ├── minimal-values.yaml            image only
│   ├── full-values.yaml               bật mọi feature cùng lúc
│   ├── statefulset-values.yaml        workload.kind: StatefulSet
│   ├── daemonset-values.yaml          workload.kind: DaemonSet
│   └── gateway-api-values.yaml        HTTPRoute + GRPCRoute
│
└── templates/
    ├── NOTES.txt                  ← endpoint + lệnh verify + cảnh báo readiness
    │
    ├── _helpers/                  ← logic dùng chung, không sinh object
    │   ├── _names.tpl                 tên chart/release/object
    │   ├── _labels.tpl                label, annotation, selector theo component
    │   ├── _images.tpl                resolve registry/repo/tag/digest
    │   ├── _security.tpl              merge securityContext 3 tầng
    │   ├── _env.tpl                   env / envFrom kế thừa
    │   ├── _component.tpl             deep-merge root ↔ component
    │   ├── _capabilities.tpl          dò API version của cluster
    │   └── _validation.tpl            12 guard fail-at-render
    │
    ├── _partials/
    │   └── _pod.tpl               ← pod spec DUY NHẤT cho cả 5 loại workload
    │
    ├── app/                       ← workload chính
    │   ├── workload.yaml              Deployment | StatefulSet | DaemonSet
    │   ├── service.yaml               Service (+ headless)
    │   ├── hpa.yaml                   HorizontalPodAutoscaler
    │   ├── scaledobject.yaml          KEDA ScaledObject
    │   ├── vpa.yaml                   VerticalPodAutoscaler
    │   └── poddisruptionbudget.yaml   PodDisruptionBudget
    │
    ├── worker/
    │   └── workers.yaml           ← mỗi worker: Deployment + Service +
    │                                ServiceMonitor + HPA + ScaledObject + PDB
    ├── cronjob/
    │   └── cronjob.yaml
    │
    ├── networking/
    │   ├── ingress.yaml · httproute.yaml · grpcroute.yaml
    │   └── networkpolicy.yaml
    │
    ├── config/
    │   ├── configmap.yaml · secret.yaml · externalsecret.yaml
    │
    ├── rbac/
    │   ├── serviceaccount.yaml · rbac.yaml
    │
    ├── observability/
    │   ├── servicemonitor.yaml · prometheusrule.yaml
    │
    ├── extras/
    │   └── extra-objects.yaml     ← manifest tuỳ ý qua `extraObjects[]`
    │
    └── tests/
        └── test-connection.yaml   ← `helm test <release>`
```

### Hai chỗ cố ý lệch convention

**`app/workload.yaml` không grep được bằng `kind: Deployment`.**
Kind là biến (`kind: {{ $kind }}`) vì `workload.kind` chọn controller lúc render.
Muốn biết ra kind gì: đọc `workload.kind` trong values, hoặc
`helm template ... | grep '^kind:'`.

**`worker/workers.yaml` chứa 6 kind.**
Cả 6 nằm trong cùng một `range .Values.workers` với cùng khối `componentConfig`.
Tách thành 6 file = lặp vòng lặp 6 lần rồi lệch nhau khi sửa. Đánh đổi có chủ đích.

---

## Hai template làm nên tính "dynamic"

Đọc 2 file này là hiểu toàn bộ chart:

**`_partials/_pod.tpl` → `application.podSpec`**
Pod spec duy nhất. Thêm một knob ở đây thì Deployment, StatefulSet, DaemonSet,
worker và cronjob có ngay — không phải sửa 5 file.

**`_helpers/_component.tpl` → `application.componentConfig`**
Deep-merge root values với override của từng component. Nhờ nó một worker chỉ cần
khai `command`/`args`; image, securityContext, volumes, env, scheduling tự kế thừa.

> Một ngoại lệ có chủ đích: **`probes` KHÔNG kế thừa.** App probe trỏ `port: http`,
> worker không có port đó → pod không bao giờ Ready. Và deep-merge `exec` đè lên
> `httpGet` tạo probe 2 handler, bị API server từ chối. Component chỉ nhận probe
> nó tự khai.

---

## Values

Mọi key optional trừ:

```yaml
image:
  repository: my-service   # BẮT BUỘC
  tag: "1.2.3"             # BẮT BUỘC (hoặc digest) — không có fallback `latest`
```

Production còn cần: `probes.readiness`, `resources`, `podDisruptionBudget`,
`topologySpreadConstraints`, `networkPolicy`. `NOTES.txt` liệt kê cái nào thiếu
sau mỗi lần install.

`values.schema.json` chặn key gõ sai — quan trọng vì helmfile để
`missingFileHandler: Warn`; không có schema thì gõ nhầm = im lặng dùng default.

---

## Validation

Chart fail lúc render thay vì đẩy object hỏng lên cluster:

- `autoscaling` + `keda` cùng bật
- PDB có cả `minAvailable` và `maxUnavailable`
- `workload.kind` sai; autoscaling trên DaemonSet
- probe 0 handler hoặc >1 handler (root, worker, cronjob)
- `serviceMonitor` mà không có Service
- `ingress` + `httpRoute` cùng bật; `ingress` không có hosts
- `keda` không có triggers; worker/cronjob thiếu name/schedule
- `image.tag: latest`, image không resolve được

```bash
$ helm template rel charts/application --set image.tag=latest
Error: image.tag `latest` is not allowed — pin an immutable tag or digest
```

---

## Test cục bộ

Luôn lint/template **kèm một values file**. Chart không có default cho
`image.repository`, nên chạy trần sẽ fail — đó là chủ đích, không phải chart hỏng:

```bash
$ helm lint charts/application
[ERROR] values.yaml: - at '/image/repository': minLength: got 0, want 1
```

Cách đúng:

```bash
for f in charts/application/ci/*-values.yaml; do
  helm lint     charts/application -f "$f" >/dev/null || echo "LINT FAIL $f"
  helm template ci charts/application -f "$f" >/dev/null || echo "TMPL FAIL $f"
done
```

Sửa xong một lỗi render thì thêm case vào `ci/` — đó là thứ giữ cho nó không quay lại.

### Vì sao `image.repository` không có default

Nó là điểm tựa an toàn cho toàn bộ layering ở các thư mục app (`be-payment/`,
`be-user/`, …). Vì mọi values file bên đó
đều **optional** (detect trên đĩa), một file load hỏng hoặc một path gõ sai phải
biến thành lỗi, chứ không phải một release chạy được nhưng sai.

Trước đây `repository` mặc định `nginx` (default của `helm create`). Kết hợp với
`missingFileHandler: Warn`, một path sai chỉ in `skipping missing values file` rồi
deploy **pod nginx mang đúng tên service và đúng Ingress** — pipeline xanh, rollout
xanh, sai app đang nhận traffic production.

---

## Nâng cấp từ 1.x

**Breaking.** Đọc [UPGRADING.md](UPGRADING.md) trước — selector đổi nên
`Deployment.spec.selector` (immutable) buộc phải recreate workload.
