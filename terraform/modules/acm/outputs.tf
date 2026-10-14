output "certificate_arn" {
  description = "Certificate ARN. Consumed by the alb module's HTTPS listener."
  value       = module.acm.acm_certificate_arn
}

output "certificate_domain_name" {
  description = "Primary domain on the certificate."
  value       = var.domain_name
}

output "certificate_domain_names" {
  description = "Every distinct name the certificate covers, primary plus SANs."
  value       = module.acm.distinct_domain_names
}

output "certificate_status" {
  description = "Certificate status — ISSUED once validation completes."
  value       = module.acm.acm_certificate_status
}

output "validation_record_fqdns" {
  description = "FQDNs of the DNS validation records."
  value       = module.acm.validation_route53_record_fqdns
}
