output "dynamodb_table_arns" {
  description = "Map of DynamoDB table ARNs"
  value       = { for k, v in module.dynamodb_table : k => v.dynamodb_table_arn }
}

output "dynamodb_table_ids" {
  description = "Map of DynamoDB table IDs"
  value       = { for k, v in module.dynamodb_table : k => v.dynamodb_table_id }
}

output "dynamodb_table_names" {
  description = "Map of DynamoDB table names"
  value       = { for k, v in module.dynamodb_table : k => v.dynamodb_table_id }
}

output "dynamodb_table_stream_arns" {
  description = "Map of DynamoDB table stream ARNs (null when stream not enabled)"
  value       = { for k, v in module.dynamodb_table : k => try(v.dynamodb_table_stream_arn, null) }
}
