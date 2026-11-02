# monitoring — template của observability

| | |
|---|---|
| **Chứa gì** | Một helmfile mỗi release observability: `kube-prometheus-stack`, `loki`, `tempo`, `mimir`, `opentelemetry-collector`, `alloy`, `grafana` (chart + version + label). Không có value. |
| **Value** | `environments/<env>/kubernetes/monitoring/<tool>/` (rule cảnh báo platform: `environments/<env>/kubernetes/monitoring/prometheus-rules/`) |
| **Owner** | platform team |
| **Sửa thế nào** | Đổi chart/version: helmfile ở đây. Đổi cấu hình: value của môi trường. Thứ tự cài: danh sách `helmfiles:` trong `kubernetes/helmfile.yaml.gotmpl` (prometheus-operator-crds đứng đầu vì nó mang CRD, rồi kube-prometheus-stack). |
| **Validate** | `cd kubernetes && helmfile -e <env> -f ../kubernetes/releases/observability/<tool>/helmfile.yaml.gotmpl template` (cần age key của môi trường) |

Hướng dẫn từng tool: `kubernetes/releases/observability/<tool>/README.md`.
