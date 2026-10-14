provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.assume_role_arn != null ? [1] : []

    content {
      role_arn     = var.assume_role_arn
      session_name = "terraform-${var.project}-${var.environment}"
    }
  }

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      CostCenter  = var.cost_center
      ManagedBy   = "terraform"
    }
  }
}
