mock_provider "aws" {
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
  name_prefix = "platform-dev"
  topics = {
    alerts = {
      subscriptions = {
        queue = { protocol = "sqs", endpoint = "arn:aws:sqs:ap-southeast-1:123456789012:platform-dev-orders" }
      }
    }
    audit = {
      fifo        = true
      kms_key_arn = "arn:aws:kms:ap-southeast-1:123456789012:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "names_and_encryption" {
  command = plan

  assert {
    condition     = local.topics["alerts"].name == "platform-dev-alerts" && local.topics["audit"].name == "platform-dev-audit.fifo"
    error_message = "Topic names must be <name_prefix>-<key>, with .fifo for FIFO topics."
  }

  assert {
    condition     = local.topics["alerts"].kms_key == "alias/aws/sns"
    error_message = "A topic without a KMS key must still be encrypted with the AWS-managed key."
  }

  assert {
    condition     = startswith(local.topics["audit"].kms_key, "arn:aws:kms:")
    error_message = "A topic with a KMS key must use it."
  }
}

run "rejects_plain_http_subscription" {
  command = plan

  variables {
    topics = {
      bad = { subscriptions = { hook = { protocol = "http", endpoint = "http://example.com/hook" } } }
    }
  }

  expect_failures = [var.topics]
}
