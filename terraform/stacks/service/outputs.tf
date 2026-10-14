output "application" {
  value = var.application
}

output "runtime" {
  value = local.app.runtime
}

output "image" {
  value = local.image
}

output "image_digest" {
  value = one(data.aws_ecr_image.this[*].image_digest)
}

output "ecs_service_name" {
  value = one(module.ecs_service[*].name)
}

output "ecs_task_definition_arn" {
  value = one(module.ecs_service[*].task_definition_arn)
}


output "route" {
  description = "host and path this application is routed on through the core ALB."
  value       = length(local.routes) == 0 ? null : "${local.app.network.host}${local.app.network.path}"
}
