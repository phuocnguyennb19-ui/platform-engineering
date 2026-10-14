variable "name_prefix" {
  description = "Prefix of every table name: a table is named \"<name_prefix>-<key>\"."
  type        = string
}

variable "tags" {
  description = "Tags applied to every table."
  type        = map(string)
  default     = {}
}

variable "tables" {
  description = <<-EOT
    Tables to create, keyed by short name. `attributes` lists every attribute used as a key —
    the table's and every index's — and nothing else. Point-in-time recovery and deletion
    protection default to on: a caller turns them off explicitly (for a throwaway environment),
    never by forgetting to turn them on.
  EOT
  type = map(object({
    hash_key  = string
    range_key = optional(string)
    attributes = list(object({
      name = string
      type = string
    }))
    billing_mode   = optional(string, "PAY_PER_REQUEST")
    read_capacity  = optional(number)
    write_capacity = optional(number)
    global_secondary_indexes = optional(list(object({
      name               = string
      hash_key           = string
      range_key          = optional(string)
      projection_type    = optional(string, "ALL")
      non_key_attributes = optional(list(string))
      read_capacity      = optional(number)
      write_capacity     = optional(number)
    })), [])
    ttl_attribute_name             = optional(string)
    stream_view_type               = optional(string)
    kms_key_arn                    = optional(string)
    point_in_time_recovery_enabled = optional(bool, true)
    deletion_protection_enabled    = optional(bool, true)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, t in var.tables : can(regex("^[A-Za-z0-9_.-]+$", k))])
    error_message = "table keys may contain only letters, digits, dots, hyphens and underscores."
  }

  validation {
    condition     = alltrue([for t in var.tables : contains(["PAY_PER_REQUEST", "PROVISIONED"], t.billing_mode)])
    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }

  validation {
    condition     = alltrue([for t in var.tables : t.billing_mode == "PAY_PER_REQUEST" || (t.read_capacity != null && t.write_capacity != null)])
    error_message = "a PROVISIONED table needs read_capacity and write_capacity."
  }

  validation {
    condition     = alltrue(flatten([for t in var.tables : [for a in t.attributes : contains(["S", "N", "B"], a.type)]]))
    error_message = "attribute type must be S, N or B."
  }

  validation {
    condition = alltrue([
      for t in var.tables : alltrue([
        for key in compact(concat([t.hash_key, t.range_key], flatten([for i in t.global_secondary_indexes : [i.hash_key, i.range_key]]))) :
        contains([for a in t.attributes : a.name], key)
      ])
    ])
    error_message = "every table and index key must be declared in attributes."
  }

  validation {
    condition     = alltrue([for t in var.tables : t.stream_view_type == null || contains(["KEYS_ONLY", "NEW_IMAGE", "OLD_IMAGE", "NEW_AND_OLD_IMAGES"], coalesce(t.stream_view_type, "KEYS_ONLY"))])
    error_message = "stream_view_type must be KEYS_ONLY, NEW_IMAGE, OLD_IMAGE or NEW_AND_OLD_IMAGES."
  }
}
