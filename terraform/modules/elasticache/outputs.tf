output "replication_group_id" {
  description = "Replication group ID."
  value       = aws_elasticache_replication_group.this.id
}

output "arn" {
  description = "Replication group ARN."
  value       = aws_elasticache_replication_group.this.arn
}

output "primary_endpoint_address" {
  description = "Primary endpoint for writes, when cluster mode is off. Null in cluster mode — use configuration_endpoint_address."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "Reader endpoint, which load-balances across replicas. Null in cluster mode."
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "configuration_endpoint_address" {
  description = "Configuration endpoint, used by cluster-mode clients. Null when cluster mode is off."
  value       = aws_elasticache_replication_group.this.configuration_endpoint_address
}

output "port" {
  description = "Port the cache listens on."
  value       = var.port
}

output "member_clusters" {
  description = "Individual cache cluster IDs in the group."
  value       = aws_elasticache_replication_group.this.member_clusters
}

output "parameter_group_name" {
  description = "Parameter group name."
  value       = aws_elasticache_parameter_group.this.name
}
