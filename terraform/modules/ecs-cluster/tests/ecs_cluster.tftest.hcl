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
  cluster_name = "platform-dev-ecs"
}

run "no_namespace_by_default" {
  command = plan

  assert {
    condition     = length(aws_service_discovery_http_namespace.this) == 0 && local.service_connect_namespace == null
    error_message = "No Cloud Map namespace unless one is named."
  }
}

run "creates_service_connect_namespace" {
  command = plan

  variables {
    service_connect_namespace_name = "platform-dev.internal"
  }

  assert {
    condition     = aws_service_discovery_http_namespace.this[0].name == "platform-dev.internal"
    error_message = "service_connect_namespace_name must create the namespace."
  }
}
