module "config" {
  source = "../../shared/config"

  config_root       = "${path.root}/../../../environments"
  applications_root = "${path.root}/../../../applications"
  environment       = var.environment
  application       = var.application
  image_tag         = var.image_tag
}

data "terraform_remote_state" "core" {
  backend = "s3"

  config = {
    bucket = module.config.backend.bucket
    region = module.config.backend.region
    key    = "${var.environment}/core/core.tfstate"
  }
}

data "terraform_remote_state" "registry" {
  backend = "s3"

  config = {
    bucket = module.config.backend.bucket
    region = module.config.backend.region
    key    = "${var.environment}/registry/registry.tfstate"
  }
}

locals {
  app      = module.config.application
  core     = data.terraform_remote_state.core.outputs
  registry = data.terraform_remote_state.registry.outputs
  name     = "${module.config.name}-${var.application}"

  tags = merge(module.config.tags, {
    Environment = var.environment
    Application = var.application
    ManagedBy   = "terraform"
    Layer       = "service"
  })

  # Looked up by image.repository: application name and repository name are different things.
  repository_url  = try(local.registry.repository_urls[local.app.repository], null)
  repository_name = try(local.registry.repository_names[local.app.repository], null)
  image           = "${coalesce(local.repository_url, "unresolved")}:${local.app.image_tag}"

  is_ecs = local.app.runtime == "ecs"
  valid  = length(module.config.errors) == 0 && local.repository_url != null

  # A for-expression, not a ternary: an empty map and a map of objects share no type.
  routes   = { for k, v in { (var.application) = local.app.network } : k => v if local.is_ecs && v != null }
  dns_zone = try(local.core.dns_zone_name, null)
  dns_record = length(local.routes) > 0 && local.dns_zone != null && try(
    local.app.network.host == local.dns_zone || endswith(local.app.network.host, ".${local.dns_zone}"), false
  )
  # The core certificate covers the zone and one level below it.
  host_has_certificate = local.dns_zone == null || try(can(regex("^([a-z0-9-]+\\.)?${replace(local.dns_zone, ".", "\\.")}$", local.app.network.host)), false)

  secret_base_arns = [for arn in values(local.app.secrets) : regex("^(arn:[^:]+:[^:]+:[^:]+:[0-9]{12}:(secret:[^:]+|parameter/.+))", arn)[0]]
}

resource "terraform_data" "validation" {
  input = "${var.environment}/${var.application}"

  lifecycle {
    precondition {
      condition     = length(module.config.errors) == 0
      error_message = "Invalid configuration:\n${join("\n", module.config.errors)}"
    }
    precondition {
      condition     = local.repository_url != null
      error_message = "image.repository ${local.app.repository} has no ECR repository in ${var.environment}: apply the registry layer for ${var.environment} first."
    }
    precondition {
      condition     = !local.is_ecs || try(local.core.ecs_cluster_arn, null) != null
      error_message = "The ${var.environment} core state has no ECS cluster: enable ecs in core.yaml and apply the core layer."
    }
    precondition {
      condition     = length(local.routes) == 0 || try(local.core.alb_listener_arn, null) != null
      error_message = "${var.application} declares network, but the ${var.environment} core state has no ALB: enable alb in core.yaml and apply the core layer."
    }
    precondition {
      condition     = length(local.routes) == 0 || local.app.port == 8080 || (local.app.port >= try(local.core.alb_target_ports.from, 8080) && local.app.port <= try(local.core.alb_target_ports.to, 8080))
      error_message = "container.port ${local.app.port} is not reachable from the ALB: use 8080 or widen alb.target_port_range in core.yaml."
    }
    precondition {
      condition     = length(local.routes) == 0 || try(local.core.certificate_arn, null) == null || local.host_has_certificate
      error_message = "network.host is not covered by the ${var.environment} certificate (${coalesce(local.dns_zone, "-")} and *.${coalesce(local.dns_zone, "-")})."
    }
  }
}

# Fails the plan when the tag is not in this environment's registry, before anything is deployed.
data "aws_ecr_image" "this" {
  count = local.valid ? 1 : 0

  repository_name = local.repository_name
  image_tag       = local.app.image_tag
}

module "ecs_service" {
  source = "../../modules/ecs-service"
  count  = local.is_ecs ? 1 : 0

  name               = local.name
  cluster_arn        = local.core.ecs_cluster_arn
  subnet_ids         = local.core.private_subnet_ids
  security_group_ids = concat([local.core.ecs_security_group_id], [for sg in aws_security_group.extra : sg.id])

  cpu                  = local.app.cpu
  memory               = local.app.memory
  ephemeral_storage_gb = local.app.ephemeral_storage_gb
  cpu_architecture     = local.app.architecture
  platform_version     = local.app.platform_version

  capacity_provider_strategy = {
    for k, v in local.app.capacity_providers : k => { capacity_provider = k, weight = v.weight, base = v.base }
  }

  containers = {
    (var.application) = {
      image = local.image

      port_mappings = [{
        containerPort = local.app.port
        name          = "http"
      }]

      environment = [for k, v in local.app.environment : { name = k, value = v }]
      secrets     = [for k, v in local.app.secrets : { name = k, valueFrom = v }]

      health_check = local.app.health_check_command == null ? null : {
        command = local.app.health_check_command
      }

      readonly_root_filesystem = local.app.readonly_root_filesystem
    }
  }

  task_exec_secret_arns    = [for arn in local.secret_base_arns : arn if strcontains(arn, ":secretsmanager:")]
  task_exec_ssm_param_arns = [for arn in local.secret_base_arns : arn if strcontains(arn, ":ssm:")]

  desired_count            = local.app.replicas
  enable_autoscaling       = local.app.autoscaling_enabled
  autoscaling_min_capacity = local.app.autoscaling_enabled ? local.app.autoscaling_min : local.app.replicas
  autoscaling_max_capacity = local.app.autoscaling_enabled ? local.app.autoscaling_max : local.app.replicas

  autoscaling_cpu_target         = local.app.autoscaling_cpu_target
  autoscaling_memory_target      = local.app.autoscaling_memory_target
  autoscaling_scale_in_cooldown  = local.app.autoscaling_scale_in_cooldown
  autoscaling_scale_out_cooldown = local.app.autoscaling_scale_out_cooldown

  deployment_minimum_healthy_percent = local.app.minimum_healthy_percent
  deployment_maximum_percent         = local.app.maximum_percent
  enable_circuit_breaker             = local.app.circuit_breaker
  health_check_grace_period_seconds  = local.app.health_check_grace_period_seconds

  tasks_iam_role_policies   = { for i, arn in local.app.iam_policy_arns : "policy${i}" => arn }
  tasks_iam_role_statements = local.app.iam_statements

  target_group_arn             = one([for tg in aws_lb_target_group.this : tg.arn])
  enable_load_balancer         = length(local.routes) > 0
  load_balancer_container_name = length(local.routes) > 0 ? var.application : null
  load_balancer_container_port = length(local.routes) > 0 ? local.app.port : null

  enable_execute_command = coalesce(local.app.execute_command, local.core.enable_execute_command)
  log_retention_days     = coalesce(local.app.log_retention_days, local.core.log_retention_days)

  tags = local.tags

  # ECS rejects a target group that no listener forwards to yet.
  depends_on = [terraform_data.validation, aws_lb_listener_rule.this]
}

resource "aws_lb_target_group" "this" {
  for_each = local.routes

  # Port is part of the name so a port change can create before it destroys.
  name                 = "${substr(local.name, 0, 23)}-${substr(sha1("${local.name}:${local.app.port}"), 0, 8)}"
  port                 = local.app.port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = local.core.vpc_id
  deregistration_delay = local.app.target_group.deregistration_delay
  slow_start           = local.app.target_group.slow_start

  stickiness {
    enabled         = local.app.target_group.stickiness_enabled
    type            = "lb_cookie"
    cookie_duration = local.app.target_group.stickiness_duration
  }

  health_check {
    enabled             = true
    path                = coalesce(local.app.target_group.health_check.path, local.app.health_check_path, "/")
    matcher             = local.app.target_group.health_check.matcher
    interval            = local.app.target_group.health_check.interval
    timeout             = local.app.target_group.health_check.timeout
    healthy_threshold   = local.app.target_group.health_check.healthy_threshold
    unhealthy_threshold = local.app.target_group.health_check.unhealthy_threshold
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Only for network.security_group.ingress: ALB → container.port is already allowed by the core ECS group.
resource "aws_security_group" "extra" {
  for_each = local.is_ecs && length(local.app.ingress_rules) > 0 ? toset(["this"]) : toset([])

  name_prefix = "${local.name}-"
  description = "Extra ingress for ${local.name}"
  vpc_id      = local.core.vpc_id

  tags = merge(local.tags, { Name = "${local.name}-extra" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "extra" {
  for_each = {
    for p in flatten([
      for i, r in local.app.ingress_rules : [for c in r.cidr_blocks : merge(r, { key = "${r.protocol}-${r.port}-${c}", cidr = c })]
    ]) : p.key => p if local.is_ecs
  }

  security_group_id = aws_security_group.extra["this"].id
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = strcontains(each.value.cidr, ":") ? null : each.value.cidr
  cidr_ipv6         = strcontains(each.value.cidr, ":") ? each.value.cidr : null
  description       = each.value.description == "" ? null : each.value.description

  tags = local.tags
}

resource "aws_lb_listener_rule" "this" {
  for_each = local.routes

  listener_arn = local.core.alb_listener_arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host]
    }
  }

  dynamic "condition" {
    for_each = each.value.path == "/" ? [] : [each.value.path]

    content {
      path_pattern {
        values = [condition.value, "${condition.value}/*"]
      }
    }
  }

  tags = local.tags
}

module "dns" {
  source = "../../modules/route53"
  count  = local.dns_record ? 1 : 0

  zone_name   = local.dns_zone
  create_zone = false

  records = {
    application = {
      name = local.app.network.host
      type = "A"
      alias = {
        name    = local.core.alb_dns_name
        zone_id = local.core.alb_zone_id
      }
    }
  }

  tags = local.tags
}
