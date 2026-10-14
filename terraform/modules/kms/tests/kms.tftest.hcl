mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:sts::111122223333:assumed-role/ci/s" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name = "platform-dev"
  keys = {
    rds  = { description = "RDS storage", service_principals = ["rds.amazonaws.com"] }
    logs = { description = "CloudWatch log groups" }
  }
}

# One key per purpose, and the alias is the handle every other module looks the ARN up by. The
# alias naming is a contract: renaming it silently repoints consumers.
run "one_key_and_one_alias_per_purpose" {
  command = plan

  assert {
    condition     = sort(keys(aws_kms_key.this)) == tolist(["logs", "rds"])
    error_message = "a key is created per entry in keys, not one shared key"
  }

  assert {
    condition     = aws_kms_alias.this["rds"].name == "alias/platform-dev-rds"
    error_message = "aliases are alias/<name>-<purpose>"
  }

  assert {
    condition     = aws_kms_key.this["rds"].tags["Purpose"] == "rds"
    error_message = "the purpose must be on the key, so an untagged key is findable"
  }
}

# Rotation is the one setting this module does not let a caller turn off, because a key that never
# rotates is the one that outlives every review.
run "rotation_is_on_with_a_bounded_period" {
  command = plan

  assert {
    condition     = aws_kms_key.this["rds"].enable_key_rotation
    error_message = "automatic rotation must default on"
  }

  assert {
    condition     = aws_kms_key.this["rds"].rotation_period_in_days == 365
    error_message = "rotation must carry a period, not leave it to the provider default"
  }
}

run "rejects_rotation_turned_off" {
  command = plan
  variables {
    keys = {
      rds = { description = "RDS storage", enable_rotation = false }
    }
  }
  expect_failures = [var.keys]
}

# A deletion window under 7 days is not recoverable in practice; over 30 AWS rejects at apply.
run "rejects_a_deletion_window_outside_the_allowed_range" {
  command = plan
  variables {
    keys = {
      rds = { description = "RDS storage", deletion_window_in_days = 3 }
    }
  }
  expect_failures = [var.keys]
}

run "deletion_window_defaults_to_the_maximum" {
  command = plan

  assert {
    condition     = aws_kms_key.this["logs"].deletion_window_in_days == 30
    error_message = "the default window is the longest one, so a mistaken destroy stays recoverable"
  }
}

# multi_region is opt-in: a multi-region key replicates key material across regions and cannot be
# converted back.
run "keys_are_single_region_unless_asked" {
  command = plan

  assert {
    condition     = !aws_kms_key.this["rds"].multi_region
    error_message = "multi_region must be opt-in"
  }
}
