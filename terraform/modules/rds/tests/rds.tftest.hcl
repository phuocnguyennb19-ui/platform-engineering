mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:sts::111122223333:assumed-role/ci/s" }
  }
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  identifier           = "platform-dev-postgres"
  engine_version       = "16.4"
  family               = "postgres16"
  major_engine_version = "16"
  instance_class       = "db.t4g.medium"
  db_subnet_group_name = "platform-dev-db"
  security_group_ids   = ["sg-0eee"]
  kms_key_arn          = "arn:aws:kms:ap-southeast-1:111122223333:key/22222222-2222-2222-2222-222222222222"
}

# Both engines accept plaintext connections out of the box. The module's default parameter group
# is what closes that, so a caller who passes no parameters still gets TLS-only.
run "postgres_defaults_force_tls" {
  command = plan

  assert {
    condition     = local.port == 5432
    error_message = "postgres must default to 5432."
  }

  assert {
    condition = length([
      for p in local.parameters : p
      if p.name == "rds.force_ssl" && p.value == "1" && p.apply_method == "pending-reboot"
    ]) == 1
    error_message = "postgres must force TLS with a static rds.force_ssl parameter."
  }

  assert {
    condition     = contains(local.log_exports, "postgresql")
    error_message = "postgres must export its log to CloudWatch by default."
  }
}

run "mysql_defaults_force_tls" {
  command = plan

  variables {
    engine               = "mysql"
    engine_version       = "8.0"
    family               = "mysql8.0"
    major_engine_version = "8.0"
  }

  assert {
    condition     = local.port == 3306
    error_message = "mysql must default to 3306."
  }

  assert {
    condition = length([
      for p in local.parameters : p
      if p.name == "require_secure_transport" && p.value == "ON" && p.apply_method == "pending-reboot"
    ]) == 1
    error_message = "mysql must force TLS with a static require_secure_transport parameter."
  }

  assert {
    condition     = contains(local.log_exports, "slowquery")
    error_message = "mysql must export the slow query log by default."
  }
}

run "explicit_port_and_parameters_win" {
  command = plan

  variables {
    port       = 6543
    parameters = [{ name = "work_mem", value = "8192", apply_method = "immediate" }]
  }

  assert {
    condition     = local.port == 6543
    error_message = "an explicit port must override the engine default."
  }

  assert {
    condition     = length(local.parameters) == 1 && local.parameters[0].name == "work_mem"
    error_message = "explicit parameters replace the defaults — the caller owns the group."
  }
}

run "rejects_retention_beyond_the_rds_limit" {
  command = plan

  variables {
    backup_retention_period = 36
  }

  expect_failures = [var.backup_retention_period]
}

run "rejects_an_instance_with_no_security_group" {
  command = plan

  variables {
    security_group_ids = []
  }

  expect_failures = [var.security_group_ids]
}

run "rejects_an_unsupported_engine" {
  command = plan

  variables {
    engine = "aurora-postgresql"
  }

  expect_failures = [var.engine]
}

run "rejects_an_unsupported_monitoring_interval" {
  command = plan

  variables {
    monitoring_interval = 45
  }

  expect_failures = [var.monitoring_interval]
}
