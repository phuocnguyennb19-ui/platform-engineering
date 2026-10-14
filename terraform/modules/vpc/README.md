# vpc

## Usage

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name       = local.name_prefix
  cidr_block = "10.0.0.0/16"

  tags       = local.tags
}
```

Every input not listed above has a default — 23 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Name prefix for the VPC and every subnet, route table and gateway inside it. Conventionally "<project>-<environment>". |
| `cidr_block` | `string` | IPv4 CIDR for the VPC. A /16 gives the default subnet layout room to grow; anything smaller than /20 will not fit three tiers across three AZs. |

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | VPC ID. Consumed by security-groups, alb, eks, rds, elasticache and lambda. |
| `vpc_arn` | VPC ARN. |
| `vpc_cidr_block` | VPC IPv4 CIDR. Used for intra-VPC security group rules where an SG reference is not possible. |
| `azs` | Availability zones the subnets were spread across, in order. |
| `public_subnet_ids` | Public subnet IDs, one per AZ. Internet-facing load balancers and NAT gateways only — never an instance or a database. |
| `private_subnet_ids` | Private application subnet IDs, one per AZ. EKS nodes, EC2 instances and Lambda ENIs live here. Egress via NAT, no inbound route from the internet. |
| `database_subnet_ids` | Database subnet IDs, one per AZ. No internet route in either direction. RDS and ElastiCache only. |
| `public_subnet_cidrs` | Public subnet CIDRs. |
| `private_subnet_cidrs` | Private application subnet CIDRs. |
| `database_subnet_cidrs` | Database subnet CIDRs. |
| `database_subnet_group_name` | RDS DB subnet group name. Passing this to the RDS module is what structurally prevents a database from being placed in a public subnet. |
| `elasticache_subnet_group_name` | ElastiCache subnet group name, or null when create_elasticache_subnet_group is false. |
| `internet_gateway_id` | Internet gateway ID. |
| `nat_gateway_ids` | NAT gateway IDs. Empty when enable_nat_gateway is false. |
| `nat_public_ips` | Elastic IPs of the NAT gateways. These are the source addresses partners must allowlist for outbound calls from private workloads. |
| `public_route_table_ids` | Public route table IDs. |
| `private_route_table_ids` | Private route table IDs. |
| `database_route_table_ids` | Database route table IDs. |
| `default_security_group_id` | The VPC's default security group. This module strips all of its rules; nothing should ever be attached to it. |
| `flow_log_id` | VPC flow log ID, or null when flow logs are disabled. |
| `flow_log_destination_arn` | ARN of the destination flow logs are delivered to — the CloudWatch log group ARN in the default configuration. Upstream exposes no separate log group name output. |
| `flow_log_cloudwatch_iam_role_arn` | Role the flow log service assumes to write to CloudWatch Logs. |
| `s3_gateway_endpoint_id` | S3 gateway VPC endpoint ID, or null when disabled. |
| `dynamodb_gateway_endpoint_id` | DynamoDB gateway VPC endpoint ID, or null when disabled. |
| `interface_endpoint_ids` | Map of service name to interface VPC endpoint ID. |
| `interface_endpoint_security_group_id` | Security group this module created for the interface endpoints, or null when none was needed. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
