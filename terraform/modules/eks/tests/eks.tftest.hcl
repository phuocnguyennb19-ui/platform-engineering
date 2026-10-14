mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:sts::123456789012:assumed-role/ci/session" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:role/ci" }
  }
}

mock_provider "tls" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "cloudinit" {}

variables {
  cluster_name       = "platform-dev-eks"
  kubernetes_version = "1.31"
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_ids         = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
}

run "addons_pass_through_without_irsa_role_key" {
  command = plan

  assert {
    condition     = local.cluster_addons["coredns"].service_account_role_arn == null && local.cluster_addons["vpc-cni"].before_compute
    error_message = "An addon without irsa_role_key must reach the EKS module unchanged."
  }

  assert {
    condition     = local.cluster_addons["coredns"].addon_version == null
    error_message = "An unpinned addon must keep tracking the default version for the cluster."
  }
}

run "addon_version_reaches_the_upstream_input_name" {
  command = plan

  variables {
    cluster_addons = {
      coredns = { version = "v1.11.3-eksbuild.1" }
    }
  }

  assert {
    condition     = local.cluster_addons["coredns"].addon_version == "v1.11.3-eksbuild.1"
    error_message = "A pinned version must be passed as addon_version; the upstream module never reads `version`."
  }
}

run "addon_takes_the_named_irsa_role" {
  command = plan

  variables {
    irsa_roles = {
      cloudwatch = {
        description                = "CloudWatch agent"
        namespace_service_accounts = ["amazon-cloudwatch:cloudwatch-agent"]
        managed_policy_arns        = ["arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"]
      }
    }
    cluster_addons = {
      amazon-cloudwatch-observability = { irsa_role_key = "cloudwatch" }
    }
  }

  assert {
    condition     = keys(aws_iam_role.irsa) == ["cloudwatch"] && local.cluster_addons["amazon-cloudwatch-observability"].irsa_role_key == "cloudwatch"
    error_message = "irsa_role_key must name an IRSA role the module creates; the plan resolving it proves the reference has no cycle."
  }
}
