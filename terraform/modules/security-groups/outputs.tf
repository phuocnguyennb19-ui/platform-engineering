output "alb_sg_id" {
  description = "ALB security group ID. Consumed by the alb module."
  value       = one(aws_security_group.alb[*].id)
}

output "eks_cluster_sg_id" {
  description = "EKS control plane security group ID. Consumed by the eks module as an additional cluster security group."
  value       = one(aws_security_group.eks_cluster[*].id)
}

output "eks_node_sg_id" {
  description = "EKS node security group ID. Consumed by the eks module as an additional node security group."
  value       = one(aws_security_group.eks_node[*].id)
}

output "ec2_sg_id" {
  description = "EC2 application security group ID. Consumed by the ec2 module."
  value       = one(aws_security_group.ec2[*].id)
}

output "ecs_sg_id" {
  description = "ECS task security group ID. Consumed by the ecs-service module as security_group_ids."
  value       = one(aws_security_group.ecs[*].id)
}

output "rds_sg_id" {
  description = "RDS security group ID. Consumed by the rds module."
  value       = one(aws_security_group.rds[*].id)
}

output "elasticache_sg_id" {
  description = "ElastiCache security group ID. Consumed by the elasticache module."
  value       = one(aws_security_group.elasticache[*].id)
}

output "lambda_sg_id" {
  description = "Lambda security group ID. Consumed by the lambda module for VPC-attached functions."
  value       = one(aws_security_group.lambda[*].id)
}

output "bastion_sg_id" {
  description = "Bastion security group ID."
  value       = one(aws_security_group.bastion[*].id)
}

output "security_group_ids" {
  description = "All security group IDs by logical name. Null for any group not created in this environment."
  value       = local.ids
}
