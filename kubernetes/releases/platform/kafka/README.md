# Kafka — Deploy

> **Values live in [`environments/<env>/kubernetes/tools/kafka/`](../../../../environments/dev/kubernetes/tools/kafka/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Event streaming backbone (KRaft mode, no ZooKeeper). Producers/consumers reach it at
`kafka.database.svc.cluster.local:9092`; `be-notification` consumes the `notifications`
topic and scales on lag via KEDA.

| | |
|---|---|
| Chart | `bitnami/kafka` |
| Version | `32.2.10` |
| Release / Namespace | `kafka` / `database` |
| Selector | `-l name=kafka` |
| Labels | `layer=platform, tier=infra, component=streaming` |
| Values | `values.yaml.gotmpl` + `files/server.properties` |
| Secrets | `.Values.secrets.kafka.{clientPassword,interBrokerPassword,controllerPassword}` |

| Env | Brokers | Controllers | RF | min.insync | Storage |
|---|---|---|---|---|---|
| dev | 1 | 1 | 1 | 1 | 10Gi |
| staging | 1 | 1 | 1 | 1 | 20Gi |
| prod | 3 | 3 | 3 | 2 | 100Gi |

---

## 1. Prerequisites

| Requirement | Note |
|---|---|
| `database` namespace | `environments/<env>/kubernetes/namespace/namespaces.yaml` |
| SOPS keys | three passwords under `secrets.kafka` |
| Storage | prod needs 3×100Gi on separate nodes |
| Bitnami mirror for prod | see `releases/platform/postgresql/README.md` |
| KEDA (if scaling on lag) | `keda` |

> **Security note:** listeners are `SASL_PLAINTEXT` today — authenticated but
> **not encrypted**. Traffic stays inside the cluster network, but for prod you should
> move to `SASL_SSL` with cert-manager-issued certs. Treat this as a known gap, not a
> finished state.

---

## 2. Configuration map

| Where | Owns |
|---|---|
| `files/server.properties` | static broker tunables (read via `readFile` into `extraConfig`) |
| `$size` table in values | replication factor, ISR, retention, sizing per env |
| SOPS | SASL passwords, rendered into the `kafka` Secret via `extraDeploy` |

SASL mechanisms: `SCRAM-SHA-256,PLAIN`; the application user is `appuser`.

---

## 3. Deploy

```bash
export ENV=dev
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

helmfile -e $ENV -f releases/platform/kafka/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f releases/platform/kafka/helmfile.yaml.gotmpl sync
```

Prod deploys split controller and broker roles; dev/staging run a single combined node.
**Switching between combined and split KRaft roles is not an in-place upgrade** — plan a
migration, or rebuild the cluster in non-prod.

---

## 4. Verify

```bash
kubectl -n database rollout status statefulset/kafka-broker --timeout=600s
kubectl -n database get pods -l app.kubernetes.io/name=kafka

# KRaft quorum
kubectl -n database exec -it kafka-controller-0 -- \
  kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status

# produce/consume smoke test (SASL)
kubectl -n database exec -it kafka-broker-0 -- bash -c '
cat >/tmp/client.properties <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="appuser" password="'"$KAFKA_CLIENT_PASSWD"'";
EOF
kafka-topics.sh --bootstrap-server localhost:9092 --command-config /tmp/client.properties --list'
```

Prod checklist: `--describe` each critical topic and confirm `ReplicationFactor: 3`,
`min.insync.replicas=2`, and no under-replicated partitions.

---

## 5. Rollback

```bash
helm history kafka -n database
helm rollback kafka <REVISION> -n database --wait --timeout 15m
```

⚠ Rolling **back** a broker count is destructive: partitions hosted only on the removed
brokers become unavailable. Reassign partitions first:

```bash
kafka-reassign-partitions.sh --bootstrap-server ... --generate --topics-to-move-json-file topics.json
```

Message data lives in the PVCs and survives a rollback; it does **not** survive a PVC
delete.

---

## 6. Monitoring & alerting

| Signal | Metric |
|---|---|
| Under-replicated partitions | `kafka_server_replicamanager_underreplicatedpartitions` > 0 — page on this |
| Offline partitions | `kafka_controller_kafkacontroller_offlinepartitionscount` > 0 |
| Consumer lag | `kafka_consumergroup_lag` (also the KEDA scaling signal) |
| ISR shrink rate | `kafka_server_replicamanager_isrshrinks_total` |
| Disk | PVC used % > 75 (log retention is the usual cause) |
| Active controller | exactly `1` across the cluster |

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Client `SaslAuthenticationException` | Password mismatch between the app's SOPS secret and `secrets.kafka.clientPassword`. |
| `NOT_ENOUGH_REPLICAS` on produce | Fewer in-sync replicas than `min.insync.replicas` — a broker is down; fix the broker, do not lower ISR in prod. |
| Broker won't start after node loss | KRaft metadata/log dir mismatch. Check the pod's `meta.properties` and cluster id. |
| Consumer lag climbing with no errors | Consumer is slower than producers — scale it (KEDA) or add partitions. |
| Disk full, broker `CrashLoopBackOff` | Retention too long. Reduce `log.retention.*` in `files/server.properties`, then restart. |

---

## 8. Notes / risks

- Partition count can only go **up**. Size topics deliberately; adding partitions later
  changes key→partition mapping and breaks ordering guarantees for existing keys.
- For a large prod estate, the **Strimzi** operator gives you rolling upgrades, rebalancing
  (Cruise Control) and topic CRs — this chart is fine for a single-team workload.
- Kafka is the async backbone: an outage here does not take the API down but silently
  stops fan-out work. Alert on consumer lag, not just broker health.
