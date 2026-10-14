# ExternalDNS — Deploy

> **Values live in [`infra-base/k8s/platform/external-dns/`](../../../infra-base/k8s/platform/external-dns/)**: `values.yaml.gotmpl` holds what every environment shares,
> `dev/` · `staging/` · `prod/` `values.yaml.gotmpl` what differs. This folder keeps the release
> (`helmfile.yaml.gotmpl`: chart, version, values list) and this runbook. Mentions of
> `values.yaml.gotmpl` below refer to those files.

Watches Ingress and Service objects and creates/updates DNS records in Route53 so
`*.<ingressDomain>` resolves without anyone editing a zone by hand.

| | |
|---|---|
| Chart | `external-dns/external-dns` |
| Version | `1.16.1` |
| Release / Namespace | `external-dns` / `infra` |
| Selector | `-l name=external-dns` |
| Labels | `layer=platform, tier=infra, component=dns` |
| Values | `values.yaml.gotmpl` |
| Provider | `aws` (Route53) |
| Replicas | 1 (dev/staging), 2 (prod) |

---

## 1. Prerequisites

| Requirement | Note |
|---|---|
| Route53 hosted zone for `<ingressDomain>` | dev/staging/prod each have their own domain in `env-values/environments.yaml` |
| **IRSA role** | `serviceAccount.annotations` contains `arn:aws:iam::<ACCOUNT_ID>:role/external-dns-<env>` — **replace the placeholder** |
| IAM permissions | `route53:ChangeResourceRecordSets`, `route53:ListHostedZones`, `route53:ListResourceRecordSets` |
| `kube-prometheus-stack` | ServiceMonitor CRD |

IRSA is preferred over static keys — with the annotation in place there is **no secret** to
manage. If you must use static credentials, add them via SOPS and set the provider env vars.

---

## 2. Ownership model (read before prod)

| Setting | Value | Effect |
|---|---|---|
| `policy` | `sync` | create **+ update + delete** records it owns |
| `registry` | `txt` | ownership tracked in TXT records |
| `txtOwnerId` | `k8s-<env>` | **must be unique per cluster/env** |
| `txtPrefix` | `_extdns-` | TXT record naming |
| `domainFilters` | `<ingressDomain>` | restricts the blast radius to this env's zone |
| `sources` | `ingress`, `service` | what it watches |

With `policy: sync`, ExternalDNS **deletes** records — but only ones carrying its own TXT
ownership marker. Two clusters sharing a `txtOwnerId` will fight and delete each other's
records. Verify `txtOwnerId` uniqueness before pointing a second cluster at the same zone.

---

## 3. Deploy

```bash
export ENV=dev
helmfile -e $ENV -f platform/external-dns/helmfile.yaml.gotmpl diff
helmfile -e $ENV -f platform/external-dns/helmfile.yaml.gotmpl sync
```

Annotate a Service/Ingress to get a record:

```yaml
annotations:
  external-dns.alpha.kubernetes.io/hostname: api.dev.example.com
```

`kong` already does this for `api.<ingressDomain>`.

---

## 4. Verify

```bash
kubectl -n infra rollout status deploy/external-dns --timeout=180s
kubectl -n infra logs deploy/external-dns --tail=50 | grep -iE 'CREATE|UPDATE|DELETE|error'

# what it actually did in Route53
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID> \
  --query "ResourceRecordSets[?contains(Name, 'dev.example.com')].[Name,Type]" --output table

dig +short api.dev.example.com
```

Dry-run style check before trusting it in a new zone: set `policy: upsert-only` for the
first sync, confirm the records it creates, then switch to `sync`.

---

## 5. Rollback

```bash
helm history external-dns -n infra
helm rollback external-dns <REVISION> -n infra --wait
```

- Rolling back **does not** revert DNS changes already made. Fix bad records in Route53
  directly, or via the source Ingress/Service annotation.
- If ExternalDNS deleted records it should not have, the cause is almost always a changed
  `txtOwnerId` or `domainFilters` — restore the records manually and fix the config before
  re-syncing.
- Scaling to 0 is the fastest way to stop it doing further damage during an incident:
  ```bash
  kubectl -n infra scale deploy external-dns --replicas=0
  ```

---

## 6. Monitoring & alerting

`serviceMonitor.enabled: true` (`release: kube-prometheus-stack`).

| Signal | Metric |
|---|---|
| Registry/provider errors | `external_dns_registry_errors_total`, `external_dns_source_errors_total` |
| Last successful sync | `external_dns_controller_last_sync_timestamp_seconds` staleness > 10m |
| Records managed | `external_dns_registry_endpoints_total` — a sudden drop means mass deletion |
| Route53 throttling | provider errors + AWS API 400s in logs |

Alert on the sudden-drop case. Mass record deletion is fast, quiet, and user-visible.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No records created | Resource missing the hostname annotation, or the host is outside `domainFilters`. |
| `AccessDenied` in logs | IRSA placeholder not replaced, or the role lacks Route53 permissions. |
| Records created then deleted in a loop | Two ExternalDNS instances sharing a `txtOwnerId` — give each cluster its own. |
| Record points at the wrong LB | Two Services claim the same hostname. |
| Stale record after deleting an Ingress | `policy` was `upsert-only`, which never deletes. |
| Nothing happens for minutes | `interval: 1m` + `triggerLoopOnEvent: true` should be near-instant; a stuck loop usually means provider throttling. |

---

## 8. Notes

- Hardened: runs as non-root UID 65534, read-only root filesystem, all capabilities dropped.
- Managed record types are limited to `A`, `AAAA`, `CNAME` — it will not touch MX/TXT records
  it does not own.
- Pairs with cert-manager: DNS must resolve to the ingress before HTTP-01 validation can
  succeed, so a broken ExternalDNS shows up as stuck ACME challenges.
