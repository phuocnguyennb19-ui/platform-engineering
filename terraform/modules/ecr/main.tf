locals {
  repository_names = {
    for k, v in var.repositories : k => var.use_name_prefix ? "${var.name}/${k}" : k
  }
}

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = local.repository_names[each.key]
  image_tag_mutability = each.value.image_tag_mutability
  force_delete         = each.value.force_delete

  image_scanning_configuration {
    scan_on_push = each.value.scan_on_push
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn != null ? "KMS" : "AES256"
    kms_key         = var.kms_key_arn
  }

  tags = merge(var.tags, each.value.tags, { Name = local.repository_names[each.key] })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = var.repositories

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${each.value.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = each.value.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${each.value.keep_tagged_count} released images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = each.value.tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = each.value.keep_tagged_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

data "aws_iam_policy_document" "pull" {
  for_each = { for k, v in var.repositories : k => v if length(v.pull_principal_arns) > 0 }

  statement {
    sid    = "AllowPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = each.value.pull_principal_arns
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
  }
}

resource "aws_ecr_repository_policy" "this" {
  for_each = data.aws_iam_policy_document.pull

  repository = aws_ecr_repository.this[each.key].name
  policy     = each.value.json
}
