variable "name" {
  description = "Name prefix for every security group, conventionally \"<project>-<environment>\"."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to. Comes from the foundation: module.vpc.vpc_id."
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR. Used only where a security group reference is impossible — ALB egress to targets, whose port varies per target group."
  type        = string
}

variable "tags" {
  description = "Tags applied to every security group."
  type        = map(string)
  default     = {}
}

variable "create_alb_sg" {
  description = "Create the ALB security group — the only tier that accepts traffic from outside the VPC."
  type        = bool
  default     = true
}

variable "create_eks_sg" {
  description = "Create the EKS cluster and node security groups."
  type        = bool
  default     = true
}

variable "create_ec2_sg" {
  description = "Create the EC2 application security group."
  type        = bool
  default     = true
}

variable "create_ecs_sg" {
  description = "Create the ECS task security group. Fargate tasks get their own ENI, so the task is the security boundary — not the instance it happens to run on. Defaults off because an environment without ECS should not carry an empty group."
  type        = bool
  default     = false
}

variable "create_rds_sg" {
  description = "Create the RDS security group."
  type        = bool
  default     = true
}

variable "create_elasticache_sg" {
  description = "Create the ElastiCache security group."
  type        = bool
  default     = false
}

variable "create_lambda_sg" {
  description = "Create the security group for VPC-attached Lambda functions."
  type        = bool
  default     = false
}

variable "create_bastion_sg" {
  description = "Create the bastion security group. Prefer AWS Systems Manager Session Manager over a bastion host: it needs no inbound rule, no key pair and no public IP, and it is audited in CloudTrail. The iam module attaches the SSM policy for exactly this reason."
  type        = bool
  default     = false
}

variable "allow_ecs_to_ecs" {
  description = "Allow ECS tasks to reach each other on application_port, referencing the ECS security group itself — what ECS Service Connect needs for one service to call another privately. Off by default: tasks then accept traffic from the ALB only."
  type        = bool
  default     = false
}

variable "application_port" {
  description = "Port the application listens on behind the ALB. Used for the ALB -> EC2 and ALB -> EKS node rules."
  type        = number
  default     = 8080
}

variable "database_port" {
  description = "Database port. 5432 for PostgreSQL, 3306 for MySQL."
  type        = number
  default     = 5432

  validation {
    condition     = var.database_port > 0 && var.database_port <= 65535
    error_message = "database_port must be a valid TCP port."
  }
}

variable "cache_port" {
  description = "ElastiCache port. 6379 for Redis, 11211 for Memcached."
  type        = number
  default     = 6379
}

variable "alb_ingress_cidrs" {
  description = "Source CIDRs allowed to reach the ALB. 0.0.0.0/0 is correct for an internet-facing ALB and wrong for an internal one — narrow it to the VPC or the corporate range when internal is true."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "alb_allow_http" {
  description = "Open port 80 on the ALB. Only useful to serve the 301 redirect to HTTPS; the ALB module never terminates application traffic on 80."
  type        = bool
  default     = true
}

variable "bastion_allowed_cidrs" {
  description = "Source CIDRs allowed to SSH to the bastion. Must be a narrow, known range — a VPN or office egress address."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.bastion_allowed_cidrs, "0.0.0.0/0")
    error_message = "bastion_allowed_cidrs must not contain 0.0.0.0/0. Exposing SSH to the internet is never the right answer; use Session Manager, or name the office/VPN range."
  }
}

variable "eks_public_api_allowed_cidrs" {
  description = "Source CIDRs allowed to reach the EKS public API endpoint. Applied to the cluster security group. Leave empty when the API endpoint is private."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.eks_public_api_allowed_cidrs, "0.0.0.0/0")
    error_message = "eks_public_api_allowed_cidrs must not contain 0.0.0.0/0. Set cluster_endpoint_public_access = false on the eks module, or name the ranges that need it."
  }
}

variable "additional_ingress_rules" {
  description = <<-EOT
    Extra ingress rules, keyed by a stable name that becomes the Terraform
    resource address — changing a key replaces the rule.

    Exactly one of source_security_group ("alb"|"eks_cluster"|"eks_node"|"ec2"|
    "ecs"|"rds"|"elasticache"|"lambda"|"bastion") or cidr_ipv4 must be set. Prefer the
    security group reference: it keeps working when addresses change.
  EOT
  type = map(object({
    security_group        = string
    from_port             = number
    to_port               = number
    ip_protocol           = optional(string, "tcp")
    source_security_group = optional(string)
    cidr_ipv4             = optional(string)
    description           = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, r in var.additional_ingress_rules :
      (r.source_security_group != null) != (r.cidr_ipv4 != null)
    ])
    error_message = "Each additional ingress rule must set exactly one of source_security_group or cidr_ipv4."
  }
}
