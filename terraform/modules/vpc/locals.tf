data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = var.azs != null ? var.azs : slice(data.aws_availability_zones.available.names, 0, var.az_count)

  az_count = length(local.azs)

  # From a /16: private /20s at 0-2, public /24s at 240+, database /24s at 250+.
  derived_private_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 4, i)]
  derived_public_subnet_cidrs   = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 8, 240 + i)]
  derived_database_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 8, 250 + i)]

  private_subnet_cidrs  = var.private_subnet_cidrs != null ? var.private_subnet_cidrs : local.derived_private_subnet_cidrs
  public_subnet_cidrs   = var.public_subnet_cidrs != null ? var.public_subnet_cidrs : local.derived_public_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs != null ? var.database_subnet_cidrs : local.derived_database_subnet_cidrs

  eks_shared_tags = { for c in var.eks_cluster_names : "kubernetes.io/cluster/${c}" => "shared" }

  public_tags = merge(
    { Tier = "public" },
    length(var.eks_cluster_names) > 0 ? merge(local.eks_shared_tags, { "kubernetes.io/role/elb" = "1" }) : {},
    var.public_subnet_tags,
  )

  private_tags = merge(
    { Tier = "private-app" },
    length(var.eks_cluster_names) > 0 ? merge(local.eks_shared_tags, { "kubernetes.io/role/internal-elb" = "1" }) : {},
    var.private_subnet_tags,
  )

  database_tags = merge(
    { Tier = "private-data" },
    var.database_subnet_tags,
  )
}
