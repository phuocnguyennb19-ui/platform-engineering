resource "aws_security_group" "alb" {
  count = var.create_alb_sg ? 1 : 0

  name        = "${var.name}-alb"
  description = "Application Load Balancer — the only tier reachable from outside the VPC"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-alb", Tier = "edge" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "eks_cluster" {
  count = var.create_eks_sg ? 1 : 0

  name        = "${var.name}-eks-cluster"
  description = "EKS control plane ENIs"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-eks-cluster", Tier = "control-plane" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "eks_node" {
  count = var.create_eks_sg ? 1 : 0

  name        = "${var.name}-eks-node"
  description = "EKS managed node group instances"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-eks-node", Tier = "compute" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "ec2" {
  count = var.create_ec2_sg ? 1 : 0

  name        = "${var.name}-ec2"
  description = "EC2 application instances in the private tier"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-ec2", Tier = "compute" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "ecs" {
  count = var.create_ecs_sg ? 1 : 0

  name        = "${var.name}-ecs"
  description = "ECS Fargate task ENIs in the private tier"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-ecs", Tier = "compute" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "rds" {
  count = var.create_rds_sg ? 1 : 0

  name        = "${var.name}-rds"
  description = "RDS instances — reachable only from the application tier"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-rds", Tier = "data" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "elasticache" {
  count = var.create_elasticache_sg ? 1 : 0

  name        = "${var.name}-elasticache"
  description = "ElastiCache nodes — reachable only from the application tier"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-elasticache", Tier = "data" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "lambda" {
  count = var.create_lambda_sg ? 1 : 0

  name        = "${var.name}-lambda"
  description = "VPC-attached Lambda function ENIs"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-lambda", Tier = "compute" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "bastion" {
  count = var.create_bastion_sg ? 1 : 0

  name        = "${var.name}-bastion"
  description = "Bastion host — SSH from named administrative ranges only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-bastion", Tier = "edge" })

  lifecycle {
    create_before_destroy = true
  }
}
