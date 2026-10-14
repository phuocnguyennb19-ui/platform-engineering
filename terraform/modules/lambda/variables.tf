variable "name" {
  description = "Name prefix. Each function is named \"<name>-<key>\"."
  type        = string
}

variable "functions" {
  description = <<-EOT
    Lambda functions, keyed by a short name.

    A function is attached to the VPC only when vpc_attached is true. Attaching
    costs a cold-start ENI and, more importantly, removes the function's default
    internet access — a VPC-attached function reaches the internet only through
    a NAT gateway, and reaches AWS APIs only through NAT or a VPC endpoint.
    Attach when the function has to reach RDS or ElastiCache; leave it detached
    otherwise.

    Environment variables are not the place for secrets. They are visible to
    anyone with lambda:GetFunctionConfiguration and they appear in the console.
    Pass a Secrets Manager or Parameter Store ARN and resolve it at runtime.
  EOT
  type = map(object({
    description = optional(string, "Managed by Terraform")
    handler     = string
    runtime     = string
    source_path = optional(string)
    filename    = optional(string)

    architectures = optional(list(string), ["arm64"])
    timeout       = optional(number, 30)
    memory_size   = optional(number, 512)

    environment_variables = optional(map(string), {})

    vpc_attached = optional(bool, false)

    reserved_concurrent_executions = optional(number, -1)
    publish                        = optional(bool, true)
    tracing_mode                   = optional(string, "Active")

    log_retention_days = optional(number, 30)

    policy_statements = optional(map(object({
      effect    = optional(string, "Allow")
      actions   = list(string)
      resources = list(string)
    })), {})

    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, f in var.functions : (f.source_path != null) != (f.filename != null)
    ])
    error_message = "Each function must set exactly one of source_path (build the package) or filename (use a prebuilt zip)."
  }

  validation {
    condition     = alltrue([for k, f in var.functions : f.timeout > 0 && f.timeout <= 900])
    error_message = "timeout must be between 1 and 900 seconds."
  }
}

variable "subnet_ids" {
  description = "Private subnets for VPC-attached functions. From module.vpc.private_subnet_ids."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "Security groups for VPC-attached functions. From module.security_groups.lambda_sg_id."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "KMS key encrypting environment variables at rest and the log groups."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every function."
  type        = map(string)
  default     = {}
}
