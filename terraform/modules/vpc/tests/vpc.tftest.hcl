mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-1" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"], zone_ids = ["apse1-az1", "apse1-az2", "apse1-az3"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:sts::111122223333:assumed-role/ci/s" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name       = "platform-dev"
  cidr_block = "10.10.0.0/16"
  az_count   = 3
}

# The three tiers are carved out of one /16 by position, so a caller that passes only a CIDR
# always gets the same layout and the tiers can never overlap.
run "derives_three_non_overlapping_tiers" {
  command = plan

  assert {
    condition     = local.private_subnet_cidrs == tolist(["10.10.0.0/20", "10.10.16.0/20", "10.10.32.0/20"])
    error_message = "private subnets must be /20s from the start of the block."
  }

  assert {
    condition     = local.public_subnet_cidrs == tolist(["10.10.240.0/24", "10.10.241.0/24", "10.10.242.0/24"])
    error_message = "public subnets must be /24s at offset 240."
  }

  assert {
    condition     = local.database_subnet_cidrs == tolist(["10.10.250.0/24", "10.10.251.0/24", "10.10.252.0/24"])
    error_message = "database subnets must be /24s at offset 250."
  }

  assert {
    condition = length(setintersection(
      toset(local.private_subnet_cidrs),
      toset(concat(local.public_subnet_cidrs, local.database_subnet_cidrs)),
    )) == 0
    error_message = "the tiers must not share a CIDR."
  }

  assert {
    condition     = local.az_count == 3 && length(local.azs) == 3
    error_message = "az_count must decide how many AZs are used when azs is not pinned."
  }
}

run "pinned_azs_win_over_az_count" {
  command = plan

  variables {
    azs = ["ap-southeast-1a", "ap-southeast-1b"]
  }

  assert {
    condition     = local.azs == tolist(["ap-southeast-1a", "ap-southeast-1b"]) && local.az_count == 2
    error_message = "an explicit azs list must decide both the AZs and the subnet count."
  }

  assert {
    condition     = length(local.private_subnet_cidrs) == 2
    error_message = "one subnet per AZ per tier."
  }
}

# EKS finds subnets by tag. Public and private carry the cluster tag and the ELB role; the
# database tier must not, or a load balancer can be placed in a subnet with no internet route.
run "eks_cluster_names_tag_only_the_routable_tiers" {
  command = plan

  variables {
    eks_cluster_names = ["platform-dev-eks"]
  }

  assert {
    condition     = local.public_tags["kubernetes.io/cluster/platform-dev-eks"] == "shared" && local.public_tags["kubernetes.io/role/elb"] == "1"
    error_message = "public subnets must carry the cluster tag and the public ELB role."
  }

  assert {
    condition     = local.private_tags["kubernetes.io/cluster/platform-dev-eks"] == "shared" && local.private_tags["kubernetes.io/role/internal-elb"] == "1"
    error_message = "private subnets must carry the cluster tag and the internal ELB role."
  }

  assert {
    condition     = !contains(keys(local.database_tags), "kubernetes.io/cluster/platform-dev-eks")
    error_message = "the database tier must never be a load balancer target."
  }
}

run "no_eks_means_no_kubernetes_tags" {
  command = plan

  assert {
    condition     = length([for k, v in merge(local.public_tags, local.private_tags) : k if startswith(k, "kubernetes.io/")]) == 0
    error_message = "an environment with no cluster must not carry Kubernetes subnet tags."
  }
}

run "rejects_a_block_too_small_to_subnet" {
  command = plan

  variables {
    cidr_block = "10.10.0.0/24"
  }

  expect_failures = [var.cidr_block]
}

run "rejects_a_single_az" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}
