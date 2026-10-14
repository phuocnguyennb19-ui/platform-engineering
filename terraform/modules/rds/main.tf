locals {
  default_port = var.engine == "postgres" ? 5432 : 3306
  port         = coalesce(var.port, local.default_port)

  default_log_exports = var.engine == "postgres" ? ["postgresql", "upgrade"] : ["error", "general", "slowquery"]
  log_exports         = coalesce(var.enabled_cloudwatch_logs_exports, local.default_log_exports)

  # Force TLS: both engines accept plaintext by default. Static parameters, hence pending-reboot.
  default_parameters = var.engine == "postgres" ? [
    {
      name         = "rds.force_ssl"
      value        = "1"
      apply_method = "pending-reboot"
    },
    {
      name         = "log_min_duration_statement"
      value        = "1000"
      apply_method = "immediate"
    },
    ] : [
    {
      name         = "require_secure_transport"
      value        = "ON"
      apply_method = "pending-reboot"
    },
    {
      name         = "slow_query_log"
      value        = "1"
      apply_method = "immediate"
    },
    {
      name         = "long_query_time"
      value        = "1"
      apply_method = "immediate"
    },
  ]

  parameters = coalesce(var.parameters, local.default_parameters)
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.13.1"

  identifier = var.identifier

  engine               = var.engine
  engine_version       = var.engine_version
  family               = var.family
  major_engine_version = var.major_engine_version
  instance_class       = var.instance_class

  create_db_subnet_group = false
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = var.security_group_ids

  multi_az            = var.multi_az
  port                = local.port
  publicly_accessible = false

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = var.storage_type
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name                       = var.db_name
  username                      = var.username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.master_user_secret_kms_key_arn

  backup_retention_period          = var.backup_retention_period
  backup_window                    = var.backup_window
  maintenance_window               = var.maintenance_window
  copy_tags_to_snapshot            = var.copy_tags_to_snapshot
  delete_automated_backups         = var.delete_automated_backups
  deletion_protection              = var.deletion_protection
  skip_final_snapshot              = var.skip_final_snapshot
  final_snapshot_identifier_prefix = "${var.identifier}-final"

  monitoring_interval    = var.monitoring_interval
  monitoring_role_arn    = var.monitoring_interval > 0 ? var.monitoring_role_arn : null
  create_monitoring_role = false

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  performance_insights_kms_key_id       = var.performance_insights_kms_key_arn

  enabled_cloudwatch_logs_exports        = local.log_exports
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days

  create_db_parameter_group = true
  parameter_group_name      = "${var.identifier}-${replace(var.family, ".", "")}"
  parameters                = local.parameters

  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = var.apply_immediately
  ca_cert_identifier         = var.ca_cert_identifier

  tags = var.tags
}
