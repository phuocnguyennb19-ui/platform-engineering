# security-groups

## Usage

```hcl
module "security_groups" {
  source = "../../modules/security-groups"

  name           = local.name_prefix
  vpc_id         = module.vpc.vpc_id
  vpc_cidr_block = module.vpc.vpc_cidr_block

  tags           = local.tags
}
```

Every input not listed above has a default — 17 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Name prefix for every security group, conventionally "<project>-<environment>". |
| `vpc_id` | `string` | VPC the security groups belong to. Comes from the foundation: module.vpc.vpc_id. |
| `vpc_cidr_block` | `string` | VPC CIDR. Used only where a security group reference is impossible — ALB egress to targets, whose port varies per target group. |

## Outputs

| Name | Description |
|---|---|
| `alb_sg_id` | ALB security group ID. Consumed by the alb module. |
| `eks_cluster_sg_id` | EKS control plane security group ID. Consumed by the eks module as an additional cluster security group. |
| `eks_node_sg_id` | EKS node security group ID. Consumed by the eks module as an additional node security group. |
| `ec2_sg_id` | EC2 application security group ID. Consumed by the ec2 module. |
| `ecs_sg_id` | ECS task security group ID. Consumed by the ecs-service module as security_group_ids. |
| `rds_sg_id` | RDS security group ID. Consumed by the rds module. |
| `elasticache_sg_id` | ElastiCache security group ID. Consumed by the elasticache module. |
| `lambda_sg_id` | Lambda security group ID. Consumed by the lambda module for VPC-attached functions. |
| `bastion_sg_id` | Bastion security group ID. |
| `security_group_ids` | All security group IDs by logical name. Null for any group not created in this environment. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
