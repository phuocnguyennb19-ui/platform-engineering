# rds

## Usage

```hcl
module "rds" {
  source = "../../modules/rds"

  identifier           = local.name_prefix
  engine_version       = "16.4"
  family               = "postgres16"
  major_engine_version = "16"
  db_subnet_group_name = module.vpc.database_subnet_group_name
  security_group_ids   = [module.security_groups.ecs_sg_id]

  tags                 = local.tags
}
```

Every input not listed above has a default — 30 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `identifier` | `string` | DB instance identifier, e.g. "dev-postgres". |
| `engine_version` | `string` | Engine version, e.g. "16.4" for PostgreSQL or "8.0.39" for MySQL. |
| `family` | `string` | Parameter group family, e.g. "postgres16" or "mysql8.0". Must match engine_version's major — a mismatch is rejected at apply, not at plan. |
| `major_engine_version` | `string` | Major engine version for the option group, e.g. "16" or "8.0". |
| `db_subnet_group_name` | `string` | DB subnet group. From module.vpc.database_subnet_group_name. Those subnets have no internet gateway route and no NAT route, so the database has no path to or from the internet regardless of what a security group says. |
| `security_group_ids` | `list(string)` | Security groups for the instance. From module.security_groups.rds_sg_id, which allows the database port from the application tiers and nothing else. |

## Outputs

| Name | Description |
|---|---|
| `instance_id` | DB instance identifier. |
| `instance_arn` | DB instance ARN. |
| `endpoint` | Connection endpoint in host:port form. |
| `address` | Hostname of the instance, without the port. |
| `port` | Port the instance listens on. |
| `database_name` | Name of the initial database. |
| `username` | Master username. The password is not an output of this module and never exists in Terraform state — read it from master_user_secret_arn. |
| `master_user_secret_arn` |  |
| `parameter_group_name` | DB parameter group name. |
| `cloudwatch_log_groups` | CloudWatch log groups the instance exports to. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
