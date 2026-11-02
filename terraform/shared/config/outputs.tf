output "errors" {
  description = "Every configuration error found. The caller fails the plan when this is not empty."
  value       = local.errors
}

output "environment" {
  value = var.environment
}

output "env_path" {
  description = "Repository path of the selected environment's Terraform values (environments/<dir>/terraform), for error messages."
  value       = local.env_path
}

output "account_id" {
  value = local.account_id
}

output "region" {
  value = local.region
}

output "name" {
  description = "<name_prefix>-<environment>, the prefix of every resource name."
  value       = "${local.name_prefix}-${var.environment}"
}

output "tags" {
  value = local.tags
}

output "core" {
  description = "core.yaml as decoded."
  value       = local.core
}

output "backend" {
  value = {
    bucket = local.backend_bucket
    region = local.backend_region
  }
}

output "applications" {
  description = "Applications enabled in this environment, keyed by directory name."
  value       = local.applications
}

output "promotion_consumer_account_ids" {
  description = "Accounts of environments whose release.promote_from is this environment."
  value       = local.promotion_consumer_account_ids
}

output "application" {
  description = "The selected application after app.yaml and <environment>.yaml are merged; null without var.application."
  value       = local.application
}
