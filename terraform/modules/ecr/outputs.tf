output "repository_urls" {
  description = "Map of repository key to registry URL — the value that goes in a container image reference."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of repository key to ARN. Pass these to the iam module's ec2_ecr_pull_repository_arns, or to an IRSA role, to scope pull permission to named repositories."
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}

output "repository_names" {
  description = "Map of repository key to full repository name."
  value       = { for k, v in aws_ecr_repository.this : k => v.name }
}

output "registry_id" {
  description = "Registry (account) ID hosting the repositories."
  value       = try(values(aws_ecr_repository.this)[0].registry_id, null)
}
