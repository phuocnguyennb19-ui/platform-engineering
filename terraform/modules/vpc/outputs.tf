output "vpc_id" {
  description = "VPC ID. Consumed by security-groups, alb, eks, rds, elasticache and lambda."
  value       = module.vpc.vpc_id
}

output "vpc_arn" {
  description = "VPC ARN."
  value       = module.vpc.vpc_arn
}

output "vpc_cidr_block" {
  description = "VPC IPv4 CIDR. Used for intra-VPC security group rules where an SG reference is not possible."
  value       = module.vpc.vpc_cidr_block
}

output "azs" {
  description = "Availability zones the subnets were spread across, in order."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs, one per AZ. Internet-facing load balancers and NAT gateways only — never an instance or a database."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Private application subnet IDs, one per AZ. EKS nodes, EC2 instances and Lambda ENIs live here. Egress via NAT, no inbound route from the internet."
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "Database subnet IDs, one per AZ. No internet route in either direction. RDS and ElastiCache only."
  value       = module.vpc.database_subnets
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDRs."
  value       = module.vpc.public_subnets_cidr_blocks
}

output "private_subnet_cidrs" {
  description = "Private application subnet CIDRs."
  value       = module.vpc.private_subnets_cidr_blocks
}

output "database_subnet_cidrs" {
  description = "Database subnet CIDRs."
  value       = module.vpc.database_subnets_cidr_blocks
}

output "database_subnet_group_name" {
  description = "RDS DB subnet group name. Passing this to the RDS module is what structurally prevents a database from being placed in a public subnet."
  value       = module.vpc.database_subnet_group_name
}

output "elasticache_subnet_group_name" {
  description = "ElastiCache subnet group name, or null when create_elasticache_subnet_group is false."
  value       = one(aws_elasticache_subnet_group.this[*].name)
}

output "internet_gateway_id" {
  description = "Internet gateway ID."
  value       = module.vpc.igw_id
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs. Empty when enable_nat_gateway is false."
  value       = module.vpc.natgw_ids
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT gateways. These are the source addresses partners must allowlist for outbound calls from private workloads."
  value       = module.vpc.nat_public_ips
}

output "public_route_table_ids" {
  description = "Public route table IDs."
  value       = module.vpc.public_route_table_ids
}

output "private_route_table_ids" {
  description = "Private route table IDs."
  value       = module.vpc.private_route_table_ids
}

output "database_route_table_ids" {
  description = "Database route table IDs."
  value       = module.vpc.database_route_table_ids
}

output "default_security_group_id" {
  description = "The VPC's default security group. This module strips all of its rules; nothing should ever be attached to it."
  value       = module.vpc.default_security_group_id
}

output "flow_log_id" {
  description = "VPC flow log ID, or null when flow logs are disabled."
  value       = module.vpc.vpc_flow_log_id
}

output "flow_log_destination_arn" {
  description = "ARN of the destination flow logs are delivered to — the CloudWatch log group ARN in the default configuration. Upstream exposes no separate log group name output."
  value       = module.vpc.vpc_flow_log_destination_arn
}

output "flow_log_cloudwatch_iam_role_arn" {
  description = "Role the flow log service assumes to write to CloudWatch Logs."
  value       = module.vpc.vpc_flow_log_cloudwatch_iam_role_arn
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway VPC endpoint ID, or null when disabled."
  value       = one(aws_vpc_endpoint.s3[*].id)
}

output "dynamodb_gateway_endpoint_id" {
  description = "DynamoDB gateway VPC endpoint ID, or null when disabled."
  value       = one(aws_vpc_endpoint.dynamodb[*].id)
}

output "interface_endpoint_ids" {
  description = "Map of service name to interface VPC endpoint ID."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "interface_endpoint_security_group_id" {
  description = "Security group this module created for the interface endpoints, or null when none was needed."
  value       = one(aws_security_group.endpoints[*].id)
}
