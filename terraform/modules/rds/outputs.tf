output "instance_id" {
  description = "DB instance identifier."
  value       = module.db.db_instance_identifier
}

output "instance_arn" {
  description = "DB instance ARN."
  value       = module.db.db_instance_arn
}

output "endpoint" {
  description = "Connection endpoint in host:port form."
  value       = module.db.db_instance_endpoint
}

output "address" {
  description = "Hostname of the instance, without the port."
  value       = module.db.db_instance_address
}

output "port" {
  description = "Port the instance listens on."
  value       = local.port
}

output "database_name" {
  description = "Name of the initial database."
  value       = module.db.db_instance_name
}

output "username" {
  description = "Master username. The password is not an output of this module and never exists in Terraform state — read it from master_user_secret_arn."
  value       = module.db.db_instance_username
  sensitive   = true
}

output "master_user_secret_arn" {
  description = <<-EOT
    ARN of the AWS-managed Secrets Manager secret holding the master credentials.

    Grant an application's role secretsmanager:GetSecretValue on this ARN and let
    it resolve the password at runtime. Do not read it in Terraform: doing so
    writes the plaintext into state, which is exactly what this arrangement
    exists to avoid.
  EOT
  value       = try(module.db.db_instance_master_user_secret_arn, null)
}

output "parameter_group_name" {
  description = "DB parameter group name."
  value       = module.db.db_parameter_group_id
}

output "cloudwatch_log_groups" {
  description = "CloudWatch log groups the instance exports to."
  value       = module.db.db_instance_cloudwatch_log_groups
}
