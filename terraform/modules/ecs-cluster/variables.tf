variable "cluster_name" {
  description = "ECS cluster name, conventionally \"<project>-<environment>-ecs\"."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{1,254}$", var.cluster_name))
    error_message = "cluster_name must be alphanumeric with hyphens or underscores, 2-255 characters."
  }
}

variable "tags" {
  description = "Tags applied to the cluster and everything this module creates."
  type        = map(string)
  default     = {}
}

variable "fargate_base" {
  description = "Tasks placed on on-demand FARGATE before the weighted split starts. This is the floor that survives a Spot capacity shortage, so it is the number that decides whether a Spot interruption is a blip or an outage."
  type        = number
  default     = 1

  validation {
    condition     = var.fargate_base >= 0
    error_message = "fargate_base cannot be negative."
  }
}

variable "fargate_weight" {
  description = "Relative share of tasks above the base placed on on-demand FARGATE."
  type        = number
  default     = 1
}

variable "fargate_spot_weight" {
  description = "Relative share of tasks above the base placed on FARGATE_SPOT. Spot is reclaimed with a two-minute warning; keep it at 0 for anything that cannot absorb a task being killed mid-request."
  type        = number
  default     = 0
}

variable "container_insights" {
  description = "Enable CloudWatch Container Insights. This is the only source of per-task CPU, memory and network metrics; without it the cluster reports service-level counts and nothing about what the tasks are doing. It is billed per metric."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the cluster log group that receives execute-command session output."
  type        = number
  default     = 90
}

variable "log_kms_key_arn" {
  description = "KMS key ARN encrypting the cluster log group. An execute-command session transcript contains whatever the operator typed and whatever the container printed back, so this is not an optional nicety."
  type        = string
  default     = null
}

variable "execute_command_kms_key_arn" {
  description = "KMS key ARN for the execute-command data channel itself. Null leaves the channel encrypted in transit by TLS only."
  type        = string
  default     = null
}

variable "create_task_exec_iam_role" {
  description = "Create a cluster-wide task execution role. Leave false when each service creates its own, which is the narrower default."
  type        = bool
  default     = false
}

variable "task_exec_iam_role_permissions_boundary" {
  description = "Permissions boundary for the cluster-wide task execution role."
  type        = string
  default     = null
}

variable "task_exec_secret_arns" {
  description = "Secrets Manager ARNs the cluster-wide execution role may read to inject container secrets. Name them explicitly; the wildcard grant here is a read of every secret in the account."
  type        = list(string)
  default     = []
}

variable "task_exec_ssm_param_arns" {
  description = "SSM Parameter Store ARNs the cluster-wide execution role may read."
  type        = list(string)
  default     = []
}

variable "service_connect_namespace_name" {
  description = "Create a Cloud Map HTTP namespace with this name and make it the cluster's Service Connect default — the private network services use to call each other. Takes precedence over service_connect_namespace. Null creates nothing."
  type        = string
  default     = null
}

variable "service_connect_namespace" {
  description = "Cloud Map namespace ARN used as the default for ECS Service Connect. Null disables the default; a service can still opt in with its own namespace."
  type        = string
  default     = null
}
