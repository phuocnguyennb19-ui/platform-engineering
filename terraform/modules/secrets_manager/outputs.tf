output "secret_arns" {
  description = "Map of secret keys to their ARNs"
  value       = { for k, v in module.secrets_manager : k => v.secret_arn }
}

output "secret_ids" {
  description = "Map of secret keys to their IDs"
  value       = { for k, v in module.secrets_manager : k => v.secret_id }
}

output "secret_names" {
  description = "Map of secret keys to their names"
  value       = local.secret_names
}

output "secret_version_ids" {
  description = "Map of secret keys to their current version IDs"
  value       = { for k, v in module.secrets_manager : k => try(v.secret_version_id, null) }
}
