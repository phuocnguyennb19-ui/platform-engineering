output "sns_topic_arns" {
  description = "Map of SNS topic ARNs"
  value       = { for k, v in module.sns : k => v.topic_arn }
}

output "sns_topic_ids" {
  description = "Map of SNS topic IDs (same as ARN)"
  value       = { for k, v in module.sns : k => v.topic_id }
}

output "sns_topic_owners" {
  description = "Map of SNS topic owners (AWS account ID)"
  value       = { for k, v in module.sns : k => v.topic_owner }
}
