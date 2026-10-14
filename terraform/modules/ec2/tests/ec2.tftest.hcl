mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0", architecture = "x86_64" }
  }
}

variables {
  name               = "platform-dev"
  security_group_ids = ["sg-0123456789abcdef0"]
  instances = {
    bastion = { subnet_id = "subnet-0aaa" }
  }
}

# Instances belong in private subnets, reached through Session Manager or the ALB. A public IP is
# refused here rather than discouraged, so the exception has to be made visibly outside the module.
run "rejects_a_public_ip" {
  command = plan
  variables {
    instances = {
      bastion = { subnet_id = "subnet-0aaa", associate_public_ip_address = true }
    }
  }
  expect_failures = [var.instances]
}

# Regression: upstream sets volume_tags unless enable_volume_tags is false, and the provider
# rejects volume_tags together with root_block_device[*].tags — which this module always writes.
# Every plan failed with "Conflicting configuration arguments" until the module turned it off.
# There is nothing to assert: the plan either builds or it does not, and for two provider versions
# it did not. The run block is the assertion.
run "volume_tags_do_not_conflict_with_per_device_tags" {
  command = plan
}

# The AMI lookup runs only when some instance leaves ami_id null. A data source that always runs
# would make every plan depend on what AWS published this week, including for pinned instances.
run "the_ami_lookup_runs_only_when_an_instance_needs_it" {
  command = plan

  assert {
    condition     = length(data.aws_ami.al2023) == 1
    error_message = "an instance without ami_id must resolve the current Amazon Linux 2023 image"
  }
}

run "no_ami_lookup_when_every_instance_pins_its_image" {
  command = plan
  variables {
    instances = {
      bastion = { subnet_id = "subnet-0aaa", ami_id = "ami-0aaaaaaaaaaaaaaaa" }
      worker  = { subnet_id = "subnet-0bbb", ami_id = "ami-0bbbbbbbbbbbbbbbb" }
    }
  }

  assert {
    condition     = length(data.aws_ami.al2023) == 0
    error_message = "nothing should be looked up when every instance pins an AMI"
  }

  assert {
    condition     = local.default_ami_id == null
    error_message = "with no lookup there is no default AMI, and coalesce must fall to the pinned one"
  }
}

# One pinned and one unpinned instance is the mixed case: the lookup still has to happen for the
# unpinned one.
run "a_single_unpinned_instance_still_triggers_the_lookup" {
  command = plan
  variables {
    instances = {
      pinned   = { subnet_id = "subnet-0aaa", ami_id = "ami-0aaaaaaaaaaaaaaaa" }
      unpinned = { subnet_id = "subnet-0bbb" }
    }
  }

  assert {
    condition     = length(data.aws_ami.al2023) == 1
    error_message = "one unpinned instance is enough to need the lookup"
  }
}
