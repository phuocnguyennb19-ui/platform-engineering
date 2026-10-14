locals {
  # Explicit bool: certificate_arn is unknown at plan when ACM is built in the same stack.
  https_enabled = var.enable_https != null ? var.enable_https : var.certificate_arn != null

  default_tg_key = coalesce(
    var.default_target_group_key,
    try(sort(keys(var.target_groups))[0], null),
  )

  target_groups = {
    for k, tg in var.target_groups : k => {
      name             = substr("${var.name}-${k}", 0, 32)
      port             = tg.port
      protocol         = tg.protocol
      protocol_version = tg.protocol_version
      target_type      = tg.target_type

      deregistration_delay          = tg.deregistration_delay
      slow_start                    = tg.slow_start
      load_balancing_algorithm_type = tg.load_balancing_algorithm_type

      health_check = {
        enabled             = tg.health_check.enabled
        path                = tg.health_check.path
        port                = tg.health_check.port
        protocol            = tg.health_check.protocol
        matcher             = tg.health_check.matcher
        interval            = tg.health_check.interval
        timeout             = tg.health_check.timeout
        healthy_threshold   = tg.health_check.healthy_threshold
        unhealthy_threshold = tg.health_check.unhealthy_threshold
      }

      stickiness = {
        enabled         = tg.stickiness.enabled
        type            = tg.stickiness.type
        cookie_duration = tg.stickiness.cookie_duration
      }

      create_attachment = false

      tags = merge(var.tags, tg.tags)
    }
  }

  listener_rules = {
    for k, r in var.listener_rules : k => {
      priority = r.priority

      actions = [{
        type             = "forward"
        target_group_key = r.target_group_key
      }]

      conditions = concat(
        r.path_patterns != null ? [{ path_pattern = { values = r.path_patterns } }] : [],
        r.host_headers != null ? [{ host_header = { values = r.host_headers } }] : [],
        r.source_ips != null ? [{ source_ip = { values = r.source_ips } }] : [],
        [for h, vals in r.http_headers : {
          http_header = { http_header_name = h, values = vals }
        }],
      )
    }
  }

  # Listeners are built with merge(), not ternaries: redirect and forward objects differ in type.
  http_redirects = local.https_enabled && var.enable_http_redirect

  http_listener = local.https_enabled && !var.enable_http_redirect ? {} : {
    http = merge(
      {
        port     = 80
        protocol = "HTTP"
      },
      local.http_redirects ? {
        redirect = {
          port        = "443"
          protocol    = "HTTPS"
          status_code = "HTTP_301"
        }
      } : {},
      local.http_redirects ? {} : {
        forward = { target_group_key = local.default_tg_key }
      },
      local.http_redirects || length(local.listener_rules) == 0 ? {} : {
        rules = local.listener_rules
      },
    )
  }

  https_listener = local.https_enabled ? {
    https = merge(
      {
        port            = 443
        protocol        = "HTTPS"
        certificate_arn = var.certificate_arn
        ssl_policy      = var.ssl_policy
        forward         = { target_group_key = local.default_tg_key }
      },
      length(var.additional_certificate_arns) > 0 ? { additional_certificate_arns = var.additional_certificate_arns } : {},
      length(local.listener_rules) > 0 ? { rules = local.listener_rules } : {},
    )
  } : {}

  listeners = merge(local.http_listener, local.https_listener)
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.17.0"

  name = var.name

  load_balancer_type = "application"
  internal           = var.internal

  vpc_id  = var.vpc_id
  subnets = var.subnet_ids

  create_security_group = false
  security_groups       = var.security_group_ids

  enable_deletion_protection       = var.enable_deletion_protection
  idle_timeout                     = var.idle_timeout
  enable_http2                     = var.enable_http2
  drop_invalid_header_fields       = var.drop_invalid_header_fields
  desync_mitigation_mode           = var.desync_mitigation_mode
  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing

  access_logs = var.enable_access_logs ? {
    bucket  = local.logs_bucket_name
    prefix  = var.access_logs_prefix
    enabled = true
  } : {}

  target_groups = local.target_groups

  listeners = local.listeners

  tags = var.tags

  depends_on = [aws_s3_bucket_policy.logs]
}
