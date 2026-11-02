# Falco — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/falco/`](../../../../environments/dev/kubernetes/tools/falco/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Runtime threat detection. A DaemonSet reads kernel syscall events via modern eBPF and
evaluates rules (unexpected shell in a container, sensitive mounts, outbound C2, package
installs). Alerts fan out through Falcosidekick.

| | |
|---|---|
| Chart | `falcosecurity/falco` |
| Version | `6.0.0` |
| Release / Namespace | `falco` / `falco` (created by this release) |
| Selector | `-l name=falco` |
| Labels | `layer=platform, tier=infra, component=security` |
| Values | `values.yaml.gotmpl` + `files/rules/custom_rules.yaml` |
| Driver | `modern_ebpf` (CO-RE — no kernel headers, works on managed nodes) |
| Deploy after | `observability` (alerts route to Loki) |

---

## 1. Prerequisites

| Requirement | Note |
|---|---|
| `falco` namespace, PSA **privileged** | eBPF probe needs privileged access |
| Kernel ≥ 5.8 with BTF | required by `modern_ebpf`; older kernels need the legacy eBPF or kmod driver |
| Loki + Alertmanager reachable | the alert path (`observability`, `kube-prometheus-stack`) |
| SOPS secret for sidekick webhooks | Slack/PagerDuty tokens, if you enable those outputs |

Check BTF support on a node before rolling out cluster-wide:

```bash
kubectl debug node/<node> -it --image=busybox -- ls /sys/kernel/btf/vmlinux
```

---

## 2. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f releases/platform/falco/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/falco/helmfile.yaml.gotmpl sync
```

Custom rules live in `files/rules/custom_rules.yaml` and are mounted as a ConfigMap —
edit the file, not the values. Noise control is already tuned:
`outputs.rate: 1`, `max_burst: 1000`, and syscall-drop actions log + alert.

Log level / priority by env: dev/staging `info`/`informational`, prod `warning`/`notice`.

---

## 3. Verify

```bash
kubectl -n falco rollout status daemonset/falco --timeout=300s
kubectl -n falco get ds falco          # DESIRED == READY (one pod per node)

# driver loaded successfully
kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=30 | grep -iE 'driver|eBPF|rules loaded'

# fire a real detection: shell into a container
kubectl -n dev exec -it deploy/be-user -- sh -c 'id'
kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=20 | grep -i 'Terminal shell'
```

Then confirm the alert reached its destinations (Loki query `{namespace="falco"}`, and
Alertmanager if sidekick is wired to it).

---

## 4. Rollback

```bash
helm history falco -n falco
helm rollback falco <REVISION> -n falco --wait
```

- Falco is detection-only — a rollback has **no** effect on workload traffic. What you lose
  is visibility, silently. Alert on the DaemonSet being incomplete.
- Rolling the DaemonSet restarts the eBPF probe on each node; there is a short blind window
  per node. Acceptable, but do not roll it during an active incident.
- A bad custom rule can flood the alert pipeline. If that happens, revert
  `files/rules/custom_rules.yaml` and re-sync rather than muting the whole output.

---

## 5. Monitoring & alerting

| Signal | Metric / check |
|---|---|
| Coverage | `kube_daemonset_status_number_unavailable{daemonset="falco"}` > 0 |
| Event rate | `falco_events_total` by priority/rule |
| **Syscall drops** | `falco_kernel_event_drops` — dropped events mean **missed detections** |
| Rule noise | top-N rules by event count; a single rule dominating means it needs tuning |
| Sidekick delivery | `falcosidekick_outputs_total{status="error"}` |

Two alerts matter most: a node without a Falco pod, and rising kernel event drops. Both mean
you are blind while everything looks green.

---

## 6. Triage workflow

```bash
# recent high-priority events
kubectl -n falco logs -l app.kubernetes.io/name=falco --since=1h \
  | jq -r 'select(.priority=="Critical" or .priority=="Warning")
           | "\(.time)\t\(.rule)\t\(.output_fields["k8s.ns.name"])/\(.output_fields["k8s.pod.name"])"'
```

`json_output: true` and `json_include_output_property: true` are set precisely so these
events are queryable in Loki rather than only greppable in pod logs.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pods `CrashLoopBackOff`, driver load failure | Kernel lacks BTF/eBPF support → switch `driver.kind` to `ebpf` or `kmod` for those nodes. |
| PSA denies the pod | `falco` namespace must be `privileged`. |
| No events at all | Rules not loaded (syntax error in `custom_rules.yaml`) — the startup log names the failing line. |
| Alert flood | A rule matching normal platform behaviour. Add an exception in the custom rules file; do not disable outputs wholesale. |
| High CPU on nodes | Very chatty rules or high syscall volume — narrow rule scope rather than raising limits indefinitely. |
| Events missing from Loki | Sidekick output not configured/reachable; check `falcosidekick` logs. |

---

## 8. Notes

- Three complementary layers: **PSA** (what a pod may request), **Kyverno** (what admission
  allows), **Falco** (what actually happens at runtime). Falco is the only one that sees a
  compromise after admission.
- Rules are code. Keep exceptions in git with a comment explaining *why* the behaviour is
  expected — an undocumented exception is a permanent blind spot.
- Sidekick webhook tokens belong in SOPS, never in `values.yaml.gotmpl`.
