variable "name_prefix" {
  description = "Prefix of every topic name: a topic is named \"<name_prefix>-<key>\" (plus \".fifo\" for a FIFO topic)."
  type        = string
}

variable "tags" {
  description = "Tags applied to every topic."
  type        = map(string)
  default     = {}
}

variable "topics" {
  description = <<-EOT
    Topics to create, keyed by short name. Every topic is encrypted at rest: with `kms_key_arn`,
    or with the AWS-managed alias/aws/sns key when it is null. A publisher that is an AWS service
    (CloudWatch, EventBridge) needs `kms:GenerateDataKey*` on a customer-managed key — the
    AWS-managed key cannot grant it.
  EOT
  type = map(object({
    display_name                = optional(string)
    fifo                        = optional(bool, false)
    content_based_deduplication = optional(bool, false)
    kms_key_arn                 = optional(string)
    policy                      = optional(string)
    subscriptions = optional(map(object({
      protocol             = string
      endpoint             = string
      raw_message_delivery = optional(bool, false)
      filter_policy        = optional(string)
    })), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for k, t in var.topics : can(regex("^[A-Za-z0-9_-]+$", k))])
    error_message = "topic keys may contain only letters, digits, hyphens and underscores."
  }

  validation {
    condition = alltrue(flatten([
      for t in var.topics : [
        for s in values(t.subscriptions) : contains(["sqs", "lambda", "https", "email", "email-json", "sms", "application", "firehose"], s.protocol)
      ]
    ]))
    error_message = "subscription protocol must be one of: sqs, lambda, https, email, email-json, sms, application, firehose. Plain http is not accepted."
  }

  validation {
    condition     = alltrue([for t in var.topics : !t.content_based_deduplication || t.fifo])
    error_message = "content_based_deduplication applies to FIFO topics only."
  }
}
