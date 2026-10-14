output "s3_bucket_id" {
  description = "Name (ID) of the bucket"
  value       = module.s3_bucket.s3_bucket_id
}

output "s3_bucket_arn" {
  description = "ARN of the bucket"
  value       = module.s3_bucket.s3_bucket_arn
}

output "s3_bucket_bucket_domain_name" {
  description = "Bucket domain name (global)"
  value       = module.s3_bucket.s3_bucket_bucket_domain_name
}

output "s3_bucket_regional_domain_name" {
  description = "Bucket regional domain name (for CloudFront origins)"
  value       = module.s3_bucket.s3_bucket_bucket_regional_domain_name
}

output "s3_bucket_hosted_zone_id" {
  description = "Route 53 hosted zone ID for the bucket (for alias records)"
  value       = module.s3_bucket.s3_bucket_hosted_zone_id
}

output "s3_bucket_website_endpoint" {
  description = "Website endpoint (empty when website not configured)"
  value       = try(module.s3_bucket.s3_bucket_website_endpoint, null)
}

output "s3_bucket_website_domain" {
  description = "Website domain (empty when website not configured)"
  value       = try(module.s3_bucket.s3_bucket_website_domain, null)
}
