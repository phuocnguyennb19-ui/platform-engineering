variable "name" {
  description = "Replication group identifier, e.g. \"dev-redis\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,39}$", var.name))
    error_message = "name must start with a lowercase letter and contain only lowercase letters, digits and hyphens, up to 40 characters."
  }
}

variable "description" {
  description = "Replication group description."
  type        = string
  default     = "Managed by Terraform"
}

variable "engine_version" {
  description = "Redis engine version, e.g. \"7.1\"."
  type        = string
  default     = "7.1"
}

variable "node_type" {
  description = "Cache node type, e.g. \"cache.t4g.micro\" for dev or \"cache.r7g.large\" for production."
  type        = string
  default     = "cache.t4g.micro"
}

variable "parameter_group_family" {
  description = "Parameter group family, e.g. \"redis7\". Must match engine_version's major."
  type        = string
  default     = "redis7"
}

variable "parameters" {
  description = "Parameter group parameters."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "subnet_group_name" {
  description = "ElastiCache subnet group. From module.vpc.elasticache_subnet_group_name, which spans the database subnets — no internet route in either direction."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups for the cache nodes. From module.security_groups.elasticache_sg_id."
  type        = list(string)

  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "At least one security group is required."
  }
}

variable "port" {
  description = "Port the cache listens on. Must match the security-groups module's cache_port."
  type        = number
  default     = 6379
}

variable "num_cache_clusters" {
  description = "Number of nodes in the replication group when cluster mode is off: one primary plus n-1 replicas. Needs at least 2 for automatic_failover_enabled to be meaningful."
  type        = number
  default     = 2
}

variable "automatic_failover_enabled" {
  description = "Promote a replica automatically when the primary fails. Requires num_cache_clusters >= 2."
  type        = bool
  default     = true
}

variable "multi_az_enabled" {
  description = "Spread the replicas across availability zones. Requires automatic_failover_enabled."
  type        = bool
  default     = true
}

variable "cluster_mode_enabled" {
  description = "Enable cluster mode (sharding). Changes the client connection model — a client library must speak Redis Cluster to use it."
  type        = bool
  default     = false
}

variable "num_node_groups" {
  description = "Shard count when cluster_mode_enabled is true."
  type        = number
  default     = 2
}

variable "replicas_per_node_group" {
  description = "Replicas per shard when cluster_mode_enabled is true."
  type        = number
  default     = 1
}

variable "at_rest_encryption_enabled" {
  description = "Encrypt data at rest. Cannot be changed after creation."
  type        = bool
  default     = true
}

variable "transit_encryption_enabled" {
  description = "Encrypt data in transit with TLS. Cannot be changed after creation on older engine versions, and clients must connect with TLS once it is on."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "KMS key for at-rest encryption. Null uses the AWS-managed ElastiCache key."
  type        = string
  default     = null
}

variable "auth_token_secret_arn" {
  description = <<-EOT
    Secrets Manager secret ARN holding the Redis AUTH token, read at plan time
    and passed to the replication group.

    There is deliberately no auth_token variable taking a literal: a token passed
    as a plain variable is written to the state file. Create the secret out of
    band (or with a separate, tightly scoped Terraform stack) and reference it
    here. Requires transit_encryption_enabled.
  EOT
  type        = string
  default     = null
}

variable "snapshot_retention_limit" {
  description = "Days of automatic snapshots. 0 disables snapshots — acceptable for a pure cache, not for anything treated as a datastore."
  type        = number
  default     = 5
}

variable "snapshot_window" {
  description = "Daily snapshot window in UTC, e.g. \"03:00-05:00\"."
  type        = string
  default     = "03:00-05:00"
}

variable "maintenance_window" {
  description = "Weekly maintenance window, e.g. \"mon:05:00-mon:07:00\"."
  type        = string
  default     = "mon:05:00-mon:07:00"
}

variable "apply_immediately" {
  description = "Apply modifications now rather than in the maintenance window."
  type        = bool
  default     = false
}

variable "auto_minor_version_upgrade" {
  description = "Allow automatic minor version upgrades during maintenance."
  type        = bool
  default     = true
}

variable "log_delivery" {
  description = "Log delivery destinations, keyed by log type — \"slow-log\" or \"engine-log\"."
  type = map(object({
    destination      = string
    destination_type = optional(string, "cloudwatch-logs")
    log_format       = optional(string, "json")
  }))
  default = {}
}

variable "notification_topic_arn" {
  description = "SNS topic receiving ElastiCache events such as failover and node replacement. From module.cloudwatch.sns_topic_arn."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
