output "arn" {
  description = "Load balancer ARN."
  value       = module.alb.arn
}

output "arn_suffix" {
  description = "ARN suffix in the form app/<name>/<id>. This is the LoadBalancer dimension CloudWatch metrics are published under — an alarm needs this, not the ARN."
  value       = module.alb.arn_suffix
}

output "dns_name" {
  description = "Load balancer DNS name. This is the alias target for the Route53 record."
  value       = module.alb.dns_name
}

output "zone_id" {
  description = "Canonical hosted zone ID of the load balancer. Route53 alias records need this alongside dns_name."
  value       = module.alb.zone_id
}

output "target_group_arn_suffixes" {
  description = "Map of target group key to ARN suffix, the TargetGroup dimension for CloudWatch metrics."
  value       = { for k, v in module.alb.target_groups : k => v.arn_suffix }
}

output "target_group_arns" {
  description = "Map of target group key to ARN. An autoscaling group consumes these as target_group_arns; in EKS the Ingress annotation references them by ARN."
  value       = { for k, v in module.alb.target_groups : k => v.arn }
}

output "target_group_names" {
  description = "Map of target group key to name."
  value       = { for k, v in module.alb.target_groups : k => v.name }
}

output "listener_arns" {
  description = "Map of listener key to ARN."
  value       = { for k, v in module.alb.listeners : k => v.arn }
}

output "https_listener_arn" {
  description = "ARN of the HTTPS listener, or null when no certificate was supplied."
  value       = try(module.alb.listeners["https"].arn, null)
}

output "access_logs_bucket" {
  description = "S3 bucket receiving access logs, or null when access logs are disabled."
  value       = var.enable_access_logs ? local.logs_bucket_name : null
}

output "access_logs_bucket_arn" {
  description = "ARN of the access log bucket, when this module created it."
  value       = one(aws_s3_bucket.logs[*].arn)
}
