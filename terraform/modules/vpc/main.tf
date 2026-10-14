module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = var.name
  cidr = var.cidr_block
  azs  = local.azs

  private_subnets  = local.private_subnet_cidrs
  public_subnets   = local.public_subnet_cidrs
  database_subnets = local.database_subnet_cidrs

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.single_nat_gateway ? false : var.one_nat_gateway_per_az

  create_database_subnet_group           = var.create_database_subnet_group
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  create_elasticache_subnet_group = false
  map_public_ip_on_launch         = false
  manage_default_security_group   = true
  default_security_group_ingress  = []
  default_security_group_egress   = []
  default_security_group_name     = "${var.name}-default-DO-NOT-USE"

  enable_flow_log                                 = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_logs
  flow_log_traffic_type                           = var.flow_log_traffic_type
  flow_log_destination_type                       = "cloud-watch-logs"
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = var.flow_log_kms_key_arn

  public_subnet_tags   = local.public_tags
  private_subnet_tags  = local.private_tags
  database_subnet_tags = local.database_tags

  tags = var.tags
}

resource "aws_elasticache_subnet_group" "this" {
  count = var.create_elasticache_subnet_group ? 1 : 0

  name        = "${var.name}-cache"
  description = "ElastiCache subnet group for ${var.name} (database tier, no internet route)"
  subnet_ids  = module.vpc.database_subnets

  tags = merge(var.tags, { Name = "${var.name}-cache" })
}

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_gateway_endpoint ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    module.vpc.private_route_table_ids,
    module.vpc.database_route_table_ids,
  )

  tags = merge(var.tags, { Name = "${var.name}-s3-endpoint" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  count = var.enable_dynamodb_gateway_endpoint ? 1 : 0

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    module.vpc.private_route_table_ids,
    module.vpc.database_route_table_ids,
  )

  tags = merge(var.tags, { Name = "${var.name}-dynamodb-endpoint" })
}

locals {
  create_endpoint_sg = length(var.interface_endpoints) > 0 && length(var.interface_endpoint_security_group_ids) == 0

  endpoint_security_group_ids = local.create_endpoint_sg ? [aws_security_group.endpoints[0].id] : var.interface_endpoint_security_group_ids
}

resource "aws_security_group" "endpoints" {
  count = local.create_endpoint_sg ? 1 : 0

  name        = "${var.name}-vpc-endpoints"
  description = "HTTPS from inside the VPC to the interface VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-vpc-endpoints" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = local.create_endpoint_sg ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  cidr_ipv4         = module.vpc.vpc_cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from inside the VPC"

  tags = merge(var.tags, { Name = "${var.name}-vpc-endpoints-https" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = local.endpoint_security_group_ids
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-${replace(each.value, ".", "-")}-endpoint" })
}
