locals {
  log_group_name = "/aws/ecs/${var.cluster_name}"

  # Weight 0 still leaves Spot eligible; omitting it is what keeps Spot out.
  fargate_capacity_providers = merge(
    {
      FARGATE = {
        default_capacity_provider_strategy = {
          weight = var.fargate_weight
          base   = var.fargate_base
        }
      }
    },
    var.fargate_spot_weight > 0 ? {
      FARGATE_SPOT = {
        default_capacity_provider_strategy = {
          weight = var.fargate_spot_weight
        }
      }
    } : {},
  )
}

module "cluster" {
  source  = "terraform-aws-modules/ecs/aws//modules/cluster"
  version = "5.11.4"

  cluster_name = var.cluster_name

  cluster_settings = [
    {
      name  = "containerInsights"
      value = var.container_insights ? "enabled" : "disabled"
    }
  ]

  cluster_configuration = {
    execute_command_configuration = {
      kms_key_id = var.execute_command_kms_key_arn
      logging    = "OVERRIDE"

      log_configuration = {
        cloud_watch_encryption_enabled = var.log_kms_key_arn != null
        cloud_watch_log_group_name     = local.log_group_name
      }
    }
  }

  create_cloudwatch_log_group            = true
  cloudwatch_log_group_name              = local.log_group_name
  cloudwatch_log_group_retention_in_days = var.log_retention_days
  cloudwatch_log_group_kms_key_id        = var.log_kms_key_arn

  default_capacity_provider_use_fargate = true
  fargate_capacity_providers            = local.fargate_capacity_providers

  autoscaling_capacity_providers = {}

  # Decided from the inputs, not the ARN: a namespace created here has no ARN until apply.
  cluster_service_connect_defaults = var.service_connect_namespace_name != null || var.service_connect_namespace != null ? {
    namespace = local.service_connect_namespace
  } : {}

  create_task_exec_iam_role               = var.create_task_exec_iam_role
  create_task_exec_policy                 = var.create_task_exec_iam_role
  task_exec_iam_role_name                 = "${var.cluster_name}-task-exec"
  task_exec_iam_role_use_name_prefix      = false
  task_exec_iam_role_permissions_boundary = var.task_exec_iam_role_permissions_boundary
  task_exec_secret_arns                   = var.task_exec_secret_arns
  task_exec_ssm_param_arns                = var.task_exec_ssm_param_arns

  tags = var.tags
}

resource "aws_service_discovery_http_namespace" "this" {
  count = var.service_connect_namespace_name != null ? 1 : 0

  name        = var.service_connect_namespace_name
  description = "ECS Service Connect namespace for ${var.cluster_name}"
  tags        = var.tags
}

locals {
  service_connect_namespace = var.service_connect_namespace_name != null ? one(aws_service_discovery_http_namespace.this[*].arn) : var.service_connect_namespace
}
