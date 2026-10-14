# ec2

## Usage

```hcl
module "ec2" {
  source = "../../modules/ec2"

  name               = local.name_prefix
  security_group_ids = [module.security_groups.ecs_sg_id]

  tags               = local.tags
}
```

Every input not listed above has a default — 5 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Name prefix. Each instance is named "<name>-<key>". |
| `security_group_ids` | `list(string)` | Security groups applied to every instance. From module.security_groups.ec2_sg_id. |

## Outputs

| Name | Description |
|---|---|
| `instance_ids` | Map of instance key to instance ID. |
| `instance_arns` | Map of instance key to ARN. |
| `private_ips` | Map of instance key to private IP. |
| `private_dns` | Map of instance key to private DNS name. |
| `availability_zones` | Map of instance key to the AZ it landed in. |
| `ami_id` | AMI resolved for instances that did not pin one, or null when every instance pinned its own. |
| `session_manager_commands` | The aws CLI command that opens a shell on each instance without SSH, a key pair or an inbound rule. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
