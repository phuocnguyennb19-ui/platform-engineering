variable "zone_name" {
  description = "Hosted zone name, e.g. \"example.com\". Used to create the zone when create_zone is true, and to look it up when false."
  type        = string
}

variable "create_zone" {
  description = <<-EOT
    Create the hosted zone, or look up an existing one.

    False is the common case for dev and staging: the apex zone is usually
    registered once and delegated per environment, so each environment attaches
    records to a zone it does not own. Creating a public zone that already
    exists elsewhere produces a second zone with different nameservers and no
    error — the records simply never resolve.
  EOT
  type        = bool
  default     = false
}

variable "private_zone" {
  description = "Make the zone private to the VPCs in vpc_ids. A private zone resolves only inside those VPCs."
  type        = bool
  default     = false
}

variable "vpc_ids" {
  description = "VPCs the private zone is associated with. Required when private_zone is true and create_zone is true."
  type        = list(string)
  default     = []
}

variable "force_destroy" {
  description = "Allow destroying the zone while it still contains records. Leave false in any environment whose DNS someone else depends on."
  type        = bool
  default     = false
}

variable "records" {
  description = <<-EOT
    DNS records, keyed by a stable name that becomes the Terraform address.

    Set either `records` (a plain value list) or `alias` (an AWS target such as
    an ALB), never both. An alias record is preferred for an ALB: it costs
    nothing to resolve, it follows the load balancer's addresses automatically,
    and it can sit on the zone apex where a CNAME cannot.
  EOT
  type = map(object({
    name    = string
    type    = string
    ttl     = optional(number, 300)
    records = optional(list(string))
    alias = optional(object({
      name                   = string
      zone_id                = string
      evaluate_target_health = optional(bool, true)
    }))
    set_identifier          = optional(string)
    health_check_id         = optional(string)
    weighted_routing_weight = optional(number)
    allow_overwrite         = optional(bool, false)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, r in var.records : (r.records != null) != (r.alias != null)
    ])
    error_message = "Each record must set exactly one of records or alias."
  }
}

variable "tags" {
  description = "Tags applied to the hosted zone."
  type        = map(string)
  default     = {}
}
