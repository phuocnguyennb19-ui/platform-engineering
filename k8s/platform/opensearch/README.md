# OpenSearch — Deploy

> **Values live in [`infra-base/k8s/platform/opensearch/`](../../../infra-base/k8s/platform/opensearch/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Search / log-analytics cluster (StatefulSet). Used for full-text search over logs and as a
Grafana datasource, alongside Loki.

| | |
|---|---|
| Chart | `opensearch/opensearch` |
| Version | `3.7.0` |
| Release / Namespace | `opensearch` / `observability` |
| Selector | `-l name=opensearch` |
| Labels | `layer=platform, tier=infra, component=search` |
| Values | `values.yaml.gotmpl` |
| Service name | `opensearch-cluster-master` (port 9200) |

| Env | Nodes | Heap | Storage | HA |
|---|---|---|---|---|
| dev | 1 (`singleNode`) | 512m | 20Gi | no |
| staging | 3 | 1g | 50Gi | PDB + anti-affinity |
| prod | 3 | 2g | 200Gi | PDB + anti-affinity |

---

## 1. Prerequisites

| Requirement | Note |
|---|---|
| `kube-prometheus-stack` | ServiceMonitor CRD |
| StorageClass | 3× PVC for staging/prod |
| Node `vm.max_map_count=262144` | required by Lucene; usually set by the chart's sysctl init container — verify on managed node images |
| Memory headroom | heap is ~50% of the container limit; do not let heap exceed 31g |
| **TLS + admin password** | see the security warning below |

> ⚠ **The chart ships DEMO TLS certificates and a default admin password.** That is
> acceptable for dev only. For staging/prod you **must**:
> 1. provide real node/admin certs via a Secret (cert-manager can issue them), and
> 2. set `OPENSEARCH_INITIAL_ADMIN_PASSWORD` from the SOPS secret
>    (`secrets.opensearch.password`, already used by `opensearch-dashboards`).
> Shipping demo certs to prod means anyone in the cluster network can authenticate as admin.

---

## 2. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f platform/opensearch/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/opensearch/helmfile.yaml.gotmpl sync
```

`opensearch-dashboards` and `grafana` both declare `needs` on this release.

---

## 3. Verify

```bash
kubectl -n observability rollout status statefulset/opensearch-cluster-master --timeout=900s

PASS=$(kubectl -n observability get secret opensearch-admin -o jsonpath='{.data.password}' | base64 -d)
kubectl -n observability port-forward svc/opensearch-cluster-master 9200:9200 &

curl -sk -u "admin:$PASS" https://localhost:9200/_cluster/health?pretty
curl -sk -u "admin:$PASS" https://localhost:9200/_cat/nodes?v
curl -sk -u "admin:$PASS" https://localhost:9200/_cat/indices?v
```

Expected `status: green` (staging/prod). `yellow` on a single-node dev cluster is normal —
replicas cannot be allocated with one node.

---

## 4. Rollback

```bash
helm history opensearch -n observability
helm rollback opensearch <REVISION> -n observability --wait --timeout 20m
```

- **Scaling down node count is destructive** if shards have no other copy. Check
  `_cat/shards` before reducing replicas, and use shard allocation filtering to drain a
  node first.
- StatefulSet PVCs survive a rollback and an uninstall. Deleting them deletes the indices.
- A major-version rollback of OpenSearch is **not supported** — indices written by a newer
  version cannot be read by an older one. Snapshot before upgrading:

```bash
curl -sk -u "admin:$PASS" -XPUT https://localhost:9200/_snapshot/backup/snap-$(date +%F)?wait_for_completion=true
```

---

## 5. Monitoring & alerting

| Signal | Metric / check |
|---|---|
| Cluster status | `opensearch_cluster_status` (green=0/yellow=1/red=2) — page on red |
| Unassigned shards | `opensearch_cluster_shards_number{type="unassigned"}` > 0 |
| JVM heap pressure | `opensearch_jvm_mem_heap_used_percent` > 85 |
| GC time | `opensearch_jvm_gc_collection_seconds_sum` rate |
| Disk watermark | PVC used % > 75 (OpenSearch stops allocating at 85%) |
| Rejected bulk requests | `opensearch_threadpool_rejected_count{name="write"}` |

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pods `CrashLoopBackOff` with `max virtual memory areas too low` | `vm.max_map_count` not set on the node — enable the sysctl init container or set it on the node image. |
| Cluster `red` | Primary shards unassigned: `_cluster/allocation/explain` tells you why (usually disk watermark or a lost node). |
| Bootstrap fails in staging/prod | Quorum settings — 3 master-eligible nodes must all come up; check PVC binding. |
| Dashboards cannot log in | Password mismatch with `secrets.opensearch.password`, or TLS verification mode (`full` outside dev) failing against demo certs. |
| Heap OOM | Heap must stay ≈50% of the memory limit and below 31g. Do not raise heap to the container limit. |
| Slow queries after a big ingest | Merge pressure — check `_cat/segments` and consider force-merging read-only indices. |

---

## 7. Notes

- Two log stores coexist by design: **Loki** for cheap label-based grep/tail, **OpenSearch**
  for full-text search and analytics. Do not double-ship everything to both without a reason
  — it doubles cost.
- Set up **ISM policies** (rollover + delete) before real volume arrives; without them the
  disk watermark will find you first.
- Anti-affinity is on for staging/prod: 3 nodes need 3 schedulable Kubernetes nodes.
