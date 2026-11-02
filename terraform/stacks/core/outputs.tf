output "environment" {
  value = var.environment
}

output "name" {
  value = local.name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "ecs_enabled" {
  value = local.ecs_enabled
}

output "ecs_cluster_arn" {
  value = local.ecs_enabled ? module.ecs_cluster[0].arn : null
}

output "ecs_cluster_name" {
  value = local.ecs_enabled ? module.ecs_cluster[0].name : null
}

output "ecs_security_group_id" {
  value = module.security_groups.ecs_sg_id
}

output "enable_execute_command" {
  value = try(local.core.ecs.enable_execute_command, false)
}

output "eks_enabled" {
  value = local.eks_enabled
}

output "eks_cluster_name" {
  value = local.eks_enabled ? module.eks[0].cluster_name : null
}

output "eks_cluster_endpoint" {
  value = local.eks_enabled ? module.eks[0].cluster_endpoint : null
}

output "eks_cluster_certificate_authority_data" {
  value     = local.eks_enabled ? module.eks[0].cluster_certificate_authority_data : null
  sensitive = true
}

output "addon_role_arns" {
  description = "IRSA role per eks.addon_roles key, for the kubernetes/platform add-on ServiceAccounts."
  value       = local.eks_enabled ? module.eks[0].irsa_role_arns : {}
}

output "sops_kms_key_arn" {
  description = "Goes into the root .sops.yaml for this environment's secrets file."
  value       = try(local.core.sops.kms_key, false) == true ? module.sops_kms[0].key_arns["sops"] : null
}

output "velero_bucket" {
  value = contains(keys(local.addon_roles), "velero") ? module.velero_bucket[0].s3_bucket_id : null
}

output "alb_arn" {
  value = local.alb_enabled ? module.alb[0].arn : null
}

output "alb_dns_name" {
  value = local.alb_enabled ? module.alb[0].dns_name : null
}

output "alb_security_group_id" {
  value = module.security_groups.alb_sg_id
}

output "alb_zone_id" {
  value = local.alb_enabled ? module.alb[0].zone_id : null
}

output "alb_listener_arn" {
  description = "Listener that application rules attach to: HTTPS when the ALB has a certificate, HTTP otherwise."
  value       = local.alb_enabled ? coalesce(module.alb[0].https_listener_arn, module.alb[0].listener_arns["http"]) : null
}

output "alb_target_ports" {
  value = local.alb_target_ports
}

output "alb_https_listener_arn" {
  value = local.alb_enabled ? module.alb[0].https_listener_arn : null
}

output "certificate_arn" {
  value = local.dns_enabled ? module.acm[0].certificate_arn : null
}

output "dns_zone_name" {
  value = local.dns_enabled ? local.core.dns.zone_name : null
}

output "route53_zone_id" {
  value = local.dns_enabled ? module.route53[0].zone_id : null
}

output "alarm_topic_arn" {
  value = module.cloudwatch.sns_topic_arn
}

output "log_retention_days" {
  value = try(local.core.logs.retention_days, 90)
}
