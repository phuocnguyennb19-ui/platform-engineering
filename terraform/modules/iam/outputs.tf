output "ec2_instance_role_arn" {
  description = "EC2 instance role ARN."
  value       = one(aws_iam_role.ec2[*].arn)
}

output "ec2_instance_role_name" {
  description = "EC2 instance role name."
  value       = one(aws_iam_role.ec2[*].name)
}

output "ec2_instance_profile_name" {
  description = "EC2 instance profile name. Consumed by the ec2 module as iam_instance_profile."
  value       = one(aws_iam_instance_profile.ec2[*].name)
}

output "ec2_instance_profile_arn" {
  description = "EC2 instance profile ARN."
  value       = one(aws_iam_instance_profile.ec2[*].arn)
}

output "rds_monitoring_role_arn" {
  description = "RDS Enhanced Monitoring role ARN. Consumed by the rds module as monitoring_role_arn."
  value       = one(aws_iam_role.rds_monitoring[*].arn)
}

output "additional_role_arns" {
  description = "Map of additional role key to ARN."
  value       = { for k, v in aws_iam_role.additional : k => v.arn }
}

output "additional_role_names" {
  description = "Map of additional role key to name."
  value       = { for k, v in aws_iam_role.additional : k => v.name }
}
