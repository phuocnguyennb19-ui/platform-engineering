provider "aws" {
  region              = module.config.region
  allowed_account_ids = [module.config.account_id]

  default_tags {
    tags = local.tags
  }
}
