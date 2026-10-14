module "s3_bucket" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-s3-bucket.git?ref=v4.2.1"

  bucket        = var.name
  force_destroy = var.force_destroy

  control_object_ownership = true
  object_ownership         = local.object_ownership

  # Upstream creates the public access block only when this is true.
  attach_public_policy    = true
  block_public_acls       = local.public_access_block.block_public_acls
  block_public_policy     = local.public_access_block.block_public_policy
  ignore_public_acls      = local.public_access_block.ignore_public_acls
  restrict_public_buckets = local.public_access_block.restrict_public_buckets

  attach_deny_insecure_transport_policy = local.tls_policies.deny_insecure_transport
  attach_require_latest_tls_policy      = local.tls_policies.require_latest_tls
  attach_policy                         = var.policy != null
  policy                                = var.policy

  versioning = {
    enabled = var.versioning_enabled
  }

  server_side_encryption_configuration = {
    rule = {
      bucket_key_enabled = local.encryption.bucket_key_enabled
      apply_server_side_encryption_by_default = {
        sse_algorithm     = local.encryption.sse_algorithm
        kms_master_key_id = local.encryption.kms_master_key_id
      }
    }
  }

  lifecycle_rule = local.lifecycle_rules
  cors_rule      = var.cors_rules

  logging = var.access_logging != null ? {
    target_bucket = var.access_logging.target_bucket
    target_prefix = var.access_logging.target_prefix
  } : {}

  object_lock_enabled = var.object_lock != null
  object_lock_configuration = var.object_lock != null ? {
    rule = {
      default_retention = {
        mode = var.object_lock.mode
        days = var.object_lock.days
      }
    }
  } : {}

  tags = var.tags
}
