# ECR moved to the registry layer: forget, never destroy, the repositories an earlier core state holds.
removed {
  from = module.ecr

  lifecycle {
    destroy = false
  }
}

moved {
  from = module.ecs_cluster
  to   = module.ecs_cluster[0]
}
