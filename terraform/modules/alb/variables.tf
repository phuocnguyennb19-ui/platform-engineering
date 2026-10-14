variable "name" {
  description = "Load balancer name. Must be 32 characters or fewer — AWS rejects longer names, and the error arrives at apply time, not plan time."
  type        = string

  validation {
    condition     = length(var.name) <= 32
    error_message = "ALB names are limited to 32 characters by AWS."
  }
}

variable "vpc_id" {
  description = "VPC the load balancer and its target groups live in. From the foundation: module.vpc.vpc_id."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets to place the load balancer in — at least two, in different AZs. Public subnets for an internet-facing ALB, private for an internal one."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "An ALB requires subnets in at least two availability zones."
  }
}

variable "security_group_ids" {
  description = "Security groups for the load balancer. From module.security_groups.alb_sg_id."
  type        = list(string)
}

variable "internal" {
  description = "Internal (VPC-only) rather than internet-facing. An internal ALB has no public address and belongs in the private subnets."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listener. From module.acm.certificate_arn. Null creates an HTTP-only listener, which is only acceptable for an internal ALB behind another TLS terminator."
  type        = string
  default     = null
}

variable "enable_https" {
  description = "Create the HTTPS listener. Set it explicitly — true alongside certificate_arn — whenever that certificate is issued in the same configuration: its ARN is unknown at plan, and inferring this from it fails the plan. Null infers it from certificate_arn != null."
  type        = bool
  default     = null
}

variable "additional_certificate_arns" {
  description = "Extra certificates attached to the HTTPS listener via SNI, for serving multiple domains from one ALB."
  type        = list(string)
  default     = []
}

variable "ssl_policy" {
  description = "TLS negotiation policy. The default is the TLS 1.3 + forward-secrecy policy; drop to a TLS 1.2 policy only for a client that genuinely cannot do better, and record why."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
}

variable "enable_http_redirect" {
  description = <<-EOT
    With HTTPS on, serve a 301 from port 80 to 443. False closes port 80 entirely rather
    than serving application traffic on it: the listener set becomes HTTPS only.

    With HTTPS off this has no effect — port 80 forwards to the default target group, which is
    only acceptable for an internal ALB behind another TLS terminator.
  EOT
  type        = bool
  default     = true
}

variable "target_groups" {
  description = <<-EOT
    Target groups, keyed by a short name that listener rules refer to.

    target_type "ip" is the right choice for EKS with the AWS Load Balancer
    Controller (traffic goes straight to the pod, skipping the kube-proxy hop)
    and for Fargate. "instance" is for EC2 behind an autoscaling group.

    Targets themselves are attached outside this module — by the controller in
    Kubernetes, or by an ASG's target_group_arns. That is why create_attachment
    defaults to false: the module creates the group, something else fills it.
  EOT
  type = map(object({
    port                          = optional(number, 8080)
    protocol                      = optional(string, "HTTP")
    protocol_version              = optional(string, "HTTP1")
    target_type                   = optional(string, "ip")
    deregistration_delay          = optional(number, 30)
    slow_start                    = optional(number, 0)
    load_balancing_algorithm_type = optional(string, "round_robin")
    health_check = optional(object({
      enabled             = optional(bool, true)
      path                = optional(string, "/healthz")
      port                = optional(string, "traffic-port")
      protocol            = optional(string, "HTTP")
      matcher             = optional(string, "200")
      interval            = optional(number, 15)
      timeout             = optional(number, 5)
      healthy_threshold   = optional(number, 2)
      unhealthy_threshold = optional(number, 3)
    }), {})
    stickiness = optional(object({
      enabled         = optional(bool, false)
      type            = optional(string, "lb_cookie")
      cookie_duration = optional(number, 86400)
    }), {})
    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for k, t in var.target_groups : contains(["ip", "instance", "lambda", "alb"], t.target_type)])
    error_message = "target_type must be one of ip, instance, lambda, alb."
  }
}

variable "default_target_group_key" {
  description = "Target group the HTTPS listener forwards to when no rule matches. Must be a key in target_groups."
  type        = string
  default     = null
}

variable "listener_rules" {
  description = <<-EOT
    HTTPS listener rules, keyed by a short name. Lower priority numbers are
    evaluated first; anything that matches no rule falls through to
    default_target_group_key.
  EOT
  type = map(object({
    priority         = number
    target_group_key = string
    path_patterns    = optional(list(string))
    host_headers     = optional(list(string))
    http_headers     = optional(map(list(string)), {})
    source_ips       = optional(list(string))
  }))
  default = {}
}

variable "enable_access_logs" {
  description = "Write ALB access logs to S3. These are the only per-request record an ALB produces; without them a latency or 5xx investigation has nothing below the CloudWatch aggregate."
  type        = bool
  default     = true
}

variable "access_logs_bucket" {
  description = "Existing S3 bucket for access logs. Null creates one (see create_access_logs_bucket)."
  type        = string
  default     = null
}

variable "create_access_logs_bucket" {
  description = "Create the access log bucket, with the bucket policy the regional ELB account needs, public access blocked, encryption on and a lifecycle rule."
  type        = bool
  default     = true
}

variable "access_logs_retention_days" {
  description = "Days before an access log object expires. ALB logs accumulate quickly on a busy service."
  type        = number
  default     = 90
}

variable "access_logs_prefix" {
  description = "Key prefix inside the bucket."
  type        = string
  default     = "alb"
}

variable "enable_deletion_protection" {
  description = "Refuse to delete the load balancer until this is turned off. On in production: a `terraform destroy` aimed at the wrong workspace stops here."
  type        = bool
  default     = false
}

variable "idle_timeout" {
  description = "Seconds an idle connection is held open. Raise it for long-polling or streaming; the backend's own timeout must be higher than this or you get intermittent 502s."
  type        = number
  default     = 60
}

variable "enable_http2" {
  description = "Enable HTTP/2 between client and load balancer."
  type        = bool
  default     = true
}

variable "drop_invalid_header_fields" {
  description = "Drop headers with invalid characters rather than forwarding them. Leave true — forwarding malformed headers is the basis of request-smuggling attacks against the backend."
  type        = bool
  default     = true
}

variable "desync_mitigation_mode" {
  description = "HTTP desync mitigation: monitor, defensive or strictest."
  type        = string
  default     = "defensive"

  validation {
    condition     = contains(["monitor", "defensive", "strictest"], var.desync_mitigation_mode)
    error_message = "desync_mitigation_mode must be monitor, defensive or strictest."
  }
}

variable "enable_cross_zone_load_balancing" {
  description = "Spread traffic across targets in every AZ. Always on for an ALB and not billable; exposed for completeness."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the load balancer and its target groups."
  type        = map(string)
  default     = {}
}

variable "use_elb_service_account_principal" {
  description = "Include the regional ELB service account in the access log bucket policy. Required in regions whose Availability Zones launched before August 2022 (most of them). Turn off only in a newer region, where AWS assigns no ELB service account and the lookup itself fails."
  type        = bool
  default     = true
}
