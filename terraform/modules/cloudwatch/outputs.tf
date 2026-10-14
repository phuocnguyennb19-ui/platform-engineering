output "sns_topic_arn" {
  description = "SNS topic every alarm publishes to — the one created here, or the one passed in via sns_topic_arn."
  value       = local.topic_arn
}

output "sns_topic_name" {
  description = "Name of the created SNS topic, or null when an existing topic was supplied."
  value       = one(aws_sns_topic.alarms[*].name)
}

output "log_group_names" {
  description = "Map of log group key to name."
  value       = { for k, v in aws_cloudwatch_log_group.this : k => v.name }
}

output "log_group_arns" {
  description = "Map of log group key to ARN."
  value       = { for k, v in aws_cloudwatch_log_group.this : k => v.arn }
}

output "alarm_arns" {
  description = "Map of alarm key to ARN."
  value       = { for k, v in aws_cloudwatch_metric_alarm.this : k => v.arn }
}

output "alarm_names" {
  description = "Map of alarm key to name."
  value       = { for k, v in aws_cloudwatch_metric_alarm.this : k => v.alarm_name }
}

output "dashboard_name" {
  description = "CloudWatch dashboard name, or null when not created."
  value       = one(aws_cloudwatch_dashboard.this[*].dashboard_name)
}
