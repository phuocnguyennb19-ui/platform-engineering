variable "name" {
  description = "Name prefix for every role and policy, conventionally \"<project>-<environment>\"."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every role this module creates. A boundary caps what a role can ever be granted, including by a later change — set it in production even when the roles look narrow today."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every role and policy."
  type        = map(string)
  default     = {}
}

variable "create_ec2_instance_role" {
  description = "Create the EC2 instance role and instance profile consumed by the ec2 module."
  type        = bool
  default     = true
}

variable "ec2_enable_ssm" {
  description = "Attach AmazonSSMManagedInstanceCore. This is what makes Session Manager work, which is what makes the bastion, the key pair and the inbound SSH rule unnecessary."
  type        = bool
  default     = true
}

variable "ec2_enable_cloudwatch_agent" {
  description = "Attach CloudWatchAgentServerPolicy so the instance can publish metrics and logs."
  type        = bool
  default     = true
}

variable "ec2_ecr_pull_repository_arns" {
  description = "ECR repository ARNs the instance may pull from. Empty grants no ECR access at all. Listing repositories explicitly is the difference between least privilege and ecr:* on every repository in the account."
  type        = list(string)
  default     = []
}

variable "ec2_s3_read_bucket_arns" {
  description = "S3 bucket ARNs the instance may read. Both the bucket ARN and its objects are granted; pass the bucket ARN only."
  type        = list(string)
  default     = []
}

variable "ec2_kms_key_arns" {
  description = "KMS key ARNs the instance may use for decrypt and data key generation — the EBS key at minimum when the root volume is encrypted with a customer-managed key."
  type        = list(string)
  default     = []
}

variable "ec2_additional_policy_arns" {
  description = "Extra managed policy ARNs to attach to the EC2 instance role."
  type        = list(string)
  default     = []
}

variable "create_rds_monitoring_role" {
  description = "Create the role RDS Enhanced Monitoring assumes to publish OS-level metrics. Required whenever the rds module sets monitoring_interval > 0."
  type        = bool
  default     = true
}

variable "additional_roles" {
  description = <<-EOT
    Extra roles, keyed by a short name. Each supplies its own trust policy as
    JSON, plus managed policy ARNs and inline policy documents.

    Use this for CI deployment roles, cross-account access and application roles
    that do not belong to a specific workload module. IRSA roles for EKS service
    accounts belong with the eks module instead, because their trust policy has
    to reference the cluster's OIDC provider.
  EOT
  type = map(object({
    description          = string
    assume_role_policy   = string
    managed_policy_arns  = optional(list(string), [])
    inline_policies      = optional(map(string), {})
    max_session_duration = optional(number, 3600)
    tags                 = optional(map(string), {})
  }))
  default = {}
}
