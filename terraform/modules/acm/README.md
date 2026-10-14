# acm

## Usage

```hcl
module "acm" {
  source = "../../modules/acm"

  domain_name = "api.example.com"
  zone_id     = module.route53.zone_id

  tags        = local.tags
}
```

Every input not listed above has a default — 6 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `domain_name` | `string` | Primary domain for the certificate, e.g. "app.example.com" or "*.example.com". |
| `zone_id` | `string` | Route53 hosted zone ID where the DNS validation records are written. Comes from the route53 module. |

## Outputs

| Name | Description |
|---|---|
| `certificate_arn` | Certificate ARN. Consumed by the alb module's HTTPS listener. |
| `certificate_domain_name` | Primary domain on the certificate. |
| `certificate_domain_names` | Every distinct name the certificate covers, primary plus SANs. |
| `certificate_status` | Certificate status — ISSUED once validation completes. |
| `validation_record_fqdns` | FQDNs of the DNS validation records. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
