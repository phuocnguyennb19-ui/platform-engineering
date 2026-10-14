output "key_arns" {
  description = "Map of purpose to KMS key ARN. This is what every other module consumes, e.g. module.kms.key_arns[\"rds\"]."
  value       = { for k, v in aws_kms_key.this : k => v.arn }
}

output "key_ids" {
  description = "Map of purpose to KMS key ID."
  value       = { for k, v in aws_kms_key.this : k => v.key_id }
}

output "alias_names" {
  description = "Map of purpose to alias name."
  value       = { for k, v in aws_kms_alias.this : k => v.name }
}

output "alias_arns" {
  description = "Map of purpose to alias ARN."
  value       = { for k, v in aws_kms_alias.this : k => v.arn }
}
