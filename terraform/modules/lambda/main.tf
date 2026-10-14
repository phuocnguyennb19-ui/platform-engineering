locals {
  vpc_attached = { for k, f in var.functions : k => f.vpc_attached }
}

module "function" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "7.21.1"

  for_each = var.functions

  function_name = "${var.name}-${each.key}"
  description   = each.value.description
  handler       = each.value.handler
  runtime       = each.value.runtime
  architectures = each.value.architectures

  create_package         = each.value.source_path != null
  source_path            = each.value.source_path
  local_existing_package = each.value.filename

  timeout                        = each.value.timeout
  memory_size                    = each.value.memory_size
  reserved_concurrent_executions = each.value.reserved_concurrent_executions
  publish                        = each.value.publish

  environment_variables = each.value.environment_variables
  kms_key_arn           = var.kms_key_arn

  vpc_subnet_ids         = each.value.vpc_attached ? var.subnet_ids : null
  vpc_security_group_ids = each.value.vpc_attached ? var.security_group_ids : null

  attach_network_policy = each.value.vpc_attached

  cloudwatch_logs_retention_in_days = each.value.log_retention_days
  cloudwatch_logs_kms_key_id        = var.kms_key_arn

  tracing_mode          = each.value.tracing_mode
  attach_tracing_policy = each.value.tracing_mode != null

  attach_policy_statements = length(each.value.policy_statements) > 0
  policy_statements        = each.value.policy_statements

  tags = merge(var.tags, each.value.tags)
}
