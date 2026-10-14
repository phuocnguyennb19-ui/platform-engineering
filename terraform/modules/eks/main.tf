locals {
  # Explicit bool: kms_key_arn is unknown at plan when the key is built in the same stack.
  create_kms_key = var.create_kms_key != null ? var.create_kms_key : var.kms_key_arn == null

  node_group_defaults = {
    # Hop limit 1: pods cannot reach IMDS for the node role's credentials - use IRSA.
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 1
      instance_metadata_tags      = "disabled"
    }

    ebs_optimized     = true
    enable_monitoring = true

    iam_role_attach_cni_policy = true

    # AWS caps name_prefix at 38 chars; "<cluster>-<group>-eks-node-group-" overflows it.
    iam_role_use_name_prefix = false
  }

  node_groups = {
    for k, g in var.node_groups : k => {
      name = "${var.cluster_name}-${k}"

      instance_types = g.instance_types
      capacity_type  = g.capacity_type
      ami_type       = g.ami_type

      min_size     = g.min_size
      max_size     = g.max_size
      desired_size = g.desired_size

      subnet_ids = coalesce(g.subnet_ids, var.subnet_ids)

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = g.disk_size
            volume_type           = g.disk_type
            encrypted             = true
            kms_key_id            = var.kms_key_arn
            delete_on_termination = true
          }
        }
      }

      labels = g.labels
      taints = g.taints

      update_config = {
        max_unavailable = g.max_unavailable
      }

      force_update_version = g.force_update_version

      vpc_security_group_ids = var.node_security_group_ids

      tags = merge(var.tags, g.tags)
    }
  }

  cluster_addons = {
    for k, a in var.cluster_addons : k => merge(a, {
      # The upstream module reads addon_version; a pin set as `version` alone is silently ignored.
      addon_version            = a.version
      service_account_role_arn = a.irsa_role_key != null ? aws_iam_role.irsa[a.irsa_role_key].arn : a.service_account_role_arn
    })
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.subnet_ids
  control_plane_subnet_ids = var.control_plane_subnet_ids

  cluster_endpoint_private_access      = var.cluster_endpoint_private_access
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access ? var.cluster_endpoint_public_access_cidrs : []

  cluster_additional_security_group_ids = var.cluster_security_group_ids

  create_kms_key = local.create_kms_key

  cluster_encryption_config = merge(
    { resources = ["secrets"] },
    local.create_kms_key ? {} : { provider_key_arn = var.kms_key_arn },
  )

  cluster_enabled_log_types              = var.cluster_enabled_log_types
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.cluster_log_retention_days
  cloudwatch_log_group_kms_key_id        = var.cluster_log_kms_key_arn

  authentication_mode                      = var.authentication_mode
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  access_entries                           = var.access_entries

  enable_irsa = var.enable_irsa

  cluster_addons = local.cluster_addons

  eks_managed_node_group_defaults = local.node_group_defaults
  eks_managed_node_groups         = local.node_groups

  tags = var.tags
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = var.enable_irsa ? var.irsa_roles : {}

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = [for sa in each.value.namespace_service_accounts : "system:serviceaccount:${sa}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = var.enable_irsa ? var.irsa_roles : {}

  name               = "${var.cluster_name}-irsa-${each.key}"
  description        = each.value.description
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[each.key].json

  tags = merge(var.tags, { Name = "${var.cluster_name}-irsa-${each.key}" })
}

resource "aws_iam_role_policy_attachment" "irsa" {
  for_each = merge([
    for role_key, role in(var.enable_irsa ? var.irsa_roles : {}) : {
      for arn in role.managed_policy_arns :
      "${role_key}:${arn}" => { role = role_key, arn = arn }
    }
  ]...)

  role       = aws_iam_role.irsa[each.value.role].name
  policy_arn = each.value.arn
}

resource "aws_iam_role_policy" "irsa_inline" {
  for_each = {
    for k, v in(var.enable_irsa ? var.irsa_roles : {}) : k => v
    if v.inline_policy != null
  }

  name   = "${var.cluster_name}-irsa-${each.key}"
  role   = aws_iam_role.irsa[each.key].id
  policy = each.value.inline_policy
}

data "aws_region" "current" {}
