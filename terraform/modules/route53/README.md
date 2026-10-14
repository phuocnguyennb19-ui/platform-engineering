# route53

## Usage

```hcl
module "route53" {
  source = "../../modules/route53"

  zone_name = "example.com"

  tags      = local.tags
}
```

Every input not listed above has a default — 6 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `zone_name` | `string` | Hosted zone name, e.g. "example.com". Used to create the zone when create_zone is true, and to look it up when false. |

## Outputs

| Name | Description |
|---|---|
| `zone_id` | Hosted zone ID, whether created here or looked up. Consumed by the acm module for DNS validation. |
| `zone_name` | Hosted zone name. |
| `zone_arn` | Hosted zone ARN, or null when the zone was looked up rather than created. |
| `name_servers` | Nameservers for the zone. When this module creates a delegated subdomain zone, these are the NS records that must be added to the parent zone — until they are, nothing in this zone resolves. |
| `record_fqdns` | Map of record key to fully qualified domain name. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
