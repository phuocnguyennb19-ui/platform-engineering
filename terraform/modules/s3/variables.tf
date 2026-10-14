variable "name" {
  description = "Bucket name. Globally unique across AWS; the caller decides it — this module derives no name from an environment or project."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.name)) && !can(regex("\\.\\.", var.name))
    error_message = "name must be 3-63 characters of lowercase letters, digits, dots and hyphens, start and end with a letter or digit, and contain no '..'."
  }
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}

variable "force_destroy" {
  description = "Allow Terraform to delete the bucket while it still holds objects. Leave false for anything that holds data you would miss."
  type        = bool
  default     = false
}

variable "versioning_enabled" {
  description = "Keep previous versions of every object. The only undo for an overwrite or a delete."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for SSE-KMS. Null encrypts with SSE-S3 (AES-256); objects are encrypted either way."
  type        = string
  default     = null
}

variable "lifecycle_rules" {
  description = "Lifecycle rules. `prefix` scopes a rule to a key prefix; omitted, it applies to the whole bucket. Incomplete multipart uploads are aborted after `abort_incomplete_multipart_upload_days` by default so failed uploads do not accumulate unseen cost."
  type = list(object({
    id                                     = string
    enabled                                = optional(bool, true)
    prefix                                 = optional(string)
    expiration_days                        = optional(number)
    noncurrent_version_expiration_days     = optional(number)
    abort_incomplete_multipart_upload_days = optional(number, 7)
    transitions = optional(list(object({
      days          = number
      storage_class = string
    })), [])
  }))
  default = []
}

variable "cors_rules" {
  description = "CORS rules, for a bucket read directly by browsers."
  type = list(object({
    allowed_methods = list(string)
    allowed_origins = list(string)
    allowed_headers = optional(list(string), [])
    expose_headers  = optional(list(string), [])
    max_age_seconds = optional(number)
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.cors_rules : !contains(r.allowed_origins, "*") || alltrue([for m in r.allowed_methods : contains(["GET", "HEAD"], m)])])
    error_message = "cors_rules: allowed_origins \"*\" is only allowed with read methods (GET, HEAD)."
  }
}

variable "access_logging" {
  description = "Server access logging to another bucket. Null disables it."
  type = object({
    target_bucket = string
    target_prefix = optional(string, "")
  })
  default = null
}

variable "object_lock" {
  description = "Default object lock retention (WORM). Only settable when the bucket is created; it cannot be turned off afterwards. Null leaves object lock disabled."
  type = object({
    mode = string
    days = number
  })
  default = null

  validation {
    condition     = var.object_lock == null || contains(["GOVERNANCE", "COMPLIANCE"], try(var.object_lock.mode, ""))
    error_message = "object_lock.mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "policy" {
  description = "Additional bucket policy (JSON). Merged with the statements this module always attaches, which deny non-TLS access and TLS older than 1.2. It cannot make the bucket public: every public access block setting is on."
  type        = string
  default     = null
}
