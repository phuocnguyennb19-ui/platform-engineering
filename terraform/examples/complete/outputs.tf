output "environment" {
  description = "Environment name."
  value       = var.environment
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "name_prefix" {
  description = "Prefix every resource in this environment is named with."
  value       = local.name_prefix
}

output "enabled_workloads" {
  description = "Which workloads this environment has switched on. The quickest answer to \"what is actually deployed here\"."
  value = {
    alb         = var.enable_alb
    eks         = var.enable_eks
    ec2         = var.enable_ec2
    rds         = var.enable_rds
    elasticache = var.enable_elasticache
    lambda      = var.enable_lambda
    ecr         = var.enable_ecr
    route53     = var.enable_route53
    acm         = var.enable_acm
  }
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR."
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs — load balancers and NAT gateways."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private application subnet IDs — EKS nodes, EC2, Lambda ENIs."
  value       = module.vpc.private_subnet_ids
}

output "database_subnet_ids" {
  description = "Database subnet IDs — no internet route in either direction."
  value       = module.vpc.database_subnet_ids
}

output "availability_zones" {
  description = "Availability zones in use."
  value       = module.vpc.azs
}

output "nat_public_ips" {
  description = "NAT gateway elastic IPs — the source addresses a partner must allowlist for outbound calls from this environment."
  value       = module.vpc.nat_public_ips
}

output "security_group_ids" {
  description = "All platform security group IDs by logical name."
  value       = module.security_groups.security_group_ids
}

output "kms_key_arns" {
  description = "Customer-managed KMS key ARNs by purpose."
  value       = module.kms.key_arns
}

output "ec2_instance_profile_name" {
  description = "Instance profile EC2 instances run with."
  value       = module.iam.ec2_instance_profile_name
}

output "alarm_topic_arn" {
  description = "SNS topic every CloudWatch alarm publishes to."
  value       = module.cloudwatch.sns_topic_arn
}

output "log_group_names" {
  description = "Managed CloudWatch log groups."
  value       = module.cloudwatch.log_group_names
}

output "ecr_repository_urls" {
  description = "ECR repository URLs by key, or null when ECR is disabled."
  value       = one(module.ecr[*].repository_urls)
}

output "route53_zone_id" {
  description = "Hosted zone ID, or null when DNS is not managed here."
  value       = one(module.route53[*].zone_id)
}

output "route53_name_servers" {
  description = "Zone nameservers. When this environment created a delegated subdomain zone, these NS records must be added to the parent zone before anything resolves."
  value       = one(module.route53[*].name_servers)
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN, or null when no certificate is issued here."
  value       = one(module.acm[*].certificate_arn)
}

output "alb_dns_name" {
  description = "ALB DNS name, or null when the ALB is disabled."
  value       = one(module.alb[*].dns_name)
}

output "alb_target_group_arns" {
  description = "ALB target group ARNs by key. An autoscaling group consumes these as target_group_arns."
  value       = one(module.alb[*].target_group_arns)
}

output "alb_access_logs_bucket" {
  description = "S3 bucket receiving ALB access logs."
  value       = one(module.alb[*].access_logs_bucket)
}

output "application_url" {
  description = "URL the application is published under, or null when DNS or the ALB is disabled."
  value       = local.app_fqdn != null && var.enable_alb ? "https://${local.app_fqdn}" : null
}

output "eks_cluster_name" {
  description = "EKS cluster name, or null when EKS is disabled."
  value       = one(module.eks[*].cluster_name)
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = one(module.eks[*].cluster_endpoint)
}

output "eks_oidc_provider_arn" {
  description = "OIDC provider ARN, needed to write an IRSA trust policy outside this stack."
  value       = one(module.eks[*].oidc_provider_arn)
}

output "eks_irsa_role_arns" {
  description = "IRSA role ARNs by key. Annotate a ServiceAccount with eks.amazonaws.com/role-arn set to one of these."
  value       = one(module.eks[*].irsa_role_arns)
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for this cluster."
  value       = one(module.eks[*].kubeconfig_command)
}

output "ec2_instance_ids" {
  description = "EC2 instance IDs by key."
  value       = one(module.ec2[*].instance_ids)
}

output "ec2_private_ips" {
  description = "EC2 private IPs by key."
  value       = one(module.ec2[*].private_ips)
}

output "ec2_session_manager_commands" {
  description = "Commands that open a shell on each instance without SSH, a key pair or an inbound rule."
  value       = one(module.ec2[*].session_manager_commands)
}

output "rds_endpoint" {
  description = "RDS connection endpoint, or null when RDS is disabled."
  value       = one(module.rds[*].endpoint)
}

output "rds_port" {
  description = "RDS port."
  value       = one(module.rds[*].port)
}

output "rds_database_name" {
  description = "Initial database name."
  value       = one(module.rds[*].database_name)
}

output "rds_master_user_secret_arn" {
  description = <<-EOT
    ARN of the AWS-managed Secrets Manager secret holding the database master
    credentials.

    This is an ARN, not a credential. AWS generates and rotates the password;
    Terraform never sees it and it is not in state. Grant the application's IAM
    role secretsmanager:GetSecretValue scoped to this ARN and let the
    application resolve the secret at runtime.

    Verify the secret from the CLI with `aws secretsmanager describe-secret`,
    which confirms existence, KMS key and rotation status without disclosing the
    value. Never resolve the plaintext into a shell, a log or a Terraform
    variable — anything Terraform reads is written to state.
  EOT
  value       = one(module.rds[*].master_user_secret_arn)
}

output "elasticache_primary_endpoint" {
  description = "Redis primary endpoint for writes, or null when ElastiCache is disabled."
  value       = one(module.elasticache[*].primary_endpoint_address)
}

output "elasticache_reader_endpoint" {
  description = "Redis reader endpoint, load-balanced across replicas."
  value       = one(module.elasticache[*].reader_endpoint_address)
}

output "lambda_function_arns" {
  description = "Lambda function ARNs by key."
  value       = one(module.lambda[*].function_arns)
}

output "lambda_execution_role_arns" {
  description = "Lambda execution role ARNs by key."
  value       = one(module.lambda[*].execution_role_arns)
}
