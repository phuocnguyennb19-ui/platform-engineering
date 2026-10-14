# elasticache

## Usage

```hcl
module "elasticache" {
  source = "../../modules/elasticache"

  name               = local.name_prefix
  subnet_group_name  = module.vpc.elasticache_subnet_group_name
  security_group_ids = [module.security_groups.ecs_sg_id]

  tags               = local.tags
}
```

Every input not listed above has a default — 24 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Replication group identifier, e.g. "dev-redis". |
| `subnet_group_name` | `string` | ElastiCache subnet group. From module.vpc.elasticache_subnet_group_name, which spans the database subnets — no internet route in either direction. |
| `security_group_ids` | `list(string)` | Security groups for the cache nodes. From module.security_groups.elasticache_sg_id. |

## Outputs

| Name | Description |
|---|---|
| `replication_group_id` | Replication group ID. |
| `arn` | Replication group ARN. |
| `primary_endpoint_address` | Primary endpoint for writes, when cluster mode is off. Null in cluster mode — use configuration_endpoint_address. |
| `reader_endpoint_address` | Reader endpoint, which load-balances across replicas. Null in cluster mode. |
| `configuration_endpoint_address` | Configuration endpoint, used by cluster-mode clients. Null when cluster mode is off. |
| `port` | Port the cache listens on. |
| `member_clusters` | Individual cache cluster IDs in the group. |
| `parameter_group_name` | Parameter group name. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
