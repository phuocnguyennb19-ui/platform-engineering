# cloudwatch

## Usage

```hcl
module "cloudwatch" {
  source = "../../modules/cloudwatch"

  name = local.name_prefix

  tags = local.tags
}
```

Every input not listed above has a default — 9 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Name prefix, conventionally "<project>-<environment>". |

## Outputs

| Name | Description |
|---|---|
| `sns_topic_arn` | SNS topic every alarm publishes to — the one created here, or the one passed in via sns_topic_arn. |
| `sns_topic_name` | Name of the created SNS topic, or null when an existing topic was supplied. |
| `log_group_names` | Map of log group key to name. |
| `log_group_arns` | Map of log group key to ARN. |
| `alarm_arns` | Map of alarm key to ARN. |
| `alarm_names` | Map of alarm key to name. |
| `dashboard_name` | CloudWatch dashboard name, or null when not created. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
