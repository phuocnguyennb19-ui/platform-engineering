output "sqs_queue_arns" {
  description = "Map of SQS queue ARNs"
  value       = { for k, v in module.sqs : k => v.queue_arn }
}

output "sqs_queue_ids" {
  description = "Map of SQS queue URLs (IDs)"
  value       = { for k, v in module.sqs : k => v.queue_id }
}

output "sqs_queue_urls" {
  description = "Map of SQS queue URLs"
  value       = { for k, v in module.sqs : k => v.queue_url }
}

output "sqs_queue_names" {
  description = "Map of SQS queue names"
  value       = { for k, v in module.sqs : k => v.queue_name }
}

output "sqs_dead_letter_queue_arns" {
  description = "Map of dead-letter queue ARNs, for the queues that have one"
  value       = { for k, v in module.sqs : k => v.dead_letter_queue_arn if local.queues[k].create_dlq }
}
