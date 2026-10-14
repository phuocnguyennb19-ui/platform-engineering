data "aws_partition" "current" {}

locals {
  managed_policy_prefix = "arn:${data.aws_partition.current.partition}:iam::aws:policy"
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  count = var.create_ec2_instance_role ? 1 : 0

  name                 = "${var.name}-ec2-instance"
  description          = "Instance role for EC2 application instances in ${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.ec2_trust.json
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(var.tags, { Name = "${var.name}-ec2-instance" })
}

resource "aws_iam_instance_profile" "ec2" {
  count = var.create_ec2_instance_role ? 1 : 0

  name = "${var.name}-ec2-instance"
  role = aws_iam_role.ec2[0].name

  tags = merge(var.tags, { Name = "${var.name}-ec2-instance" })
}

locals {
  ec2_managed_policies = var.create_ec2_instance_role ? toset(concat(
    var.ec2_enable_ssm ? ["${local.managed_policy_prefix}/AmazonSSMManagedInstanceCore"] : [],
    var.ec2_enable_cloudwatch_agent ? ["${local.managed_policy_prefix}/CloudWatchAgentServerPolicy"] : [],
    var.ec2_additional_policy_arns,
  )) : toset([])
}

resource "aws_iam_role_policy_attachment" "ec2_managed" {
  for_each = local.ec2_managed_policies

  role       = aws_iam_role.ec2[0].name
  policy_arn = each.value
}

data "aws_iam_policy_document" "ec2_inline" {
  count = var.create_ec2_instance_role ? 1 : 0

  dynamic "statement" {
    for_each = length(var.ec2_ecr_pull_repository_arns) > 0 ? [1] : []

    content {
      sid       = "ECRAuthToken"
      effect    = "Allow"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.ec2_ecr_pull_repository_arns) > 0 ? [1] : []

    content {
      sid    = "ECRPull"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]
      resources = var.ec2_ecr_pull_repository_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.ec2_s3_read_bucket_arns) > 0 ? [1] : []

    content {
      sid       = "S3ListBuckets"
      effect    = "Allow"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = var.ec2_s3_read_bucket_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.ec2_s3_read_bucket_arns) > 0 ? [1] : []

    content {
      sid       = "S3ReadObjects"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:GetObjectVersion"]
      resources = [for b in var.ec2_s3_read_bucket_arns : "${b}/*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.ec2_kms_key_arns) > 0 ? [1] : []

    content {
      sid    = "KMSUse"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      resources = var.ec2_kms_key_arns
    }
  }

  # A policy document needs at least one statement; this one grants nothing.
  statement {
    sid       = "IdentitySelfCheck"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_inline" {
  count = var.create_ec2_instance_role ? 1 : 0

  name   = "${var.name}-ec2-instance"
  role   = aws_iam_role.ec2[0].id
  policy = data.aws_iam_policy_document.ec2_inline[0].json
}

data "aws_iam_policy_document" "rds_monitoring_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  count = var.create_rds_monitoring_role ? 1 : 0

  name                 = "${var.name}-rds-monitoring"
  description          = "Assumed by RDS Enhanced Monitoring to publish OS metrics for ${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.rds_monitoring_trust.json
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(var.tags, { Name = "${var.name}-rds-monitoring" })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count = var.create_rds_monitoring_role ? 1 : 0

  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "${local.managed_policy_prefix}/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_iam_role" "additional" {
  for_each = var.additional_roles

  name                 = "${var.name}-${each.key}"
  description          = each.value.description
  assume_role_policy   = each.value.assume_role_policy
  permissions_boundary = var.permissions_boundary_arn
  max_session_duration = each.value.max_session_duration

  tags = merge(var.tags, each.value.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = merge([
    for role_key, role in var.additional_roles : {
      for arn in role.managed_policy_arns :
      "${role_key}:${arn}" => { role = role_key, arn = arn }
    }
  ]...)

  role       = aws_iam_role.additional[each.value.role].name
  policy_arn = each.value.arn
}

resource "aws_iam_role_policy" "additional_inline" {
  for_each = merge([
    for role_key, role in var.additional_roles : {
      for policy_name, policy_json in role.inline_policies :
      "${role_key}:${policy_name}" => { role = role_key, name = policy_name, json = policy_json }
    }
  ]...)

  name   = each.value.name
  role   = aws_iam_role.additional[each.value.role].id
  policy = each.value.json
}
