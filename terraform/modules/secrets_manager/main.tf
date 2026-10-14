module "secrets_manager" {
  for_each = local.secrets
  source   = "git::https://github.com/terraform-aws-modules/terraform-aws-secrets-manager.git?ref=v1.1.0"

  name        = each.value.name
  description = coalesce(each.value.description, "Managed by Terraform; the value is set out of band")

  kms_key_id              = each.value.kms_key_arn
  recovery_window_in_days = each.value.recovery_window_in_days
  block_public_policy     = true

  # Upstream always writes a first version; after that the value is owned outside Terraform.
  create_random_password = each.value.generate_password
  random_password_length = each.value.password_length
  secret_string          = each.value.initial_value
  ignore_secret_changes  = true

  enable_rotation     = each.value.enable_rotation
  rotation_lambda_arn = each.value.rotation_lambda_arn
  rotation_rules = each.value.enable_rotation ? {
    automatically_after_days = each.value.rotation_days
  } : {}

  tags = var.tags
}
