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
  name               = "platform-dev-api"
  cluster_arn        = "arn:aws:ecs:ap-southeast-1:123456789012:cluster/platform-dev-ecs"
  subnet_ids         = ["subnet-00000001", "subnet-00000002"]
  security_group_ids = ["sg-00000001"]
  containers = {
    app = {
      image         = "123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/api:1.0.0"
      port_mappings = [{ containerPort = 8080, name = "http" }]
    }
  }
}

run "worker_has_no_load_balancer_or_mesh" {
  command = plan

  assert {
    condition     = !local.load_balancer_enabled && length(local.load_balancer) == 0
    error_message = "A service without a target group must not be wired to a load balancer."
  }

  assert {
    condition     = length(local.service_connect_configuration) == 0
    error_message = "Service Connect must stay off unless service_connect is set."
  }
}

run "explicit_load_balancer_with_unknown_arn" {
  command = plan

  variables {
    enable_load_balancer         = true
    target_group_arn             = "arn:aws:elasticloadbalancing:ap-southeast-1:123456789012:targetgroup/api/0000000000000000"
    load_balancer_container_name = "app"
    load_balancer_container_port = 8080
  }

  assert {
    condition     = local.load_balancer_enabled && local.load_balancer.default.container_port == 8080
    error_message = "enable_load_balancer must register the container port in the target group."
  }
}

run "service_connect_client_server" {
  command = plan

  variables {
    service_connect = {
      namespace = "arn:aws:servicediscovery:ap-southeast-1:123456789012:namespace/ns-0000000000000000"
      port_name = "http"
      dns_name  = "api"
      port      = 8080
    }
  }

  assert {
    condition     = local.service_connect_configuration.service.client_alias.dns_name == "api" && local.service_connect_configuration.service.port_name == "http"
    error_message = "service_connect must publish the service as <dns_name>:<port> on the named port mapping."
  }
}

run "rejects_service_connect_on_unknown_port_name" {
  command = plan

  variables {
    service_connect = {
      namespace = "arn:aws:servicediscovery:ap-southeast-1:123456789012:namespace/ns-0000000000000000"
      port_name = "grpc"
      dns_name  = "api"
      port      = 8080
    }
  }

  expect_failures = [terraform_data.service_connect_wiring]
}

run "rejects_admin_task_role" {
  command = plan

  variables {
    tasks_iam_role_statements = [{ actions = ["*"], resources = ["*"] }]
  }

  expect_failures = [var.tasks_iam_role_statements]
}

run "rejects_service_wildcard_on_all_resources" {
  command = plan

  variables {
    tasks_iam_role_statements = [{ actions = ["s3:*"], resources = ["*"] }]
  }

  expect_failures = [var.tasks_iam_role_statements]
}

run "allows_scoped_statement" {
  command = plan

  variables {
    tasks_iam_role_statements = [{ actions = ["s3:GetObject"], resources = ["arn:aws:s3:::platform-dev-artifacts/*"] }]
  }
}
