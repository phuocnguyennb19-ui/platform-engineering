mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name_prefix = "platform-dev"
  queues = {
    orders = {
      dead_letter = {}
    }
    events = {
      fifo                        = true
      content_based_deduplication = true
      kms_key_arn                 = "arn:aws:kms:ap-southeast-1:123456789012:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "names_and_encryption" {
  command = plan

  assert {
    condition     = local.queues["orders"].name == "platform-dev-orders" && local.queues["events"].name == "platform-dev-events.fifo"
    error_message = "Queue names must be <name_prefix>-<key>, with .fifo for FIFO queues."
  }

  assert {
    condition     = local.queues["orders"].sqs_managed_sse && !local.queues["events"].sqs_managed_sse
    error_message = "A queue without a KMS key must use SQS-managed SSE; one with a key must not."
  }

  assert {
    condition     = local.queues["orders"].create_dlq && local.queues["orders"].dead_letter.max_receive_count == 5
    error_message = "dead_letter must create a DLQ with a max receive count of 5 by default."
  }

  assert {
    condition     = !local.queues["events"].create_dlq
    error_message = "No DLQ unless dead_letter is set."
  }

  assert {
    condition     = local.queues["orders"].receive_wait_time_seconds == 20
    error_message = "Long polling must be the default."
  }
}

run "rejects_dedup_on_standard_queue" {
  command = plan

  variables {
    queues = { bad = { content_based_deduplication = true } }
  }

  expect_failures = [var.queues]
}

run "rejects_out_of_range_retention" {
  command = plan

  variables {
    queues = { bad = { message_retention_seconds = 30 } }
  }

  expect_failures = [var.queues]
}
