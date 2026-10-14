locals {
  secrets = {
    for k, s in var.secrets : k => merge(s, {
      name            = "${var.name_prefix}/${k}"
      initial_value   = s.generate_password ? null : jsonencode({})
      enable_rotation = s.rotation_lambda_arn != null
    })
  }

  secret_names = { for k, s in local.secrets : k => s.name }
}
