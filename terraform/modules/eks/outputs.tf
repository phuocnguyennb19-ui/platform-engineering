output "cluster_name" {
  description = "Cluster name."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "Cluster ARN."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version actually running, which may be ahead of the requested minor after an AWS-initiated patch."
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA certificate for the API server. Needed to build a kubeconfig. Not a secret — it is a public certificate — but it is bulky, so it is not printed by default."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group EKS created for the control plane."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group EKS created for the nodes. Add rules here for anything that must reach the nodes and is not already covered by the platform's own node security group."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN. Required to write an IRSA trust policy outside this module."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL without the https:// scheme, as it appears in a trust policy condition key."
  value       = module.eks.oidc_provider
}

output "node_group_arns" {
  description = "Map of node group key to ARN."
  value       = { for k, v in module.eks.eks_managed_node_groups : k => v.node_group_arn }
}

output "node_group_iam_role_arns" {
  description = "Map of node group key to the instance role ARN its nodes run as."
  value       = { for k, v in module.eks.eks_managed_node_groups : k => v.iam_role_arn }
}

output "irsa_role_arns" {
  description = "Map of IRSA role key to ARN. Annotate the Kubernetes ServiceAccount with eks.amazonaws.com/role-arn set to one of these."
  value       = { for k, v in aws_iam_role.irsa : k => v.arn }
}

output "kubeconfig_command" {
  description = "The aws CLI command that writes a kubeconfig entry for this cluster."
  value       = "aws eks update-kubeconfig --region ${data.aws_region.current.name} --name ${module.eks.cluster_name}"
}
