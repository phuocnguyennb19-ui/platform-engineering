output "repository_urls" {
  description = "Keyed by image.repository, never by application name."
  value       = module.ecr.repository_urls
}

output "repository_names" {
  value = module.ecr.repository_names
}

output "repository_arns" {
  value = module.ecr.repository_arns
}

output "registry_id" {
  value = module.ecr.registry_id
}
