variable "name" {
  description = "Name prefix. Each instance is named \"<name>-<key>\"."
  type        = string
}

variable "instances" {
  description = <<-EOT
    Instances to create, keyed by a short name.

    subnet_id must be a private subnet from the foundation. This module creates
    no VPC and no subnet — it places instances into networking that already
    exists, which is the whole point of the foundation/workload split.

    Leaving ami_id null resolves the current Amazon Linux 2023 AMI for the
    region. That is convenient and it means a `terraform apply` months later can
    plan a replacement when AWS publishes a new image; pin ami_id explicitly for
    anything whose replacement needs to be a deliberate act.
  EOT
  type = map(object({
    subnet_id     = string
    instance_type = optional(string, "t3.medium")
    ami_id        = optional(string)

    root_volume_size = optional(number, 30)
    root_volume_type = optional(string, "gp3")
    root_volume_iops = optional(number)

    user_data                   = optional(string)
    user_data_replace_on_change = optional(bool, false)

    associate_public_ip_address = optional(bool, false)
    key_name                    = optional(string)
    availability_zone           = optional(string)

    monitoring                           = optional(bool, true)
    ebs_optimized                        = optional(bool, true)
    disable_api_termination              = optional(bool, false)
    instance_initiated_shutdown_behavior = optional(string, "stop")

    additional_ebs_volumes = optional(map(object({
      device_name = string
      size        = number
      type        = optional(string, "gp3")
      iops        = optional(number)
      throughput  = optional(number)
    })), {})

    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for k, i in var.instances : !i.associate_public_ip_address])
    error_message = "associate_public_ip_address must stay false. Instances belong in private subnets reached through Session Manager or the ALB; if a public instance is genuinely required, create it outside this module so the exception is visible in review."
  }
}

variable "security_group_ids" {
  description = "Security groups applied to every instance. From module.security_groups.ec2_sg_id."
  type        = list(string)
}

variable "iam_instance_profile" {
  description = "Instance profile name. From module.iam.ec2_instance_profile_name. Without one the instance has no AWS identity — no Session Manager, no CloudWatch agent, no ECR pull."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "KMS key encrypting the root and additional EBS volumes. Null uses the AWS-managed EBS key, which still encrypts but cannot be scoped by key policy."
  type        = string
  default     = null
}

variable "enable_termination_protection_default" {
  description = "Default value for disable_api_termination when an instance does not set it. Turn on in production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every instance."
  type        = map(string)
  default     = {}
}
