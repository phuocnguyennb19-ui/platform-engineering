variable "name" {
  description = "Name prefix for the VPC and every subnet, route table and gateway inside it. Conventionally \"<project>-<environment>\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be lowercase alphanumeric with hyphens, 2-41 characters."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "cidr_block" {
  description = "IPv4 CIDR for the VPC. A /16 gives the default subnet layout room to grow; anything smaller than /20 will not fit three tiers across three AZs."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR, e.g. 10.10.0.0/16."
  }

  validation {
    condition     = tonumber(split("/", var.cidr_block)[1]) <= 20
    error_message = "cidr_block must be /20 or larger to fit the three-tier subnet layout."
  }
}

variable "az_count" {
  description = "How many availability zones to spread across. Ignored when azs is set explicitly. Production should use at least 3 so a single-AZ failure never removes quorum."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6."
  }
}

variable "azs" {
  description = "Explicit availability zone names, e.g. [\"ap-southeast-1a\",\"ap-southeast-1b\"]. Null means \"take the first az_count zones the region offers\". Pin these in production so a zone-ordering change never renumbers your subnets."
  type        = list(string)
  default     = null
}

variable "public_subnet_cidrs" {
  description = "Explicit public subnet CIDRs. Null derives them from cidr_block (see locals.tf). Set explicitly in production."
  type        = list(string)
  default     = null
}

variable "private_subnet_cidrs" {
  description = "Explicit private application subnet CIDRs. Null derives them from cidr_block."
  type        = list(string)
  default     = null
}

variable "database_subnet_cidrs" {
  description = "Explicit private database subnet CIDRs. Null derives them from cidr_block. These subnets get no route to the internet at all."
  type        = list(string)
  default     = null
}

variable "enable_nat_gateway" {
  description = "Create NAT gateways so private subnets can reach the internet outbound. Turning this off leaves private workloads with no egress — they will need VPC endpoints for every AWS API they call."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Route every private subnet through ONE NAT gateway. Cheap, and a single-AZ failure takes egress down for the whole VPC. Correct for dev, wrong for production."
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "One NAT gateway per availability zone. This is the production setting: an AZ failure removes only that AZ's egress."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Capture VPC flow logs to CloudWatch Logs. This is the only record of who talked to what inside the VPC; without it a security investigation has nothing to read."
  type        = bool
  default     = true
}

variable "flow_log_traffic_type" {
  description = "Which traffic to record: ACCEPT, REJECT or ALL."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for flow logs, in days. 0 means never expire."
  type        = number
  default     = 90
}

variable "flow_log_kms_key_arn" {
  description = "KMS key ARN encrypting the flow log group. Null uses the CloudWatch Logs service key."
  type        = string
  default     = null
}

variable "create_database_subnet_group" {
  description = "Create an RDS DB subnet group over the database subnets. The RDS module consumes its name, which is how RDS is prevented from ever landing in a public subnet."
  type        = bool
  default     = true
}

variable "create_elasticache_subnet_group" {
  description = "Create an ElastiCache subnet group over the database subnets."
  type        = bool
  default     = true
}

variable "enable_s3_gateway_endpoint" {
  description = "Gateway VPC endpoint for S3. Free, and it keeps S3 traffic off the NAT gateway — this usually pays for itself immediately."
  type        = bool
  default     = true
}

variable "enable_dynamodb_gateway_endpoint" {
  description = "Gateway VPC endpoint for DynamoDB. Also free."
  type        = bool
  default     = false
}

variable "interface_endpoints" {
  description = "Interface VPC endpoint service names to create in the private subnets, e.g. [\"ecr.api\",\"ecr.dkr\",\"logs\",\"ssm\",\"ssmmessages\",\"ec2messages\",\"sts\"]. Each one is billed hourly plus data, so name only what you use. Requires interface_endpoint_security_group_ids."
  type        = list(string)
  default     = []
}

variable "interface_endpoint_security_group_ids" {
  description = <<-EOT
    Security groups for the interface endpoints. Empty makes this module create
    its own, allowing 443 from the VPC CIDR.

    The self-created group exists to avoid a dependency cycle: the security-groups
    module needs vpc_id from here, so having this module consume a group from
    there would make the two modules depend on each other. Endpoint access is
    governed by the endpoint policy and the VPC boundary in any case.
  EOT
  type        = list(string)
  default     = []
}

variable "eks_cluster_names" {
  description = "EKS cluster names that will run in this VPC. Adds the kubernetes.io/cluster/<name> discovery tags to the subnets so the AWS Load Balancer Controller and Cluster Autoscaler can find them. Purely tags — this creates no EKS resource and no dependency on the EKS module."
  type        = list(string)
  default     = []
}

variable "public_subnet_tags" {
  description = "Extra tags for public subnets, merged over the defaults."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Extra tags for private application subnets, merged over the defaults."
  type        = map(string)
  default     = {}
}

variable "database_subnet_tags" {
  description = "Extra tags for database subnets, merged over the defaults."
  type        = map(string)
  default     = {}
}
