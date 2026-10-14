module "config" {
  source = "../../shared/config"

  config_root       = "${path.root}/../../../infra-base/terraform"
  applications_root = "${path.root}/../../../applications"
  environment       = var.environment
}

locals {
  ecr = try(module.config.core.ecr, {})

  tags = merge(module.config.tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Layer       = "registry"
  })

  pull_principal_arns = [for id in module.config.promotion_consumer_account_ids : "arn:aws:iam::${id}:root"]

  # Third-party images copied in by the k8s mirror job, so clusters never pull from Docker Hub.
  mirror_repositories = try(tolist(local.ecr.mirror_repositories), [])
  app_repositories    = [for a in module.config.applications : a.repository]

  mirror_errors = concat(
    [for r in local.mirror_repositories : "infra-base/terraform/environments/${var.environment}/core.yaml: ecr.mirror_repositories entry ${r} is also an application image.repository" if contains(local.app_repositories, r)],
    [for r in local.mirror_repositories : "infra-base/terraform/environments/${var.environment}/core.yaml: ecr.mirror_repositories entry ${r} is not a valid repository name" if !can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", r))],
    length(distinct(local.mirror_repositories)) == length(local.mirror_repositories) ? [] : ["infra-base/terraform/environments/${var.environment}/core.yaml: ecr.mirror_repositories has duplicates"],
  )
}

resource "terraform_data" "validation" {
  input = var.environment

  lifecycle {
    precondition {
      condition     = length(module.config.errors) == 0 && length(local.mirror_errors) == 0
      error_message = "Invalid configuration:\n${join("\n", concat(module.config.errors, local.mirror_errors))}"
    }
  }
}

module "ecr" {
  source = "../../modules/ecr"

  name            = module.config.name
  use_name_prefix = false

  repositories = merge(
    {
      for app, a in module.config.applications : a.repository => {
        image_tag_mutability = try(local.ecr.image_tag_mutability, "IMMUTABLE")
        force_delete         = try(local.ecr.force_delete, false)
        pull_principal_arns  = local.pull_principal_arns
        tags                 = { Application = app }
      }
    },
    {
      for r in local.mirror_repositories : r => {
        image_tag_mutability = "IMMUTABLE"
        force_delete         = try(local.ecr.force_delete, false)
        tags                 = { Mirror = "true" }
      } if !contains(local.app_repositories, r)
    },
  )

  tags = local.tags
}
