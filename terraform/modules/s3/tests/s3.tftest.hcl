mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name = "contract-test-bucket"
}

run "secure_defaults" {
  command = plan

  assert {
    condition     = local.object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled (BucketOwnerEnforced)."
  }

  assert {
    condition     = alltrue(values(local.public_access_block))
    error_message = "Every public access block setting must be on."
  }

  assert {
    condition     = alltrue(values(local.tls_policies))
    error_message = "The bucket policy must deny non-TLS and pre-1.2 TLS access."
  }

  assert {
    condition     = local.encryption.sse_algorithm == "AES256"
    error_message = "Without a KMS key the bucket must still be encrypted with SSE-S3."
  }

  assert {
    condition     = var.versioning_enabled && !var.force_destroy
    error_message = "Versioning must default to on and force_destroy to off."
  }
}

run "kms_encryption" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:ap-southeast-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = local.encryption.sse_algorithm == "aws:kms" && local.encryption.bucket_key_enabled
    error_message = "A KMS key must switch encryption to SSE-KMS with a bucket key."
  }
}

run "lifecycle_mapping" {
  command = plan

  variables {
    lifecycle_rules = [{
      id                                 = "logs"
      prefix                             = "logs/"
      expiration_days                    = 30
      noncurrent_version_expiration_days = 7
      transitions                        = [{ days = 7, storage_class = "STANDARD_IA" }]
    }]
  }

  assert {
    condition     = local.lifecycle_rules[0].expiration.days == 30 && local.lifecycle_rules[0].filter.prefix == "logs/"
    error_message = "expiration_days and prefix must map onto the upstream rule."
  }

  assert {
    condition     = local.lifecycle_rules[0].abort_incomplete_multipart_upload_days == 7
    error_message = "Incomplete multipart uploads must be aborted after 7 days by default."
  }
}

run "rejects_invalid_name" {
  command = plan

  variables {
    name = "Invalid_Bucket"
  }

  expect_failures = [var.name]
}

run "rejects_public_write_cors" {
  command = plan

  variables {
    cors_rules = [{ allowed_methods = ["PUT"], allowed_origins = ["*"] }]
  }

  expect_failures = [var.cors_rules]
}

run "rejects_bad_object_lock_mode" {
  command = plan

  variables {
    object_lock = { mode = "FOREVER", days = 1 }
  }

  expect_failures = [var.object_lock]
}
