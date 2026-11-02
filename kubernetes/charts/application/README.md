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
│   ├── gateway-api-values.yaml        HTTPRoute + GRPCRoute
│   └── proxy-values.yaml              nginx proxy sidecar (proxy.enabled)
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
    │   ├── _proxy.tpl                 nginx sidecar: nginx.conf, container, volume, guard
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
    │   ├── proxy-configmap.yaml       nginx.conf của proxy sidecar
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

`values.schema.json` chặn key gõ sai (từ 2.2.0 cả key cấp gốc: `additionalProperties: false`)
— Helm vốn bỏ qua key lạ, nên không có schema thì gõ nhầm = im lặng dùng default. Mọi release
(app và platform) dùng `missingFileHandler: Error`, nên path values sai cũng làm render fail.

---

## Proxy sidecar (nginx, từ 2.3.0)

Opt-in, chỉ cho pod **app** (Deployment / StatefulSet / DaemonSet) — worker và cronjob
không bao giờ có. Tắt (`proxy.enabled: false`, default) thì output giống hệt 2.2.0.

```
Ingress (kong) / HTTPRoute → Service :service.port → targetPort `http`
  → container `proxy` (nginx, :proxy.port)  → proxy_pass http://127.0.0.1:proxy.upstreamPort
  → container app (:proxy.upstreamPort, port name `app`)
```

```yaml
proxy:
  enabled: true
  upstreamPort: 3000        # BẮT BUỘC — port app listen; khác proxy.port (mặc định 8080)
  clientMaxBodySize: 16m
  timeouts: { read: 120s }
```

Khi bật:

- **Port.** Tên `http` chuyển sang nginx → Service `targetPort: http`, headless Service,
  Ingress/HTTPRoute (qua Service) đều tới nginx. `service.targetPort` bị bỏ qua. App
  container mở `proxy.upstreamPort` với tên `app`. `extraPorts` (vd. `metrics`) vẫn nằm trên
  app container và vẫn lên Service như cũ.
- **Probe.** Probe của app (`probes.*`) với `port: http` được đổi thành `port: app` — vẫn
  probe **app**, không probe nginx (kubelet chỉ resolve port name trong chính container đó).
  Port số và tên khác giữ nguyên. nginx có readiness/liveness riêng trên `proxy.healthPath`
  (nginx tự trả 200, không proxy). Pod chỉ Ready khi cả hai container Ready.
- **NetworkPolicy.** Port ingress mặc định là `proxy.port` (+ `extraPorts`);
  `upstreamPort` không mở ra ngoài pod — app chỉ nhận traffic qua 127.0.0.1.
- **Config.** `nginx.conf` render vào ConfigMap `<fullname>-proxy`, mount read-only;
  `checksum/proxy-config` trên pod template → đổi config là rollout. `proxy.config` thay
  toàn bộ file; `httpSnippet` / `serverSnippet` thêm directive.
- **Header.** `Host` ($http_host), `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`
  (header từ ingress, không có thì `$scheme`), `X-Request-ID` (chỉ khi request có),
  WebSocket `Upgrade`. `realIpFrom` = CIDR tin cậy cho X-Forwarded-For.
- **Security.** Container `proxy` dùng chung merge `global → securityDefaults →
  securityContext → proxy.securityContext` (non-root, read-only rootfs, drop ALL; seccomp
  từ pod). Mọi đường ghi nằm trên emptyDir `/tmp` và `/var/cache/nginx`. Chạy `nginx`
  trực tiếp, bỏ qua entrypoint script của image.
- **Image.** Theo `application.image`: `registry: ""` = `global.imageRegistry`, digest thắng
  tag. Default là `nginxinc/nginx-unprivileged` pin digest (như `applications/test-app`) —
  Kyverno chỉ nhận ECR/harbor/gitlab nên phải mirror image vào registry đó.

**Thứ tự start/stop.** nginx là container thường (không phải native sidecar
`initContainers` + `restartPolicy: Always`): native sidecar dừng **sau** app, ngược với điều cần
ở đây. Khi start, hai container lên song song; trong lúc app chưa listen nginx trả 502, nhưng
pod chưa Ready nên chưa nhận traffic. Khi stop:

| t | nginx | app |
|---|---|---|
| 0 | preStop `sleep drainSeconds` — vẫn phục vụ trong lúc endpoint bị gỡ | preStop `sleep appPreStopSleepSeconds` |
| drainSeconds (5) | `nginx -s quit`: hết nhận kết nối mới, request đang chạy chạy xong | vẫn chạy |
| appPreStopSleepSeconds (15) | đã thoát | nhận SIGTERM |

`appPreStopSleepSeconds > 0` **thay** `lifecycle.preStop` của app bằng native `sleep`
(k8s ≥ 1.30; giữ `postStart`); đặt `0` để giữ `lifecycle` như đã khai. Chart fail nếu
`drainSeconds` hoặc `appPreStopSleepSeconds` ≥ `terminationGracePeriodSeconds`, hoặc
`appPreStopSleepSeconds` ≤ `drainSeconds`.

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
- `proxy.enabled` mà thiếu `proxy.upstreamPort`, hoặc `upstreamPort` = `proxy.port`; `extraPorts`
  trùng port/tên `http`/`app`; tên volume/container/extraConfigMap `proxy*` bị chiếm; thời gian
  shutdown của proxy không vừa `terminationGracePeriodSeconds`

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
