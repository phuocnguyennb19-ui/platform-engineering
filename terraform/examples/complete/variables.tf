variable "environment" {
  description = "Environment name. Drives naming, tagging and the production hardening floor in main.tf."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" {
  description = "AWS region for every resource in this environment."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region must be an AWS region identifier, e.g. ap-southeast-1."
  }
}

variable "project" {
  description = "Project name. Combined with environment it becomes the name prefix for everything."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 2-21 characters."
  }
}

variable "owner" {
  description = "Team accountable for this environment. Becomes the Owner tag, which is what makes an unexplained resource traceable to a human."
  type        = string
  default     = "platform-engineering"
}

variable "cost_center" {
  description = "Cost centre tag, used for chargeback in Cost Explorer."
  type        = string
  default     = "platform"
}

variable "additional_tags" {
  description = "Extra tags merged into the default tag set applied to every resource."
  type        = map(string)
  default     = {}
}

variable "assume_role_arn" {
  description = "Role the provider assumes. Set this so each environment is applied into its own account with its own role rather than by a long-lived key. Null uses the ambient credential chain."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "VPC CIDR. Keep environment ranges non-overlapping: overlapping CIDRs make VPC peering and Transit Gateway attachment impossible later, and the cost of fixing it is a re-address."
  type        = string
}

variable "az_count" {
  description = "Availability zones to spread across."
  type        = number
  default     = 3
}

variable "azs" {
  description = "Explicit AZ names. Null takes the first az_count the region offers. Pin these in staging and prod."
  type        = list(string)
  default     = null
}

variable "single_nat_gateway" {
  description = "Route all private subnets through one NAT gateway. Saves roughly two thirds of the NAT bill and makes egress a single-AZ dependency. Forced to false in prod."
  type        = bool
  default     = false
}

variable "enable_nat_gateway" {
  description = "Create NAT gateways at all."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "VPC flow logs to CloudWatch. Forced on in prod."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Flow log retention."
  type        = number
  default     = 30
}

variable "interface_endpoints" {
  description = "Interface VPC endpoints to create, e.g. [\"ecr.api\",\"ecr.dkr\",\"logs\",\"ssm\",\"ssmmessages\",\"ec2messages\"]. Each is billed hourly per AZ."
  type        = list(string)
  default     = []
}

variable "enable_alb" {
  description = "Deploy the Application Load Balancer."
  type        = bool
  default     = false
}

variable "enable_eks" {
  description = "Deploy the EKS cluster and its node groups."
  type        = bool
  default     = false
}

variable "enable_ec2" {
  description = "Deploy EC2 instances."
  type        = bool
  default     = false
}

variable "enable_rds" {
  description = "Deploy the RDS instance."
  type        = bool
  default     = false
}

variable "enable_elasticache" {
  description = "Deploy the ElastiCache replication group."
  type        = bool
  default     = false
}

variable "enable_lambda" {
  description = "Deploy Lambda functions."
  type        = bool
  default     = false
}

variable "enable_ecr" {
  description = "Deploy ECR repositories."
  type        = bool
  default     = false
}

variable "enable_route53" {
  description = "Manage DNS. Required by enable_acm, which needs a zone to write validation records into."
  type        = bool
  default     = false
}

variable "enable_acm" {
  description = "Issue an ACM certificate for the ALB. Requires enable_route53."
  type        = bool
  default     = false
}

variable "enable_bastion_sg" {
  description = "Create the bastion security group. Prefer Session Manager, which the EC2 instance role already allows."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Hosted zone name, e.g. \"example.com\". Required when enable_route53 is true."
  type        = string
  default     = null
}

variable "create_dns_zone" {
  description = "Create the hosted zone rather than looking it up. False is usual — the apex zone is normally registered once and shared."
  type        = bool
  default     = false
}

variable "app_hostname" {
  description = "Hostname the ALB is published under, e.g. \"api\" produces api.<domain_name>. Null publishes at the zone apex."
  type        = string
  default     = null
}

variable "certificate_sans" {
  description = "Extra names on the ACM certificate."
  type        = list(string)
  default     = []
}

variable "alb_internal" {
  description = "Make the ALB internal (VPC-only)."
  type        = bool
  default     = false
}

variable "alb_ingress_cidrs" {
  description = "Source CIDRs allowed to reach the ALB."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "application_port" {
  description = "Port the application listens on behind the ALB. Used for both the target group and the ALB-to-compute security group rules."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "ALB health check path."
  type        = string
  default     = "/healthz"
}

variable "alb_access_logs_retention_days" {
  description = "Retention for ALB access log objects in S3."
  type        = number
  default     = 90
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version, e.g. \"1.31\"."
  type        = string
  default     = "1.31"
}

variable "eks_node_groups" {
  description = "EKS managed node groups. See modules/eks/variables.tf for the full shape."
  type        = any
  default     = {}
}

variable "eks_public_api_access" {
  description = "Expose the EKS API server publicly. Forced to false in prod."
  type        = bool
  default     = false
}

variable "eks_public_api_cidrs" {
  description = "Source CIDRs allowed to reach the public EKS API endpoint."
  type        = list(string)
  default     = []
}

variable "eks_irsa_roles" {
  description = "IAM roles assumable by Kubernetes service accounts. See modules/eks/variables.tf."
  type        = any
  default     = {}
}

variable "eks_access_entries" {
  description = "EKS access entries mapping IAM principals to Kubernetes permissions."
  type        = any
  default     = {}
}

variable "ec2_instances" {
  description = <<-EOT
    EC2 instances, keyed by short name. subnet_id is resolved by main.tf from
    the foundation's private subnets using subnet_index, so an environment never
    has to name a subnet ID that does not exist until apply time.
  EOT
  type = map(object({
    subnet_index     = optional(number, 0)
    instance_type    = optional(string, "t3.medium")
    ami_id           = optional(string)
    root_volume_size = optional(number, 30)
    user_data        = optional(string)
    tags             = optional(map(string), {})
  }))
  default = {}
}

variable "rds_engine" {
  description = "postgres or mysql."
  type        = string
  default     = "postgres"
}

variable "rds_engine_version" {
  description = "Engine version, e.g. \"16.4\"."
  type        = string
  default     = "16.4"
}

variable "rds_family" {
  description = "Parameter group family, e.g. \"postgres16\"."
  type        = string
  default     = "postgres16"
}

variable "rds_major_engine_version" {
  description = "Major engine version for the option group, e.g. \"16\"."
  type        = string
  default     = "16"
}

variable "rds_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "rds_allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 50
}

variable "rds_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB."
  type        = number
  default     = 200
}

variable "rds_multi_az" {
  description = "Run a standby in a second AZ. Forced on in prod."
  type        = bool
  default     = false
}

variable "rds_backup_retention_period" {
  description = "Days of automated backups. Floored at 30 in prod."
  type        = number
  default     = 7
}

variable "rds_database_name" {
  description = "Initial database name."
  type        = string
  default     = "appdb"
}

variable "rds_username" {
  description = "Master username. The password is generated by AWS into Secrets Manager and never enters Terraform."
  type        = string
  default     = "dbadmin"
}

variable "elasticache_node_type" {
  description = "Cache node type."
  type        = string
  default     = "cache.t4g.micro"
}

variable "elasticache_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "elasticache_parameter_group_family" {
  description = "Cache parameter group family."
  type        = string
  default     = "redis7"
}

variable "elasticache_num_cache_clusters" {
  description = "Nodes in the replication group: one primary plus n-1 replicas. Floored at 2 in prod."
  type        = number
  default     = 1
}

variable "elasticache_auth_token_secret_arn" {
  description = "Secrets Manager ARN holding the Redis AUTH token. Create the secret outside Terraform so the token never enters state."
  type        = string
  default     = null
}

variable "ecr_repositories" {
  description = "ECR repositories to create. See modules/ecr/variables.tf."
  type        = any
  default     = {}
}

variable "ecr_use_name_prefix" {
  description = "Prefix repository names with <project>-<environment>. False shares one repository across environments, which is what image promotion requires."
  type        = bool
  default     = false
}

variable "lambda_functions" {
  description = "Lambda functions to create. See modules/lambda/variables.tf."
  type        = any
  default     = {}
}

variable "bastion_allowed_cidrs" {
  description = "Administrative source ranges allowed to SSH to the bastion. Rejected if it contains 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary applied to every IAM role this environment creates."
  type        = string
  default     = null
}

variable "alarm_subscriptions" {
  description = <<-EOT
    Subscriptions on the alarm SNS topic, keyed by name, e.g.
    { oncall = { protocol = "https", endpoint = "https://events.pagerduty.com/..." } }

    An email subscription stays PENDING_CONFIRMATION until a human clicks the
    link; Terraform reports success either way, so an unconfirmed email address
    is a silent alerting gap.
  EOT
  type = map(object({
    protocol = string
    endpoint = string
  }))
  default = {}
}

variable "log_retention_days" {
  description = "Default retention for application log groups. Floored at 90 in prod."
  type        = number
  default     = 30
}

variable "create_alarm_dashboard" {
  description = "Create a CloudWatch dashboard showing every alarm's state."
  type        = bool
  default     = false
}
