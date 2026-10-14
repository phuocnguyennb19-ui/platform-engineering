# network-policies — zero-trust, workload-scoped

Raw manifests, **not** a Helm release — same convention as `bootstrap/`. Applied
**last**, once every release is synced and healthy.

```bash
kubectl apply -f platform/network-policies/manifests/
kubectl get netpol -A
```

| File | Scope | Policies |
|---|---|---|
| `00-baseline.yaml` | 7 namespaces | 14 — default-deny (Ingress **+ Egress**) and the DNS / kube-API / in-cluster egress floor |
| `10-monitoring.yaml` | `observability` | 9 — one per workload |
| `20-database.yaml` | `database` | 5 — one per engine |
| `30-application.yaml` | `dev` `staging` `prod` | 9 — namespace floor only; apps own their own rules |
| `40-platform.yaml` | `velero` `trivy-system` | 2 |
| `50-security.yaml` | `vault` `harbor` `falco` `keda` | 14 — previously unprotected |

---

## The model

**Two layers, two owners.**

1. **Platform baseline** (`00-baseline.yaml`) — default-deny in both directions,
   plus the floor every pod needs: DNS, the Kubernetes API, and in-cluster
   traffic. Owned by whoever runs the cluster. No release may own this: a
   namespace-wide rule emitted by one chart would disappear when that chart is
   uninstalled, silently unprotecting everything else in the namespace.
2. **Workload policies** — each selects **one workload by label**. For upstream
   charts they live in the tier files here; for in-house apps they ship with the
   service (see below), which is where they belong.

**Egress deny is the point of this layer.** Every destination already gates
access with its own ingress rules, so per-destination egress would double the
rules and double what breaks when a port moves, for no added isolation. What
egress-deny adds is the thing ingress rules cannot: **no pod can open a
connection to the internet.** That closes exfiltration and C2 without needing a
full dependency graph. Workloads that legitimately call out are granted it
explicitly — today Grafana (plugin downloads), Alertmanager (webhooks), Velero
(off-cluster backup targets) and trivy-operator (vulnerability DB).

### Three rules that govern every edit

**1. Policies are additive — they can only widen.** A pod's allowed traffic is
the union of every policy selecting it. There is no deny rule and no precedence.
Adding a policy never tightens anything; to tighten you must edit or delete an
existing allow. A stale duplicate elsewhere silently defeats a narrow rule here.

**2. A policy is enforced at both ends.** An app reaching Postgres needs the
egress allow on the app side (`env-values/<env>/app-values.yaml.gotmpl`) *and* the ingress
allow on the database side (`20-database.yaml`). Miss either half and the
connection drops.

**3. Same-namespace traffic is not implicit.** Once any policy selects a pod,
traffic from its own namespace stops being allowed by default. Hence the
explicit `allow-intra-namespace` in each tier.

---

## 🔴 Naming: every platform-owned policy is prefixed `platform-`

**This is not cosmetic — it prevents a production outage.** Several charts emit
their own NetworkPolicy at prod, into the same namespace, using the release name
as the object name:

| Chart | Emits at prod | Would have collided with |
|---|---|---|
| `grafana` (`extraObjects`, `{{- if $isProd }}`) | `grafana` | `grafana` |
| `redis` (`networkPolicy.enabled: $isProd`) | `redis` | `redis` |
| `clickhouse` | `clickhouse`, `clickhouse-keeper` | `clickhouse` |
| `kafka` | `kafka-broker`, `kafka-controller` | — (escaped by naming luck) |

Two objects cannot share a name in a namespace. Whichever ran second lost:

- **kubectl first, then helm** → the release fails outright with *"resource
  already exists and is not owned by this release"*. Grafana, Redis and
  ClickHouse would not install at prod.
- **helm first, then kubectl** → `apply` silently seizes a Helm-managed object,
  and the next `helm upgrade` fights it back. Permanent drift.

Neither shows up at dev or staging, because both chart policies are gated behind
`$isProd`. It would have surfaced only on the prod rollout.

**Rule: any policy applied from this directory is named `platform-<workload>`.**
Chart-emitted policies keep their own names, the two layers union cleanly, and
`kubectl get netpol` shows at a glance who owns what.

---

## Two rules that will break the cluster if removed

**The three API-server paths.** The API server is **not a pod**, so no
`namespaceSelector` or `podSelector` can ever match it. Each of these is granted
by `ipBlock` from RFC1918 only — a control plane always reaches nodes from a
private address (in-VPC on EKS/GKE/AKS, the node IP on minikube/kubeadm), so
this stays portable while keeping the endpoints off the public internet.
**Narrow each to the real control-plane CIDR at prod**
(`kubectl get endpoints kubernetes -n default`):

| Rule | Port | What breaks without it |
|---|---|---|
| `platform-prometheus-operator` | 10250 | Every create/update of a `Prometheus`, `ServiceMonitor` or `PrometheusRule` fails (webhook enabled at staging/prod only) |
| `platform-vault-injector` | 8080 | The mutating webhook times out — pod creation stalls cluster-wide |
| `platform-keda-metrics-apiserver` | 6443 | **Silent.** KEDA-driven HPAs stop scaling, visible only as `FailedGetExternalMetric` on the HPA |

**The RFC1918 egress block** (`00-baseline.yaml`, observability) —
`namespaceSelector: {}` matches **pod** IPs only, never **node** IPs. Prometheus
scrapes kubelet (`:10250`) and node-exporter (`:9100`) at the *node* address,
because node-exporter is `hostNetwork: true`. Without those three private CIDRs,
egress-deny silently kills 4 of the stack's own targets while everything else
keeps working. Note this also means the `node-exporter` ingress policy is a
**no-op on Calico** — host-network traffic bypasses pod policy entirely.

---

## Adding app-specific rules on top of the baseline

When one workload needs more than its tier baseline, add a policy that selects
just that workload. The two union: baseline + extras, nothing else affected.

**Route depends on what the release is.** Not every chart can emit manifests:

| Release type | Where the extra policy goes | Example |
|---|---|---|
| In-house app (`charts/application`) | `networkPolicy.*` in `apps/<app>/values.yaml.gotmpl` | `apps/be-user/` |
| Upstream chart with `extraObjects` | that key in `platform/<tool>/values.yaml.gotmpl` | `monitoring/grafana/` |
| Upstream chart with `extraManifests` | that key | `kube-prometheus-stack/` |
| **Upstream chart with neither** | back here, in the tier file | **`minio/`** |

### In-house apps — use the chart interface, not raw YAML

`charts/application` already models this; policy ships with the service,
versioned and deployed with it:

```yaml
# apps/be-user/values.yaml.gotmpl
networkPolicy:
  enabled: true
  egress:
    enabled: true
    toNamespaces:
      - namespace: database
        ports: [ { protocol: TCP, port: 5432 } ]
  ingress:
    fromNamespaces: [ observability ]
```

### Upstream charts — extraObjects / extraManifests

```yaml
extraObjects:
  - apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata: { name: grafana-extra }
    spec:
      podSelector:
        matchLabels:
          app.kubernetes.io/name: grafana   # ← scope to THIS release only
      policyTypes: [ Ingress ]
      ingress:
        - from: [ { namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: infra } } } ]
          ports: [ { protocol: TCP, port: 3000 } ]
```

⚠ **Always set a `podSelector`.** A bare `podSelector: {}` applies to every pod
in the namespace, turning "extra access for one app" into "extra access for the
whole tier".

### What this pattern cannot do

Policies only widen. An app-level policy can grant access the baseline
withholds; it can never remove access the baseline grants.

- *"be-user also needs Kafka"* → app-level policy. Works.
- *"be-user must NOT reach Postgres, though other apps may"* → **impossible.**
  Remove the port from the tier rule and re-grant it per workload.

If you want the second shape often, the tier baseline is too broad.

---

## Label verification

A wrong selector does not error — it matches nothing, the workload keeps only
the namespace default-deny, and it becomes **unreachable**. Verify after every
chart bump:

```bash
kubectl -n <ns> get pods --show-labels
```

| Status | Workloads |
|---|---|
| ✅ Verified against running pods | the six monitoring workloads, `minio` (`app: minio`) |
| ⚠ Chart convention, **unverified** | `postgresql` `redis` `kafka` `clickhouse` |
| ⚠ Chart convention, **unverified** | `vault` `vault-agent-injector` `harbor` `falco` `keda-operator` `keda-metrics-apiserver` |

Everything in `50-security.yaml` is unverified — none of those four namespaces is
deployed on the cluster this was written against. **Roll them out one namespace
at a time**, checking labels first. Vault and KEDA carry API-server paths whose
failure is cluster-wide rather than local.

---

## Migration still outstanding

`allow-intra-namespace` in `10-monitoring.yaml` is the one deliberate
`podSelector: {}` left, and it is why Loki, Tempo, Mimir, Alloy, OTel-collector
and OpenSearch are reachable at all — none of them has a scoped rule yet. Give
each one a policy before removing it, or Grafana loses its datasources.

---

## Verify

```bash
kubectl get netpol -A

# The canary for over-tightening: every target still scraping
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/targets \
  | jq '[.data.activeTargets[] | select(.health!="up") | {job:.labels.job, err:.lastError}]'

# Which policies actually select a given pod
kubectl -n observability describe pod <pod> | grep -A3 Labels
```

> **⚠ Enforcement depends on the CNI.** The bridge/kindnet plugins that
> `minikube` and `kind` use by default **ignore NetworkPolicy entirely** —
> objects apply cleanly and block nothing. A green target list on minikube
> proves the YAML is valid and that nothing broke; it proves **nothing** about
> isolation, and it cannot catch a missing egress rule. Verify on Calico or
> Cilium (`minikube start --cni=calico`).

---

## Rollback

```bash
kubectl delete -f platform/network-policies/manifests/
```

Safe — removing policies only widens access. To revoke one flow during an
incident, delete that one object: `kubectl delete netpol minio -n database`.

To find what is being dropped before deleting anything: Calico flow logs
(`calico-node` → denied packets) or `hubble observe --verdict DROPPED` on Cilium.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Prometheus targets in one namespace all "down" | Missing scrape rule, or the exporter port is not in the workload's rule. |
| **kubelet + node-exporter targets down, others fine** | The RFC1918 egress block in `00-baseline.yaml` was removed or narrowed. Node IPs are not pod IPs. |
| `ServiceMonitor` create hangs, webhook timeout | `prometheus-operator` rule missing, or its `ipBlock` no longer covers the control plane. |
| Webhook timeouts cluster-wide | A default-deny was applied to `infra`. Remove it. |
| A workload is totally unreachable after a chart bump | Its policy's `podSelector` no longer matches — the labels changed. |
| App cannot reach Postgres/Redis/Kafka | Check both halves: `20-database.yaml` and `networkPolicy.egress` in `env-values/<env>/app-values.yaml.gotmpl`. |
| Alerts stop being delivered | Alertmanager's external egress rule — fails silently at the receiver. |
| Trivy reports everything CLEAN | Its vuln-DB egress is blocked; a scanner that cannot update reports clean. |
| Helm release fails: *"resource already exists and is not owned by this release"* | A policy here shares a name with one the chart emits. Everything applied from this directory must be `platform-`-prefixed. |
| KEDA HPAs stopped scaling, `FailedGetExternalMetric` | `platform-keda-metrics-apiserver` — the aggregation layer cannot reach `:6443`. |
| Pod creation stalls cluster-wide after enabling vault policies | `platform-vault-injector` — the mutating webhook is unreachable. |
| `vault login` via Kubernetes auth fails | Vault's egress to the API server (TokenReview) — `10.96.0.1:443` in its baseline. |
| Grafana starts but a datasource plugin is missing | Grafana's external HTTPS egress rule. |
| Policies applied but nothing is blocked | The CNI does not enforce NetworkPolicy. See the warning above. |

---

## Notes

- Env-agnostic: the same manifests apply to dev, staging and prod.
- Not managed by helmfile on purpose — they must be applied after every release
  is healthy, which helmfile's per-folder states cannot express.
- Namespace peers match on `kubernetes.io/metadata.name`, set automatically by
  the API server, so they work for the app namespaces Helm creates unlabelled.
- `infra` and `kube-system` have no policies, deliberately — both carry
  API-server-initiated traffic that a default-deny would break.
