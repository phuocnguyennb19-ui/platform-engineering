variable "name_prefix" {
  description = "Prefix of every queue name: a queue is named \"<name_prefix>-<key>\" (plus \".fifo\" for a FIFO queue)."
  type        = string
}

variable "tags" {
  description = "Tags applied to every queue."
  type        = map(string)
  default     = {}
}

variable "queues" {
  description = <<-EOT
    Queues to create, keyed by short name. Every queue is encrypted: SQS-managed SSE, or SSE-KMS
    when `kms_key_arn` is set. `dead_letter` creates a companion "<name>-dlq" queue and moves a
    message there after `max_receive_count` failed receives — set it for anything a consumer can
    fail on, or a poison message is retried until it expires.
  EOT
  type = map(object({
    fifo                        = optional(bool, false)
    content_based_deduplication = optional(bool, false)
    visibility_timeout_seconds  = optional(number, 30)
    message_retention_seconds   = optional(number, 345600)
    max_message_size            = optional(number, 262144)
    delay_seconds               = optional(number, 0)
    receive_wait_time_seconds   = optional(number, 20)
    kms_key_arn                 = optional(string)
    dead_letter = optional(object({
      max_receive_count         = optional(number, 5)
      message_retention_seconds = optional(number, 1209600)
    }))
    policy = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, q in var.queues : can(regex("^[A-Za-z0-9_-]+$", k))])
    error_message = "queue keys may contain only letters, digits, hyphens and underscores."
  }

  validation {
    condition     = alltrue([for q in var.queues : q.visibility_timeout_seconds >= 0 && q.visibility_timeout_seconds <= 43200])
    error_message = "visibility_timeout_seconds must be between 0 and 43200."
  }

  validation {
    condition     = alltrue([for q in var.queues : q.message_retention_seconds >= 60 && q.message_retention_seconds <= 1209600])
    error_message = "message_retention_seconds must be between 60 and 1209600 (14 days)."
  }

  validation {
    condition     = alltrue([for q in var.queues : q.receive_wait_time_seconds >= 0 && q.receive_wait_time_seconds <= 20])
    error_message = "receive_wait_time_seconds must be between 0 and 20."
  }

  validation {
    condition     = alltrue([for q in var.queues : !q.content_based_deduplication || q.fifo])
    error_message = "content_based_deduplication applies to FIFO queues only."
  }
}
