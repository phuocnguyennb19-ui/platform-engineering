variable "name" {
  description = "Name prefix. Repository names become \"<name>/<key>\" unless use_name_prefix is false."
  type        = string
}

variable "use_name_prefix" {
  description = "Prefix repository names with `name`. Set false when repositories are shared across environments and should be named by the key alone — an image built once and promoted through dev, staging and prod lives in one repository, not three."
  type        = bool
  default     = true
}

variable "repositories" {
  description = <<-EOT
    ECR repositories to create, keyed by short name.

    Defaults are the production-safe ones: immutable tags so a deployed digest
    cannot be swapped under a running workload, scan-on-push so a known CVE is
    visible before it ships, and KMS encryption.
  EOT
  type = map(object({
    image_tag_mutability = optional(string, "IMMUTABLE")
    scan_on_push         = optional(bool, true)
    force_delete         = optional(bool, false)
    untagged_expiry_days = optional(number, 7)
    keep_tagged_count    = optional(number, 30)
    tag_prefixes         = optional(list(string), ["v", "release", "main", "prod"])
    pull_principal_arns  = optional(list(string), [])
    tags                 = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.repositories : contains(["IMMUTABLE", "MUTABLE"], v.image_tag_mutability)
    ])
    error_message = "image_tag_mutability must be IMMUTABLE or MUTABLE."
  }
}

variable "kms_key_arn" {
  description = "KMS key encrypting the repositories. Null falls back to AES256 with an AWS-owned key."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every repository."
  type        = map(string)
  default     = {}
}
