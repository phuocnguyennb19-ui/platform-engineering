data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_root = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}

data "aws_iam_policy_document" "key" {
  for_each = var.keys

  # Account-root delegation: without it the key becomes unmanageable.
  dynamic "statement" {
    for_each = each.value.enable_default_policy ? [1] : []

    content {
      sid       = "EnableAccountIAMPolicies"
      effect    = "Allow"
      actions   = ["kms:*"]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = [local.account_root]
      }
    }
  }

  dynamic "statement" {
    for_each = length(each.value.key_administrator_arns) > 0 ? [1] : []

    content {
      sid    = "KeyAdministrators"
      effect = "Allow"
      actions = [
        "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
        "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
        "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource",
        "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = each.value.key_administrator_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(each.value.key_user_arns) > 0 ? [1] : []

    content {
      sid    = "KeyUsers"
      effect = "Allow"
      actions = [
        "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
        "kms:GenerateDataKey*", "kms:DescribeKey",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = each.value.key_user_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(each.value.service_principals) > 0 ? [1] : []

    content {
      sid    = "ServicePrincipals"
      effect = "Allow"
      actions = [
        "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
        "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant",
      ]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = each.value.service_principals
      }

      condition {
        test     = "StringEquals"
        variable = "kms:CallerAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  for_each = var.keys

  description             = each.value.description
  deletion_window_in_days = each.value.deletion_window_in_days
  enable_key_rotation     = each.value.enable_rotation
  rotation_period_in_days = each.value.enable_rotation ? each.value.rotation_period_in_days : null
  multi_region            = each.value.multi_region
  policy                  = data.aws_iam_policy_document.key[each.key].json

  tags = merge(var.tags, each.value.tags, {
    Name    = "${var.name}-${each.key}"
    Purpose = each.key
  })
}

resource "aws_kms_alias" "this" {
  for_each = var.keys

  name          = "alias/${var.name}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
