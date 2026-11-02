#!/usr/bin/env bash
# Write the app template: applications/_template/k8s/<env>/values.yaml for dev | staging | prod.
#
# Each file holds EVERY key of kubernetes/charts/application, active, with the value the release
# would get anyway in that environment:
#   chart values.yaml  *  environments/<env>/kubernetes/app-values
#                      *  eks-app-values.base.yaml  *  eks-app-env/<env>.yaml   (the app's own part)
# so an app copied from it renders exactly like an app that sets only its own part.
# global.imageRegistry is left out: the environment owns the registry.
# Keys are grouped by the chart's `# ── Section ──` blocks, one note per block, no other comments.
#
# usage: gen-app-template.sh [out]     default out: applications/_template/k8s
set -euo pipefail
cd "$(dirname "$0")/../.."
T=scripts/docs
K=environments
CHART=kubernetes/charts/application/values.yaml
OUT=${1:-applications/_template/k8s}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

for env in dev staging prod; do
  sed "s/__ENV__/$env/g" "$T/eks-app-values.base.yaml" > "$tmp/app-$env.yaml"
  yq eval-all '. as $i ireduce ({}; . * $i)' \
    "$CHART" "$K/$env/kubernetes/app-values.yaml.gotmpl" \
    "$tmp/app-$env.yaml" "$T/eks-app-env/$env.yaml" \
    | yq 'del(.global.imageRegistry) | ... comments=""' > "$tmp/merged-$env.yaml"
  mkdir -p "$OUT/$env"
  python3 - "$CHART" "$tmp/merged-$env.yaml" "$env" > "$OUT/$env/values.yaml" <<'PY'
import re, sys
chart, merged, env = sys.argv[1], sys.argv[2], sys.argv[3]
KEY = re.compile(r"^([A-Za-z_][\w-]*):")
HEAD = re.compile(r"^# ── (.+?) ─")

# section of each top-level key = the last `# ── Title ──` header above it in the chart
section, cur = {}, "Identity"
for l in open(chart, encoding="utf-8"):
    h = HEAD.match(l)
    if h: cur = re.sub(r"\s*\(.*\)\s*$", "", h.group(1)); continue
    k = KEY.match(l)
    if k: section.setdefault(k.group(1), cur)

NOTE = {
    "Identity":          "tên object và label/annotation chung; để trống = tên release",
    "Global":            "registry do môi trường đặt (global.imageRegistry trong environments/<env>/kubernetes/app-values), không ghi ở đây",
    "Image":             "repository = image.repository trong ../../terraform/app.yaml; tag hoặc digest bắt buộc",
    "Workload shape":    "Deployment | StatefulSet | DaemonSet, chiến lược rollout, số replica",
    "ServiceAccount":    "chỉ bật automountServiceAccountToken khi app gọi Kubernetes API",
    "RBAC":              "tắt mặc định — chỉ bật khi app cần quyền trên API",
    "Security":          "sàn bảo mật của nền (PSA restricted); chỉ nới khi có lý do",
    "Entrypoint":        "ghi đè ENTRYPOINT/CMD của image",
    "Environment":       "biến môi trường; bí mật lấy qua extraEnvFrom/secretRef, không ghi giá trị",
    "Ports":             "cổng phụ (metrics 9090); cổng chính là service.targetPort",
    "Service":           "Service ClusterIP trỏ vào cổng http",
    "Health probes":     "bắt buộc ở prod",
    "Resources":         "đo theo mức dùng thật; không đặt limits.cpu",
    "Lifecycle":         "thời gian tắt êm và preStop",
    "Autoscaling":       "HPA, KEDA, VPA — chọn tối đa một cơ chế scale ngang",
    "Availability":      "PDB, rải pod theo node/zone, nodeSelector/affinity/tolerations",
    "Pod-spec escape hatches": "trường pod-spec ít dùng; host* luôn false (PSA restricted)",
    "Volumes":           "tmp là tmpfs (tính vào limits.memory); list thay thế cả danh sách",
    "initContainers":    "chạy trước container chính",
    "Sidecars":          "container chạy kèm",
    "Workers":           "Deployment phụ dùng chung image/config",
    "CronJobs":          "job định kỳ",
    "Config & Secrets":  "ConfigMap/Secret của chart, ExternalSecret, Reloader",
    "North-south routing": "Ingress hoặc HTTPRoute/GRPCRoute — không bật cả hai",
    "NetworkPolicy":     "luật mạng của app; allowSameNamespace phải giữ true",
    "Observability":     "ServiceMonitor/PrometheusRule cần CRD của kube-prometheus-stack",
    "helm test":         "smoke test sau deploy",
    "Raw manifests shipped with the release": "manifest thô đi kèm release",
}

print(f"# __APP__ · {env} — toàn bộ cấu hình của app ở môi trường {env} (chart kubernetes/charts/application).")
print("# Mọi key đều active với giá trị app sẽ nhận ở môi trường này; sửa key nào app cần khác.")
print("# Sinh bởi scripts/docs/gen-app-template.sh (make docs-reference) — không sửa tay; tạo app: make new-app.")
last = None
for l in open(merged, encoding="utf-8").read().rstrip("\n").split("\n"):
    k = KEY.match(l)
    if k:
        sec = section.get(k.group(1), "Khác")
        if sec != last:
            print(); print(f"# ── {sec} ── {NOTE.get(sec, '')}".rstrip()); last = sec
    print(l)
PY
done
