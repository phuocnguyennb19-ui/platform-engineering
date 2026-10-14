# iam

## Usage

```hcl
module "iam" {
  source = "../../modules/iam"

  name = local.name_prefix

  tags = local.tags
}
```

Every input not listed above has a default — 11 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Name prefix for every role and policy, conventionally "<project>-<environment>". |

## Outputs

| Name | Description |
|---|---|
| `ec2_instance_role_arn` | EC2 instance role ARN. |
| `ec2_instance_role_name` | EC2 instance role name. |
| `ec2_instance_profile_name` | EC2 instance profile name. Consumed by the ec2 module as iam_instance_profile. |
| `ec2_instance_profile_arn` | EC2 instance profile ARN. |
| `rds_monitoring_role_arn` | RDS Enhanced Monitoring role ARN. Consumed by the rds module as monitoring_role_arn. |
| `additional_role_arns` | Map of additional role key to ARN. |
| `additional_role_names` | Map of additional role key to name. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
