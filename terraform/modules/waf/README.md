# waf

A WAFv2 web ACL built from AWS managed rule groups and an optional per-IP rate limit. Wraps
`terraform-aws-wafv2` (v1.1.0).

The default is the AWS baseline — `AWSManagedRulesCommonRuleSet`,
`AWSManagedRulesKnownBadInputsRuleSet`, `AWSManagedRulesAmazonIpReputationList` — blocking.
Introduce a new group with `count_only = true`, read the sampled requests, then let it block.
CloudWatch metrics and sampled requests are always on.

## Usage

```hcl
module "waf" {
  source = "../../modules/waf"

  name       = "platform-prod"
  rate_limit = 2000

  associate_resource_arns = { alb = module.alb.arn }

  tags = local.tags
}
```

Every input not listed below has a default — 7 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Web ACL name. |

## Outputs

| Name | Description |
|---|---|
| `web_acl_arn` | Web ACL ARN. |
| `web_acl_id` | Web ACL ID. |
| `web_acl_capacity` | WCUs the rules consume (the limit is 5000 per web ACL). |

## Tests

`tests/waf.tftest.hcl` — `terraform init -backend=false && terraform test` (Terraform ≥ 1.7).
