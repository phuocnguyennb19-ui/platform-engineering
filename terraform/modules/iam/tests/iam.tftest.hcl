mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:sts::111122223333:assumed-role/ci/s" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name                     = "platform-dev"
  permissions_boundary_arn = "arn:aws:iam::111122223333:policy/platform-boundary"
}

# The boundary is the ceiling on everything this module hands out. A role created without it can
# be widened later by anyone who can edit its policies, so every role must carry it.
run "permissions_boundary_reaches_every_role" {
  command = plan

  variables {
    create_ec2_instance_role   = true
    create_rds_monitoring_role = true
    additional_roles = {
      deployer = {
        description        = "CI deployment role"
        assume_role_policy = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      }
    }
  }

  assert {
    condition     = aws_iam_role.ec2[0].permissions_boundary == var.permissions_boundary_arn
    error_message = "the EC2 instance role must carry the permissions boundary."
  }

  assert {
    condition     = aws_iam_role.rds_monitoring[0].permissions_boundary == var.permissions_boundary_arn
    error_message = "the RDS monitoring role must carry the permissions boundary."
  }

  assert {
    condition     = aws_iam_role.additional["deployer"].permissions_boundary == var.permissions_boundary_arn
    error_message = "an additional role must carry the permissions boundary."
  }

  assert {
    condition     = aws_iam_role.additional["deployer"].name == "platform-dev-deployer"
    error_message = "additional roles must be prefixed with the module name."
  }
}

# Managed policies are opt-in per capability, so a host that needs SSM does not also get the
# CloudWatch agent's permissions.
run "managed_policies_are_opt_in" {
  command = plan

  variables {
    create_ec2_instance_role    = true
    ec2_enable_ssm              = true
    ec2_enable_cloudwatch_agent = false
  }

  assert {
    condition     = contains(local.ec2_managed_policies, "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore")
    error_message = "ec2_enable_ssm must attach AmazonSSMManagedInstanceCore."
  }

  assert {
    condition     = !contains(local.ec2_managed_policies, "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy")
    error_message = "the CloudWatch agent policy must not be attached unless it is asked for."
  }
}

run "no_capability_means_no_managed_policy" {
  command = plan

  variables {
    create_ec2_instance_role    = true
    ec2_enable_ssm              = false
    ec2_enable_cloudwatch_agent = false
  }

  assert {
    condition     = length(local.ec2_managed_policies) == 0
    error_message = "with every capability off the instance role must hold no managed policy."
  }
}

# Every role is opt-out, so a caller that needs only one of them does not silently get the rest.
run "every_role_can_be_turned_off" {
  command = plan

  variables {
    create_ec2_instance_role   = false
    create_rds_monitoring_role = false
  }

  assert {
    condition     = length(aws_iam_role.ec2) == 0 && length(aws_iam_role.rds_monitoring) == 0 && length(aws_iam_role.additional) == 0
    error_message = "the module must create no role when nothing is asked for."
  }
}
