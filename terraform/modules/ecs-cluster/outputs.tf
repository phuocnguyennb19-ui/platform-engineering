output "arn" {
  description = "Cluster ARN. Consumed by the ecs-service module as cluster_arn."
  value       = module.cluster.arn
}

output "id" {
  description = "Cluster ID."
  value       = module.cluster.id
}

output "name" {
  description = "Cluster name. This is the ClusterName dimension for CloudWatch metrics and the value `aws ecs` commands take as --cluster."
  value       = module.cluster.name
}

output "capacity_providers" {
  description = "Capacity providers attached to the cluster."
  value       = module.cluster.cluster_capacity_providers
}

output "log_group_name" {
  description = "Log group receiving execute-command session transcripts."
  value       = module.cluster.cloudwatch_log_group_name
}

output "log_group_arn" {
  description = "ARN of the execute-command log group."
  value       = module.cluster.cloudwatch_log_group_arn
}

output "task_exec_iam_role_arn" {
  description = "Cluster-wide task execution role ARN, or null when each service creates its own."
  value       = module.cluster.task_exec_iam_role_arn
}

output "task_exec_iam_role_name" {
  description = "Cluster-wide task execution role name, or null when create_task_exec_iam_role is false."
  value       = module.cluster.task_exec_iam_role_name
}

output "service_connect_namespace_arn" {
  description = "Cloud Map namespace ARN services join for Service Connect — created here or passed in — or null when the cluster has none."
  value       = local.service_connect_namespace
}
