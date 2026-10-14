output "web_acl_arn" {
  description = "ARN of the WAFv2 Web ACL"
  value       = module.wafv2.web_acl_arn
}

output "web_acl_id" {
  description = "ID of the WAFv2 Web ACL"
  value       = module.wafv2.web_acl_id
}

output "web_acl_capacity" {
  description = "Web ACL capacity units consumed"
  value       = try(module.wafv2.web_acl_capacity, null)
}
