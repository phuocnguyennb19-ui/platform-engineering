output "instance_ids" {
  description = "Map of instance key to instance ID."
  value       = { for k, v in module.instance : k => v.id }
}

output "instance_arns" {
  description = "Map of instance key to ARN."
  value       = { for k, v in module.instance : k => v.arn }
}

output "private_ips" {
  description = "Map of instance key to private IP."
  value       = { for k, v in module.instance : k => v.private_ip }
}

output "private_dns" {
  description = "Map of instance key to private DNS name."
  value       = { for k, v in module.instance : k => v.private_dns }
}

output "availability_zones" {
  description = "Map of instance key to the AZ it landed in."
  value       = { for k, v in module.instance : k => v.availability_zone }
}

output "ami_id" {
  description = "AMI resolved for instances that did not pin one, or null when every instance pinned its own."
  value       = local.default_ami_id
}

output "session_manager_commands" {
  description = "The aws CLI command that opens a shell on each instance without SSH, a key pair or an inbound rule."
  value       = { for k, v in module.instance : k => "aws ssm start-session --target ${v.id}" }
}
