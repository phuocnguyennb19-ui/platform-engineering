module "wafv2" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-wafv2.git?ref=v1.1.0"

  name           = var.name
  scope          = var.scope
  default_action = var.default_action

  rules = merge(local.managed_rules, local.rate_rules)

  visibility_config = {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }

  association_resource_arns = var.scope == "REGIONAL" ? var.associate_resource_arns : {}

  create_logging_configuration    = length(var.log_destination_arns) > 0
  logging_log_destination_configs = var.log_destination_arns

  tags = var.tags
}
