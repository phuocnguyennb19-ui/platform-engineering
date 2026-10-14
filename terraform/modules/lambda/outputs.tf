output "function_arns" {
  description = "Map of function key to ARN."
  value       = { for k, v in module.function : k => v.lambda_function_arn }
}

output "function_names" {
  description = "Map of function key to name."
  value       = { for k, v in module.function : k => v.lambda_function_name }
}

output "function_invoke_arns" {
  description = "Map of function key to invoke ARN — what an API Gateway integration or an ALB target group references."
  value       = { for k, v in module.function : k => v.lambda_function_invoke_arn }
}

output "function_qualified_arns" {
  description = "Map of function key to the published-version ARN."
  value       = { for k, v in module.function : k => v.lambda_function_qualified_arn }
}

output "execution_role_arns" {
  description = "Map of function key to execution role ARN. Attach extra permissions to these rather than widening policy_statements when the grant is owned elsewhere."
  value       = { for k, v in module.function : k => v.lambda_role_arn }
}

output "execution_role_names" {
  description = "Map of function key to execution role name."
  value       = { for k, v in module.function : k => v.lambda_role_name }
}

output "log_group_names" {
  description = "Map of function key to CloudWatch log group name."
  value       = { for k, v in module.function : k => v.lambda_cloudwatch_log_group_name }
}
