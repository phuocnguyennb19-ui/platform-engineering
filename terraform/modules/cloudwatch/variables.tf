variable "name" {
  description = "Name prefix, conventionally \"<project>-<environment>\"."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "create_sns_topic" {
  description = <<-EOT
    Create the SNS topic every alarm publishes to.

    An alarm with no action is a dashboard widget with extra steps — it changes
    colour and tells nobody. Creating the topic here is what closes the loop, and
    it is why this module owns the alarms rather than leaving them to each
    workload module.
  EOT
  type        = bool
  default     = true
}

variable "sns_topic_arn" {
  description = "Existing SNS topic to publish alarms to. Set this instead of create_sns_topic when the account already has a central alerting topic."
  type        = string
  default     = null
}

variable "sns_kms_key_arn" {
  description = "KMS key encrypting the SNS topic. Alarm payloads carry resource identifiers and metric values."
  type        = string
  default     = null
}

variable "sns_subscriptions" {
  description = <<-EOT
    Subscriptions on the created topic, keyed by a stable name.

    Note on email: an email subscription is created in PENDING_CONFIRMATION and
    stays there until a human clicks the link in the confirmation mail. Terraform
    reports it as created either way, so an unconfirmed email subscription is a
    silent alerting gap. Prefer https to an on-call system, which confirms itself.
  EOT
  type = map(object({
    protocol = string
    endpoint = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, s in var.sns_subscriptions :
      contains(["email", "email-json", "https", "sqs", "lambda", "sms", "application"], s.protocol)
    ])
    error_message = "protocol must be one of email, email-json, https, sqs, lambda, sms, application."
  }
}

variable "log_groups" {
  description = <<-EOT
    CloudWatch log groups, keyed by a short name. `name` is the full log group
    path, e.g. "/aws/application/api".

    Create log groups here rather than letting a service create them implicitly:
    an implicitly created group has never-expire retention and no KMS key, which
    is both a bill that grows forever and plaintext application logs at rest.
  EOT
  type = map(object({
    name              = string
    retention_in_days = optional(number, 30)
    kms_key_arn       = optional(string)
    skip_destroy      = optional(bool, false)
    tags              = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, g in var.log_groups :
      contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], g.retention_in_days)
    ])
    error_message = "retention_in_days must be a value CloudWatch Logs accepts (0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)."
  }
}

variable "default_log_kms_key_arn" {
  description = "KMS key applied to any log group that does not name its own."
  type        = string
  default     = null
}

variable "metric_alarms" {
  description = <<-EOT
    CloudWatch metric alarms, keyed by a short name. Every alarm publishes to the
    module's SNS topic on both ALARM and OK — the OK notification is what tells
    on-call the incident is over without them having to check.

    treat_missing_data defaults to "missing" rather than "notBreaching": for most
    infrastructure metrics an absent datapoint means the thing stopped reporting,
    and "notBreaching" turns that into silence.
  EOT
  type = map(object({
    alarm_description   = string
    namespace           = string
    metric_name         = string
    statistic           = optional(string, "Average")
    extended_statistic  = optional(string)
    period              = optional(number, 300)
    evaluation_periods  = optional(number, 2)
    datapoints_to_alarm = optional(number)
    threshold           = number
    comparison_operator = string
    dimensions          = optional(map(string), {})
    treat_missing_data  = optional(string, "missing")
    unit                = optional(string)
    severity            = optional(string, "warning")
    tags                = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, a in var.metric_alarms :
      contains([
        "GreaterThanOrEqualToThreshold", "GreaterThanThreshold",
        "LessThanThreshold", "LessThanOrEqualToThreshold",
      ], a.comparison_operator)
    ])
    error_message = "comparison_operator must be one of GreaterThanOrEqualToThreshold, GreaterThanThreshold, LessThanThreshold, LessThanOrEqualToThreshold."
  }

  validation {
    condition = alltrue([
      for k, a in var.metric_alarms :
      contains(["breaching", "notBreaching", "ignore", "missing"], a.treat_missing_data)
    ])
    error_message = "treat_missing_data must be one of breaching, notBreaching, ignore, missing."
  }
}

variable "create_dashboard" {
  description = "Create a CloudWatch dashboard listing every alarm this module manages, so the environment has one page showing current alarm state."
  type        = bool
  default     = false
}
