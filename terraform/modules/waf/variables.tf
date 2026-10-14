variable "name" {
  description = "Web ACL name."
  type        = string
}

variable "tags" {
  description = "Tags applied to the web ACL."
  type        = map(string)
  default     = {}
}

variable "scope" {
  description = "REGIONAL for an ALB, API Gateway or AppSync; CLOUDFRONT for a distribution (the provider must then be in us-east-1)."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "CLOUDFRONT"], var.scope)
    error_message = "scope must be REGIONAL or CLOUDFRONT."
  }
}

variable "default_action" {
  description = "What happens to a request no rule matches: allow or block."
  type        = string
  default     = "allow"

  validation {
    condition     = contains(["allow", "block"], var.default_action)
    error_message = "default_action must be allow or block."
  }
}

variable "managed_rule_groups" {
  description = <<-EOT
    AWS managed rule groups, keyed by rule name, evaluated in `priority` order. `count_only`
    runs a group in count mode — how a new group is introduced before it is allowed to block.
    The default is the AWS baseline: common rule set, known bad inputs, IP reputation.
  EOT
  type = map(object({
    priority    = number
    name        = string
    vendor_name = optional(string, "AWS")
    count_only  = optional(bool, false)
  }))
  default = {
    common        = { priority = 10, name = "AWSManagedRulesCommonRuleSet" }
    bad-inputs    = { priority = 20, name = "AWSManagedRulesKnownBadInputsRuleSet" }
    ip-reputation = { priority = 30, name = "AWSManagedRulesAmazonIpReputationList" }
  }
}

variable "rate_limit" {
  description = "Requests per 5 minutes from one IP before it is blocked. Null disables the rate-based rule."
  type        = number
  default     = null

  validation {
    condition     = var.rate_limit == null || try(var.rate_limit >= 100, false)
    error_message = "rate_limit must be at least 100 (the AWS minimum)."
  }
}

variable "associate_resource_arns" {
  description = "Resources (ALB, API Gateway stage) protected by this web ACL, keyed by a stable name. REGIONAL scope only."
  type        = map(string)
  default     = {}
}

variable "log_destination_arns" {
  description = "Where to send request logs: a Firehose stream, a CloudWatch log group whose name starts with aws-waf-logs-, or an S3 bucket. Empty disables logging."
  type        = list(string)
  default     = []
}
