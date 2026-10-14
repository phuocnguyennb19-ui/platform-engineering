data "aws_secretsmanager_secret_version" "auth_token" {
  count = var.auth_token_secret_arn != null ? 1 : 0

  secret_id = var.auth_token_secret_arn
}

resource "aws_elasticache_parameter_group" "this" {
  name        = "${var.name}-${replace(var.parameter_group_family, ".", "")}"
  family      = var.parameter_group_family
  description = "Parameter group for ${var.name}"

  dynamic "parameter" {
    for_each = var.parameters

    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-params" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = var.description

  engine         = "redis"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = var.port

  parameter_group_name = aws_elasticache_parameter_group.this.name

  subnet_group_name  = var.subnet_group_name
  security_group_ids = var.security_group_ids

  num_cache_clusters      = var.cluster_mode_enabled ? null : var.num_cache_clusters
  num_node_groups         = var.cluster_mode_enabled ? var.num_node_groups : null
  replicas_per_node_group = var.cluster_mode_enabled ? var.replicas_per_node_group : null

  automatic_failover_enabled = var.automatic_failover_enabled
  multi_az_enabled           = var.automatic_failover_enabled ? var.multi_az_enabled : false

  at_rest_encryption_enabled = var.at_rest_encryption_enabled
  transit_encryption_enabled = var.transit_encryption_enabled
  kms_key_id                 = var.at_rest_encryption_enabled ? var.kms_key_arn : null

  auth_token = var.auth_token_secret_arn != null ? data.aws_secretsmanager_secret_version.auth_token[0].secret_string : null

  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = var.snapshot_retention_limit > 0 ? var.snapshot_window : null
  maintenance_window       = var.maintenance_window

  apply_immediately          = var.apply_immediately
  auto_minor_version_upgrade = var.auto_minor_version_upgrade

  notification_topic_arn = var.notification_topic_arn

  dynamic "log_delivery_configuration" {
    for_each = var.log_delivery

    content {
      destination      = log_delivery_configuration.value.destination
      destination_type = log_delivery_configuration.value.destination_type
      log_format       = log_delivery_configuration.value.log_format
      log_type         = log_delivery_configuration.key
    }
  }

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    # Read at plan time; rotation goes through ElastiCache AUTH rotation, not Terraform.
    ignore_changes = [auth_token]
  }
}
