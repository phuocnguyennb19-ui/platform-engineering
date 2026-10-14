mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "random" {}

variables {
  name_prefix = "platform-dev"
  secrets = {
    stripe-key = {}
    db-app = {
      generate_password   = true
      rotation_lambda_arn = "arn:aws:lambda:ap-southeast-1:123456789012:function:rotate"
    }
  }
}

run "value_stays_out_of_terraform" {
  command = plan

  assert {
    condition     = local.secrets["stripe-key"].name == "platform-dev/stripe-key"
    error_message = "Secret names must be <name_prefix>/<key>."
  }

  assert {
    condition     = local.secrets["stripe-key"].initial_value == "{}"
    error_message = "Without generate_password the module must write only an empty placeholder."
  }

  assert {
    condition     = local.secrets["db-app"].initial_value == null
    error_message = "A generated secret must not also carry a placeholder."
  }

  assert {
    condition     = local.secrets["stripe-key"].recovery_window_in_days == 30
    error_message = "Deletion must be recoverable for 30 days by default."
  }

  assert {
    condition     = local.secrets["db-app"].enable_rotation && !local.secrets["stripe-key"].enable_rotation
    error_message = "Rotation follows rotation_lambda_arn."
  }
}

run "rejects_short_recovery_window" {
  command = plan

  variables {
    secrets = { bad = { recovery_window_in_days = 3 } }
  }

  expect_failures = [var.secrets]
}
