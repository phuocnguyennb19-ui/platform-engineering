mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name = "platform-dev"
  repositories = {
    api = {}
  }
}

# The defaults are the production-safe ones. A caller that names a repository and nothing else
# must not get a mutable tag: a deployed digest could then be swapped under a running workload.
run "defaults_are_the_safe_ones" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this["api"].image_tag_mutability == "IMMUTABLE"
    error_message = "tags must be immutable unless the caller asks otherwise"
  }

  assert {
    condition     = aws_ecr_repository.this["api"].image_scanning_configuration[0].scan_on_push
    error_message = "scan on push must be on by default"
  }

  assert {
    condition     = !aws_ecr_repository.this["api"].force_delete
    error_message = "force_delete must be off: a repository with images should not vanish on destroy"
  }
}

# Encryption follows kms_key_arn without the caller restating it.
run "encryption_falls_back_to_aes256_without_a_key" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this["api"].encryption_configuration[0].encryption_type == "AES256"
    error_message = "no key means the AWS-owned key, not an empty KMS configuration"
  }
}

run "a_kms_key_switches_the_encryption_type" {
  command = plan
  variables {
    kms_key_arn = "arn:aws:kms:ap-southeast-1:111122223333:key/abcd-1234"
  }

  assert {
    condition     = aws_ecr_repository.this["api"].encryption_configuration[0].encryption_type == "KMS"
    error_message = "a key must select KMS encryption"
  }

  assert {
    condition     = aws_ecr_repository.this["api"].encryption_configuration[0].kms_key == "arn:aws:kms:ap-southeast-1:111122223333:key/abcd-1234"
    error_message = "the key the caller passed must be the key used"
  }
}

# use_name_prefix is what decides whether an image is promoted through environments or rebuilt per
# environment. Both namings are part of the contract.
run "name_prefix_decides_the_repository_name" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this["api"].name == "platform-dev/api"
    error_message = "prefixed repositories are <name>/<key>"
  }
}

run "shared_repositories_are_named_by_key_alone" {
  command = plan
  variables {
    use_name_prefix = false
  }

  assert {
    condition     = aws_ecr_repository.this["api"].name == "api"
    error_message = "an image promoted through environments lives in one repository, named by key"
  }
}

# The lifecycle policy is generated, not passed in: these two rules are the contract.
run "lifecycle_policy_expires_untagged_and_caps_released_images" {
  command = plan
  variables {
    repositories = {
      api = { untagged_expiry_days = 3, keep_tagged_count = 20, tag_prefixes = ["v"] }
    }
  }

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.this["api"].policy).rules) == 2
    error_message = "the policy is exactly the untagged rule and the tagged rule"
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this["api"].policy).rules[0].selection.countNumber == 3
    error_message = "untagged_expiry_days must reach the untagged rule"
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this["api"].policy).rules[1].selection.countNumber == 20
    error_message = "keep_tagged_count must reach the tagged rule"
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this["api"].policy).rules[1].selection.tagPrefixList == ["v"]
    error_message = "tag_prefixes decides which tagged images the cap applies to"
  }
}

# A repository policy exists only where cross-account pull was asked for. An empty policy attached
# to every repository would be a standing grant nobody reads.
run "repository_policy_only_where_pull_principals_are_given" {
  command = plan
  variables {
    repositories = {
      api     = { pull_principal_arns = ["arn:aws:iam::999988887777:root"] }
      private = {}
    }
  }

  assert {
    condition     = keys(aws_ecr_repository_policy.this) == ["api"]
    error_message = "only the repository that names a pull principal gets a policy"
  }
}

run "rejects_an_unknown_tag_mutability" {
  command = plan
  variables {
    repositories = {
      api = { image_tag_mutability = "SOMETIMES" }
    }
  }
  expect_failures = [var.repositories]
}
