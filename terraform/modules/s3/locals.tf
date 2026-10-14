locals {
  # ACLs off: the bucket owner owns every object and access is decided by policy alone.
  object_ownership = "BucketOwnerEnforced"

  public_access_block = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }

  tls_policies = {
    deny_insecure_transport = true
    require_latest_tls      = true
  }

  encryption = var.kms_key_arn != null ? {
    sse_algorithm      = "aws:kms"
    kms_master_key_id  = var.kms_key_arn
    bucket_key_enabled = true
    } : {
    sse_algorithm      = "AES256"
    kms_master_key_id  = null
    bucket_key_enabled = false
  }

  lifecycle_rules = [
    for r in var.lifecycle_rules : merge(
      {
        id                                     = r.id
        enabled                                = r.enabled
        abort_incomplete_multipart_upload_days = r.abort_incomplete_multipart_upload_days
      },
      r.prefix != null ? { filter = { prefix = r.prefix } } : {},
      r.expiration_days != null ? { expiration = { days = r.expiration_days } } : {},
      r.noncurrent_version_expiration_days != null ? { noncurrent_version_expiration = { days = r.noncurrent_version_expiration_days } } : {},
      length(r.transitions) > 0 ? { transition = r.transitions } : {},
    )
  ]
}
