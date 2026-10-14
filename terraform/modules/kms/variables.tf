variable "name" {
  description = "Name prefix, conventionally \"<project>-<environment>\". Aliases become alias/<name>-<key>."
  type        = string
}

variable "keys" {
  description = <<-EOT
    Customer-managed KMS keys to create, keyed by purpose — "rds", "ebs", "logs",
    "secrets", "s3", "eks". The key name becomes part of the alias and is the
    handle every other module uses to look the ARN up.

    One key per purpose rather than one key for everything: a key policy is the
    only place you can say "the RDS service may use this and nothing else", and
    a single shared key collapses that distinction. It also means rotating or
    revoking one blast radius does not take the others with it.

    service_principals are AWS service principals granted encrypt/decrypt through
    the key policy, e.g. ["rds.amazonaws.com"], ["logs.<region>.amazonaws.com"].
  EOT
  type = map(object({
    description             = string
    service_principals      = optional(list(string), [])
    key_administrator_arns  = optional(list(string), [])
    key_user_arns           = optional(list(string), [])
    enable_rotation         = optional(bool, true)
    rotation_period_in_days = optional(number, 365)
    deletion_window_in_days = optional(number, 30)
    multi_region            = optional(bool, false)
    enable_default_policy   = optional(bool, true)
    tags                    = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.keys : v.deletion_window_in_days >= 7 && v.deletion_window_in_days <= 30
    ])
    error_message = "deletion_window_in_days must be between 7 and 30."
  }

  validation {
    condition     = alltrue([for k, v in var.keys : v.enable_rotation])
    error_message = "Automatic key rotation must stay enabled. If a key genuinely cannot rotate (an external key store, or a format that pins key material), record the exception and set it outside this module."
  }
}

variable "tags" {
  description = "Tags applied to every key and alias."
  type        = map(string)
  default     = {}
}
