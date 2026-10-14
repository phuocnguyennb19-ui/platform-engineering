output "zone_id" {
  description = "Hosted zone ID, whether created here or looked up. Consumed by the acm module for DNS validation."
  value       = local.zone_id
}

output "zone_name" {
  description = "Hosted zone name."
  value       = var.zone_name
}

output "zone_arn" {
  description = "Hosted zone ARN, or null when the zone was looked up rather than created."
  value       = one(aws_route53_zone.this[*].arn)
}

output "name_servers" {
  description = "Nameservers for the zone. When this module creates a delegated subdomain zone, these are the NS records that must be added to the parent zone — until they are, nothing in this zone resolves."
  value       = var.create_zone ? aws_route53_zone.this[0].name_servers : data.aws_route53_zone.this[0].name_servers
}

output "record_fqdns" {
  description = "Map of record key to fully qualified domain name."
  value       = { for k, v in aws_route53_record.this : k => v.fqdn }
}
