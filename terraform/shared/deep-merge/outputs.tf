output "merged" {
  value = local.merged
}

output "too_deep" {
  description = "Paths where both documents hold a map below the fourth level; those are replaced, not merged."
  value       = local.too_deep
}
