mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:sts::111122223333:assumed-role/ci/s" }
  }
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  # Upstream attaches the X-Ray managed policy by looking it up; a generated mock value is not
  # JSON and the provider rejects it before the plan is built.
  mock_data "aws_iam_policy" {
    defaults = {
      arn    = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
      policy = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name = "platform-dev"
  functions = {
    resizer = { handler = "index.handler", runtime = "python3.12", filename = "build/resizer.zip" }
  }
}

# The functions are built by an upstream module, which a contract test cannot see inside. What this
# module owns is the input contract and local.vpc_attached, the value that decides whether a
# function gets an ENI and loses its default internet access.

# Exactly one of source_path (build here) or filename (prebuilt zip). Both set means the module
# would silently prefer one; neither means an empty package.
run "rejects_a_function_that_sets_both_package_sources" {
  command = plan
  variables {
    functions = {
      resizer = {
        handler     = "index.handler"
        runtime     = "python3.12"
        source_path = "src/resizer"
        filename    = "build/resizer.zip"
      }
    }
  }
  expect_failures = [var.functions]
}

run "rejects_a_function_with_no_package_source" {
  command = plan
  variables {
    functions = {
      resizer = { handler = "index.handler", runtime = "python3.12" }
    }
  }
  expect_failures = [var.functions]
}

# 900 seconds is the Lambda maximum; past it the apply fails, which is the slowest place to learn.
run "rejects_a_timeout_over_the_lambda_maximum" {
  command = plan
  variables {
    functions = {
      resizer = {
        handler  = "index.handler"
        runtime  = "python3.12"
        filename = "build/resizer.zip"
        timeout  = 901
      }
    }
  }
  expect_failures = [var.functions]
}

run "rejects_a_zero_timeout" {
  command = plan
  variables {
    functions = {
      resizer = {
        handler  = "index.handler"
        runtime  = "python3.12"
        filename = "build/resizer.zip"
        timeout  = 0
      }
    }
  }
  expect_failures = [var.functions]
}

# VPC attachment is off by default and decided per function. Attaching costs a cold-start ENI and
# removes the function's default internet access, so it must never be the accidental state.
run "vpc_attachment_is_off_by_default" {
  command = plan

  assert {
    condition     = !local.vpc_attached["resizer"]
    error_message = "a function must not be attached to the VPC unless it asks"
  }
}

run "vpc_attachment_is_decided_per_function" {
  command = plan
  variables {
    subnet_ids         = ["subnet-0aaa", "subnet-0bbb"]
    security_group_ids = ["sg-0123456789abcdef0"]
    functions = {
      resizer  = { handler = "index.handler", runtime = "python3.12", filename = "build/resizer.zip" }
      reporter = { handler = "index.handler", runtime = "python3.12", filename = "build/reporter.zip", vpc_attached = true }
    }
  }

  assert {
    condition     = !local.vpc_attached["resizer"] && local.vpc_attached["reporter"]
    error_message = "two functions in one call must be able to differ on VPC attachment"
  }
}
