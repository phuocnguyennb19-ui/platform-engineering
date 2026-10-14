output "id" {
  description = "Service ARN."
  value       = module.service.id
}

output "name" {
  description = "Service name. This is the ServiceName dimension for CloudWatch metrics and what `aws ecs update-service --service` takes."
  value       = module.service.name
}

output "task_definition_arn" {
  description = "Full ARN of the task definition revision this apply produced, including the revision number. This is the value to record in a deployment log — it is the only unambiguous answer to \"what is running\"."
  value       = module.service.task_definition_arn
}

output "task_definition_family" {
  description = "Task definition family."
  value       = module.service.task_definition_family
}

output "task_definition_revision" {
  description = "Task definition revision number. Rolling back means re-deploying a previous revision of this family."
  value       = module.service.task_definition_revision
}

output "container_definitions" {
  description = "Rendered container definitions, as ECS received them. Useful for diffing what changed between two applies."
  value       = module.service.container_definitions
  sensitive   = true
}

output "task_exec_iam_role_arn" {
  description = "Execution role ARN — what ECS assumes to pull the image and read secrets. Grant a secret's resource policy to THIS role, not the task role."
  value       = module.service.task_exec_iam_role_arn
}

output "task_exec_iam_role_name" {
  description = "Execution role name."
  value       = module.service.task_exec_iam_role_name
}

output "tasks_iam_role_arn" {
  description = "Task role ARN — the identity the application itself uses against AWS APIs. This is the principal to name in an S3 bucket policy or a KMS key policy."
  value       = module.service.tasks_iam_role_arn
}

output "tasks_iam_role_name" {
  description = "Task role name."
  value       = module.service.tasks_iam_role_name
}

output "autoscaling_policy_arns" {
  description = "Map of scaling policy key to ARN. Empty when autoscaling is disabled."
  value       = { for k, v in module.service.autoscaling_policies : k => v.arn }
}
