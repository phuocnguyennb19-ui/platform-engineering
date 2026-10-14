variable "name_prefix" {
  description = "Prefix of every secret name: a secret is named \"<name_prefix>/<key>\"."
  type        = string
}

variable "tags" {
  description = "Tags applied to every secret."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = <<-EOT
    Secrets to create, keyed by short name. By default the module creates the secret with an
    empty "{}" placeholder and never touches its value again: the real value is written out of
    band (console, CLI, a rotation function) and never passes through Terraform or its state.
    `generate_password = true` instead generates a random value in Terraform — it is then stored
    in the state, so use it only with an encrypted, access-controlled backend.
  EOT
  type = map(object({
    description             = optional(string)
    kms_key_arn             = optional(string)
    recovery_window_in_days = optional(number, 30)
    generate_password       = optional(bool, false)
    password_length         = optional(number, 32)
    rotation_lambda_arn     = optional(string)
    rotation_days           = optional(number, 30)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, s in var.secrets : can(regex("^[A-Za-z0-9/_+=.@-]+$", k))])
    error_message = "secret keys may contain only letters, digits and / _ + = . @ -."
  }

  validation {
    condition     = alltrue([for s in var.secrets : s.recovery_window_in_days == 0 || (s.recovery_window_in_days >= 7 && s.recovery_window_in_days <= 30)])
    error_message = "recovery_window_in_days must be 0 (delete immediately) or between 7 and 30."
  }

  validation {
    condition     = alltrue([for s in var.secrets : s.password_length >= 16 && s.password_length <= 4096])
    error_message = "password_length must be between 16 and 4096."
  }
}
