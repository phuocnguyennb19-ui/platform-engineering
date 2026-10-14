variable "name" {
  description = "Service name, conventionally \"<project>-<environment>-<app>\". Also the task definition family."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{1,254}$", var.name))
    error_message = "name must be alphanumeric with hyphens or underscores, 2-255 characters."
  }
}

variable "cluster_arn" {
  description = "ECS cluster the service runs in. From the foundation: module.ecs_cluster.arn."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets the task ENIs are created in. Private subnets only — see assign_public_ip in main.tf for why there is no input to place them elsewhere."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "At least one subnet is required."
  }
}

variable "security_group_ids" {
  description = "Security groups attached to the task ENIs. From module.security_groups.ecs_sg_id. This module never creates its own: the tier-to-tier rules live in one place, and a service that mints a private group is a rule nobody will find during an incident."
  type        = list(string)

  validation {
    condition     = length(var.security_group_ids) >= 1
    error_message = "At least one security group is required. Fargate tasks get their own ENI, so an empty list means the task has no network policy at all."
  }
}

variable "tags" {
  description = "Tags applied to the service, the task definition and every role this module creates."
  type        = map(string)
  default     = {}
}

variable "cpu" {
  description = "Task CPU units. 1024 = 1 vCPU. Fargate accepts 256, 512, 1024, 2048, 4096, 8192 or 16384."
  type        = number
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "Fargate cpu must be one of 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "memory" {
  description = "Task memory in MiB. Must be a valid pairing for cpu — 256 CPU allows 512/1024/2048, 512 allows 1024-4096 in 1024 steps, and so on."
  type        = number
  default     = 1024

  validation {
    condition     = var.memory >= 512 && var.memory <= 122880
    error_message = "Fargate memory must be between 512 and 122880 MiB."
  }
}

variable "ephemeral_storage_gb" {
  description = "Ephemeral storage in GiB, 21-200. Null uses the 20 GiB Fargate provides free. Raise it only for a workload that genuinely writes to disk; it is billed."
  type        = number
  default     = null

  validation {
    condition     = var.ephemeral_storage_gb == null || try(var.ephemeral_storage_gb >= 21 && var.ephemeral_storage_gb <= 200, false)
    error_message = "ephemeral_storage_gb must be between 21 and 200, or null."
  }
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64. ARM64 is Graviton — roughly 20% cheaper per task, and it requires an image built for arm64. A mismatch here fails at task start with an exec format error, not at plan."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "containers" {
  description = <<-EOT
    Containers in the task, keyed by container name. Exactly one must be
    essential for a single-container task; ECS stops the task when any essential
    container exits.

    `image` must be a digest or an immutable tag. The ecr module defaults to
    IMMUTABLE tags precisely so that "the tag deployed last week" still resolves
    to the bytes deployed last week — a mutable tag makes a rollback a guess.

    `secrets` injects Secrets Manager or SSM values as environment variables at
    task start. Use it for every credential: a value placed in `environment`
    instead is stored in the task definition in plaintext and readable by anyone
    with ecs:DescribeTaskDefinition.
  EOT
  type = map(object({
    image     = string
    essential = optional(bool, true)

    cpu                = optional(number)
    memory             = optional(number)
    memory_reservation = optional(number)

    command     = optional(list(string))
    entrypoint  = optional(list(string))
    working_dir = optional(string)

    port_mappings = optional(list(object({
      containerPort = number
      hostPort      = optional(number)
      protocol      = optional(string, "tcp")
      name          = optional(string)
      appProtocol   = optional(string)
    })), [])

    environment = optional(list(object({
      name  = string
      value = string
    })), [])

    secrets = optional(list(object({
      name      = string
      valueFrom = string
    })), [])

    health_check = optional(object({
      command     = list(string)
      interval    = optional(number, 30)
      timeout     = optional(number, 5)
      retries     = optional(number, 3)
      startPeriod = optional(number, 60)
    }))

    mount_points = optional(list(object({
      sourceVolume  = string
      containerPath = string
      readOnly      = optional(bool, true)
    })), [])

    depends_on = optional(list(object({
      containerName = string
      condition     = string
    })), [])

    ulimits = optional(list(object({
      name      = string
      softLimit = number
      hardLimit = number
    })), [])

    readonly_root_filesystem = optional(bool)
    user                     = optional(string)

    stop_timeout = optional(number, 30)
  }))

  validation {
    condition     = length(var.containers) > 0
    error_message = "At least one container is required."
  }

  validation {
    condition     = anytrue([for k, c in var.containers : c.essential])
    error_message = "At least one container must be essential, otherwise ECS has nothing whose exit ends the task."
  }

  validation {
    condition = alltrue([
      for k, c in var.containers : !can(regex(":latest$", c.image))
    ])
    error_message = "A container image must not be tagged :latest. Deploy a digest or an immutable tag — :latest makes the running version unknowable and the rollback a guess."
  }
}

variable "volumes" {
  description = "Task volumes, keyed by name. EFS for anything that must survive a task replacement; a bind mount is scratch space that dies with the task."
  type        = any
  default     = {}
}

variable "log_retention_days" {
  description = "Retention for the container log groups this module creates."
  type        = number
  default     = 90
}

variable "log_kms_key_arn" {
  description = "KMS key ARN encrypting the container log groups. The key policy must allow logs.<region>.amazonaws.com — the kms module's \"logs\" key already does."
  type        = string
  default     = null
}

variable "desired_count" {
  description = "Tasks to run. Ignored after the first apply when autoscaling is enabled — the scaling policy owns the count from then on, and Terraform stops fighting it."
  type        = number
  default     = 2
}

variable "deployment_minimum_healthy_percent" {
  description = "Percentage of desired_count that must stay running during a deployment. 100 with a maximum above 100 gives a rolling deploy with no capacity dip."
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "Ceiling on running tasks during a deployment, as a percentage of desired_count. 200 starts a full replacement set before draining the old one."
  type        = number
  default     = 200
}

variable "enable_circuit_breaker" {
  description = "Stop a deployment that cannot reach a steady state and roll back to the last working task definition. Leave on: without it a bad image leaves the service cycling failed tasks until someone notices."
  type        = bool
  default     = true
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command` into a running task. The cluster forces every session to be logged; see modules/ecs-cluster."
  type        = bool
  default     = true
}

variable "wait_for_steady_state" {
  description = "Block the apply until the service is stable. Slower, and it is what turns \"terraform apply succeeded\" into evidence the deployment actually worked rather than evidence the API accepted it."
  type        = bool
  default     = true
}

variable "platform_version" {
  description = "Fargate platform version. LATEST tracks the newest revision."
  type        = string
  default     = "LATEST"
}

variable "propagate_tags" {
  description = "Copy tags onto the tasks themselves: SERVICE, TASK_DEFINITION or NONE. Task-level tags are what make per-service cost allocation work."
  type        = string
  default     = "SERVICE"

  validation {
    condition     = contains(["SERVICE", "TASK_DEFINITION", "NONE"], var.propagate_tags)
    error_message = "propagate_tags must be SERVICE, TASK_DEFINITION or NONE."
  }
}

variable "capacity_provider_strategy" {
  description = "Per-service override of the cluster's default capacity provider split, keyed by a short name. Empty inherits the cluster default."
  type        = any
  default     = {}
}

variable "target_group_arn" {
  description = "Target group to register tasks in. From module.alb.target_group_arns[\"<key>\"]. Must have target_type \"ip\" — Fargate tasks have no instance to register. Null runs the service with no load balancer, which is correct for a worker."
  type        = string
  default     = null
}

variable "service_connect" {
  description = "Join ECS Service Connect: other services in the same namespace reach this one at http://<dns_name>:<port> without leaving the VPC. `namespace` is the Cloud Map namespace ARN (ecs-cluster's service_connect_namespace_arn); `port_name` must name one of the container's port_mappings. The security groups must allow task-to-task traffic on that port (security-groups' allow_ecs_to_ecs). Null keeps the service out of Service Connect."
  type = object({
    namespace = string
    port_name = string
    dns_name  = string
    port      = number
  })
  default = null
}

variable "enable_load_balancer" {
  description = "Register tasks in target_group_arn. Set it explicitly — true alongside target_group_arn — whenever that target group is created in the same configuration: its ARN is unknown at plan, and inferring this from it fails the plan. Null infers it from target_group_arn != null."
  type        = bool
  default     = null
}

variable "load_balancer_container_name" {
  description = "Container receiving load balanced traffic. Must be a key in containers. Required when target_group_arn is set."
  type        = string
  default     = null
}

variable "load_balancer_container_port" {
  description = "Container port the target group forwards to. Must appear in that container's port_mappings."
  type        = number
  default     = null
}

variable "health_check_grace_period_seconds" {
  description = "Seconds after task start before ALB health checks can kill it. Set this above the application's real cold start, or a slow-booting service is killed and restarted forever without ever going healthy."
  type        = number
  default     = 60
}

variable "enable_autoscaling" {
  description = "Register the service with Application Auto Scaling."
  type        = bool
  default     = true
}

variable "autoscaling_min_capacity" {
  description = "Floor on running tasks. Below 2 there is no redundancy: a single task is a single point of failure and every deployment is an outage."
  type        = number
  default     = 2
}

variable "autoscaling_max_capacity" {
  description = "Ceiling on running tasks. This is a cost control as much as a capacity one — it is what stops a request storm or a retry loop from scaling into a five-figure bill."
  type        = number
  default     = 10
}

variable "autoscaling_cpu_target" {
  description = "Target average CPU utilisation, as a percentage. Null removes the CPU policy entirely. 70 leaves headroom for the scale-out to take effect before saturation — a target of 90 means scaling starts when the service is already struggling."
  type        = number
  default     = 70
}

variable "autoscaling_memory_target" {
  description = "Target average memory utilisation, as a percentage. Null removes the memory policy. Remove it for a JVM or any runtime that allocates a heap up front and never gives it back: its memory sits flat at the reservation and the policy never fires."
  type        = number
  default     = 70
}

variable "autoscaling_scale_in_cooldown" {
  description = "Seconds after a scale-in before another may start. Longer than scale-out on purpose: adding capacity too eagerly costs money, removing it too eagerly costs availability."
  type        = number
  default     = 300
}

variable "autoscaling_scale_out_cooldown" {
  description = "Seconds after a scale-out before another may start."
  type        = number
  default     = 60
}

variable "autoscaling_policies_extra" {
  description = <<-EOT
    Additional scaling policies, keyed by name, merged over the CPU and memory
    policies built from the targets above. Use it for the metric that actually
    governs the workload — ALBRequestCountPerTarget for a web service, a
    customised SQS queue-depth metric for a worker.

    Supplied as a map rather than replacing the defaults through a conditional:
    a ternary would have to unify the type of two differently-shaped policy maps,
    which Terraform refuses. Override a default by reusing its key ("cpu",
    "memory"); merge is shallow, so the whole policy object is replaced.
  EOT
  type        = any
  default     = {}
}

variable "task_exec_iam_role_arn" {
  description = "Existing execution role to reuse, e.g. the cluster-wide one. Null makes this module create a service-scoped role, which is the narrower default."
  type        = string
  default     = null
}

variable "task_exec_secret_arns" {
  description = "Secrets Manager ARNs the execution role may read to inject the `secrets` entries above. Every ARN referenced by a container's secrets must appear here or the task fails to start."
  type        = list(string)
  default     = []
}

variable "task_exec_ssm_param_arns" {
  description = "SSM Parameter Store ARNs the execution role may read."
  type        = list(string)
  default     = []
}

variable "tasks_iam_role_arn" {
  description = "Existing task role for the application. Null creates one scoped to this service."
  type        = string
  default     = null
}

variable "tasks_iam_role_policies" {
  description = "Managed policy ARNs attached to the created task role, keyed by a short name."
  type        = map(string)
  default     = {}
}

variable "tasks_iam_role_statements" {
  description = "Inline policy statements for the created task role. Name the resources: a wildcard here is the application's standing permission on every resource of that type in the account. Rejected: action \"*\", and \"<service>:*\" on resource \"*\" — both are administrator access, not an application permission. Actions that AWS only authorizes on \"*\" (cloudwatch:PutMetricData, xray:PutTraceSegments) are fine."
  type = list(object({
    sid       = optional(string)
    effect    = optional(string, "Allow")
    actions   = list(string)
    resources = list(string)
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default = []

  validation {
    condition     = alltrue([for s in var.tasks_iam_role_statements : !contains(s.actions, "*")])
    error_message = "tasks_iam_role_statements: action \"*\" is not allowed; name the actions the application needs."
  }

  validation {
    condition = alltrue([
      for s in var.tasks_iam_role_statements :
      s.effect != "Allow" || !contains(s.resources, "*") || alltrue([for a in s.actions : !endswith(a, ":*")])
    ])
    error_message = "tasks_iam_role_statements: \"<service>:*\" on resource \"*\" is not allowed; name the resources, or the actions."
  }
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to both roles this module creates. A boundary caps what the role can ever be granted, including by a later change."
  type        = string
  default     = null
}
