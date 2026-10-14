mock_provider "aws" {}

variables {
  name             = "platform-dev"
  vpc_id           = "vpc-00000000"
  vpc_cidr_block   = "10.10.0.0/16"
  create_alb_sg    = true
  create_ecs_sg    = true
  create_rds_sg    = true
  application_port = 8080
}

run "tier_chain_alb_ecs_rds" {
  command = plan

  assert {
    condition     = contains(keys(local.active_group_ingress), "ecs-from-alb") && contains(keys(local.active_group_ingress), "rds-from-ecs")
    error_message = "ALB → ECS → RDS must be wired by security group reference."
  }

  assert {
    condition     = !contains(keys(local.active_group_ingress), "ecs-from-ecs")
    error_message = "Task-to-task traffic must be closed unless allow_ecs_to_ecs is set."
  }

  assert {
    condition     = local.active_group_ingress["ecs-from-alb"].from == 8080 && local.active_group_ingress["ecs-from-alb"].to == 8080
    error_message = "ALB → ECS must open only the application port."
  }
}

run "service_connect_opens_task_to_task" {
  command = plan

  variables {
    allow_ecs_to_ecs = true
  }

  assert {
    condition     = local.active_group_ingress["ecs-from-ecs"].source == "ecs" && local.active_group_ingress["ecs-from-ecs"].from == 8080
    error_message = "allow_ecs_to_ecs must open the application port from the ECS group to itself."
  }
}

run "rejects_open_bastion" {
  command = plan

  variables {
    create_bastion_sg     = true
    bastion_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.bastion_allowed_cidrs]
}
