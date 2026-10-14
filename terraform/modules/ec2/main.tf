data "aws_ami" "al2023" {
  count = length([for k, i in var.instances : k if i.ami_id == null]) > 0 ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  default_ami_id = try(data.aws_ami.al2023[0].id, null)
}

module "instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "5.8.0"

  for_each = var.instances

  name = "${var.name}-${each.key}"

  ami           = coalesce(each.value.ami_id, local.default_ami_id)
  instance_type = each.value.instance_type

  subnet_id                   = each.value.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = each.value.associate_public_ip_address
  availability_zone           = each.value.availability_zone

  create_iam_instance_profile = false
  iam_instance_profile        = var.iam_instance_profile

  key_name = each.value.key_name

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # Each volume is tagged on its own block below; the provider rejects volume_tags together with
  # root_block_device[*].tags, and upstream sets volume_tags unless this is off.
  enable_volume_tags = false

  root_block_device = [{
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    volume_size           = each.value.root_volume_size
    volume_type           = each.value.root_volume_type
    iops                  = each.value.root_volume_iops
    delete_on_termination = true
    tags                  = merge(var.tags, { Name = "${var.name}-${each.key}-root" })
  }]

  ebs_block_device = [
    for vk, v in each.value.additional_ebs_volumes : {
      device_name           = v.device_name
      volume_size           = v.size
      volume_type           = v.type
      iops                  = v.iops
      throughput            = v.throughput
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
      tags                  = merge(var.tags, { Name = "${var.name}-${each.key}-${vk}" })
    }
  ]

  monitoring                           = each.value.monitoring
  ebs_optimized                        = each.value.ebs_optimized
  disable_api_termination              = coalesce(each.value.disable_api_termination, var.enable_termination_protection_default)
  instance_initiated_shutdown_behavior = each.value.instance_initiated_shutdown_behavior

  user_data                   = each.value.user_data
  user_data_replace_on_change = each.value.user_data_replace_on_change

  tags = merge(var.tags, each.value.tags)
}
