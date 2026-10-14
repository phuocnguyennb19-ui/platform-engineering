module "config" {
  source = "../../shared/config"

  config_root       = "${path.root}/../../../infra-base/terraform"
  applications_root = "${path.root}/../../../applications"
  environment       = var.environment
}

locals {
  core = module.config.core
  name = module.config.name

  tags = merge(module.config.tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Layer       = "core"
  })

  ecs_enabled  = try(local.core.ecs.enabled, false) == true
  eks_enabled  = try(local.core.eks.enabled, false) == true
  alb_enabled  = try(local.core.alb.enabled, false) == true
  alb_internal = try(local.core.alb.internal, false) == true
  iam_enabled  = try(local.core.iam.enabled, false) == true
  dns_enabled  = try(local.core.dns.zone_name, null) != null

  eks_cluster_name = "${local.name}-eks"

  # The module always opens application_port (8080) from the ALB; target_port_range widens it for other ports.
  alb_target_ports = {
    from = try(local.core.alb.target_port_range.from, 8080)
    to   = try(local.core.alb.target_port_range.to, 8080)
  }

  core_errors = concat(
    can(cidrhost(local.core.vpc.cidr, 0)) ? [] : ["infra-base/terraform/environments/${var.environment}/core.yaml: vpc.cidr must be a CIDR block"],
    !local.alb_enabled || local.dns_enabled || local.alb_internal ? [] : ["infra-base/terraform/environments/${var.environment}/core.yaml: a public alb needs dns for its certificate, or set alb.internal"],
    local.alb_target_ports.from <= local.alb_target_ports.to ? [] : ["infra-base/terraform/environments/${var.environment}/core.yaml: alb.target_port_range.from must not exceed to"],
    [for k in keys(local.addon_roles) : "infra-base/terraform/environments/${var.environment}/core.yaml: eks.addon_roles.${k} has no policy; known: ${join(", ", keys(local.addon_policies))}" if !contains(keys(local.addon_policies), k)],
    [for k, r in local.addon_roles : "infra-base/terraform/environments/${var.environment}/core.yaml: eks.addon_roles.${k}.service_accounts must list namespace:serviceaccount entries" if length(r.service_accounts) == 0 || !alltrue([for sa in r.service_accounts : can(regex("^[a-z0-9-]+:[a-z0-9-]+$", sa))])],
  )

  # IAM for cluster add-ons installed from k8s/platform; policies follow each project's documented minimum.
  addon_roles = {
    for k, r in try(local.core.eks.addon_roles, {}) : k => {
      service_accounts = try(tolist(r.service_accounts), [])
    } if local.eks_enabled
  }

  velero_bucket = "${local.name}-velero-${module.config.account_id}"

  addon_policies = {
    external-dns = {
      Version = "2012-10-17"
      Statement = [
        { Effect = "Allow", Action = ["route53:ChangeResourceRecordSets"], Resource = ["arn:aws:route53:::hostedzone/*"] },
        { Effect = "Allow", Action = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"], Resource = ["*"] },
      ]
    }
    cluster-autoscaler = {
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["autoscaling:DescribeAutoScalingGroups", "autoscaling:DescribeAutoScalingInstances", "autoscaling:DescribeLaunchConfigurations", "autoscaling:DescribeScalingActivities", "ec2:DescribeImages", "ec2:DescribeInstanceTypes", "ec2:DescribeLaunchTemplateVersions", "ec2:GetInstanceTypesFromInstanceRequirements", "eks:DescribeNodegroup"]
          Resource = ["*"]
        },
        {
          Effect    = "Allow"
          Action    = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
          Resource  = ["*"]
          Condition = { StringEquals = { "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.eks_cluster_name}" = "owned" } }
        },
      ]
    }
    velero = {
      Version = "2012-10-17"
      Statement = [
        { Effect = "Allow", Action = ["ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:CreateTags", "ec2:CreateVolume", "ec2:CreateSnapshot", "ec2:DeleteSnapshot"], Resource = ["*"] },
        { Effect = "Allow", Action = ["s3:GetObject", "s3:DeleteObject", "s3:PutObject", "s3:PutObjectTagging", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = ["arn:aws:s3:::${local.velero_bucket}/*"] },
        { Effect = "Allow", Action = ["s3:ListBucket"], Resource = ["arn:aws:s3:::${local.velero_bucket}"] },
      ]
    }
  }
}

resource "terraform_data" "validation" {
  input = var.environment

  lifecycle {
    precondition {
      condition     = length(module.config.errors) == 0 && length(local.core_errors) == 0
      error_message = "Invalid configuration:\n${join("\n", concat(module.config.errors, local.core_errors))}"
    }
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name                   = local.name
  cidr_block             = local.core.vpc.cidr
  az_count               = try(local.core.vpc.az_count, 3)
  azs                    = try(local.core.vpc.azs, null)
  enable_nat_gateway     = true
  single_nat_gateway     = try(local.core.vpc.single_nat_gateway, false)
  one_nat_gateway_per_az = !try(local.core.vpc.single_nat_gateway, false)
  enable_flow_logs       = try(local.core.vpc.enable_flow_logs, true)
  eks_cluster_names      = local.eks_enabled ? [local.eks_cluster_name] : []
  tags                   = local.tags
}

module "security_groups" {
  source = "../../modules/security-groups"

  name              = local.name
  vpc_id            = module.vpc.vpc_id
  vpc_cidr_block    = module.vpc.vpc_cidr_block
  create_alb_sg     = local.alb_enabled
  create_ec2_sg     = false
  create_rds_sg     = false
  create_ecs_sg     = local.ecs_enabled
  create_eks_sg     = local.eks_enabled
  alb_ingress_cidrs = try(local.core.alb.ingress_cidrs, ["0.0.0.0/0"])

  additional_ingress_rules = local.alb_enabled && local.ecs_enabled && try(local.core.alb.target_port_range, null) != null ? {
    ecs-from-alb-targets = {
      security_group        = "ecs"
      source_security_group = "alb"
      from_port             = local.alb_target_ports.from
      to_port               = local.alb_target_ports.to
      description           = "Application ports from the ALB to Fargate task ENIs"
    }
  } : {}

  tags = local.tags
}

module "iam" {
  source = "../../modules/iam"
  count  = local.iam_enabled ? 1 : 0

  name                       = local.name
  create_ec2_instance_role   = try(local.core.iam.ec2_instance_role, false)
  create_rds_monitoring_role = try(local.core.iam.rds_monitoring_role, false)
  tags                       = local.tags
}

module "ecs_cluster" {
  source = "../../modules/ecs-cluster"
  count  = local.ecs_enabled ? 1 : 0

  cluster_name        = "${local.name}-ecs"
  fargate_base        = try(local.core.ecs.fargate_base, 1)
  fargate_weight      = try(local.core.ecs.fargate_weight, 1)
  fargate_spot_weight = try(local.core.ecs.fargate_spot_weight, 0)
  container_insights  = try(local.core.ecs.container_insights, true)
  log_retention_days  = try(local.core.logs.retention_days, 90)
  tags                = local.tags
}

module "eks" {
  source = "../../modules/eks"
  count  = local.eks_enabled ? 1 : 0

  cluster_name                   = local.eks_cluster_name
  kubernetes_version             = local.core.eks.version
  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnet_ids
  cluster_endpoint_public_access = try(local.core.eks.endpoint_public_access, false)
  node_groups                    = try(local.core.eks.node_groups, {})
  node_security_group_ids        = [module.security_groups.eks_node_sg_id]
  cluster_security_group_ids     = [module.security_groups.eks_cluster_sg_id]
  cluster_log_retention_days     = try(local.core.logs.retention_days, 90)
  access_entries                 = try(local.core.eks.access_entries, {})

  # Role names are <cluster>-irsa-<key>; k8s/env-values builds the same ARN from the account ID.
  irsa_roles = {
    for k, r in local.addon_roles : k => {
      description                = "${k} add-on (helm-project), ${local.eks_cluster_name}"
      namespace_service_accounts = r.service_accounts
      inline_policy              = jsonencode(local.addon_policies[k])
    } if contains(keys(local.addon_policies), k)
  }

  tags = local.tags
}

# SOPS data key for k8s/env-values secrets; the deploy role decrypts with kms:Decrypt.
module "sops_kms" {
  source = "../../modules/kms"
  count  = try(local.core.sops.kms_key, false) == true ? 1 : 0

  name = local.name

  keys = {
    sops = {
      description   = "SOPS data key for ${local.name} helm-project secrets"
      key_user_arns = try(tolist(local.core.sops.key_user_arns), [])
    }
  }

  tags = local.tags
}

module "velero_bucket" {
  source = "../../modules/s3"
  count  = contains(keys(local.addon_roles), "velero") ? 1 : 0

  name               = local.velero_bucket
  versioning_enabled = true
  tags               = local.tags
}

module "route53" {
  source = "../../modules/route53"
  count  = local.dns_enabled ? 1 : 0

  zone_name   = local.core.dns.zone_name
  create_zone = try(local.core.dns.create_zone, false)
  tags        = local.tags
}

module "acm" {
  source = "../../modules/acm"
  count  = local.dns_enabled ? 1 : 0

  domain_name               = local.core.dns.zone_name
  subject_alternative_names = ["*.${local.core.dns.zone_name}"]
  zone_id                   = module.route53[0].zone_id
  tags                      = local.tags
}

module "alb" {
  source = "../../modules/alb"
  count  = local.alb_enabled ? 1 : 0

  name                       = "${local.name}-alb"
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = local.alb_internal ? module.vpc.private_subnet_ids : module.vpc.public_subnet_ids
  security_group_ids         = [module.security_groups.alb_sg_id]
  internal                   = local.alb_internal
  enable_https               = local.dns_enabled
  certificate_arn            = local.dns_enabled ? module.acm[0].certificate_arn : null
  enable_deletion_protection = try(local.core.alb.deletion_protection, true)

  # The listener needs a default target; applications attach their own rules and groups.
  target_groups = {
    default = {}
  }

  tags = local.tags
}

module "cloudwatch" {
  source = "../../modules/cloudwatch"

  name              = local.name
  create_sns_topic  = true
  sns_subscriptions = try(local.core.alerts.subscriptions, {})
  tags              = local.tags
}
