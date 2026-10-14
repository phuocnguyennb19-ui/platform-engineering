variable "cluster_name" {
  description = "EKS cluster name."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-_]{0,99}$", var.cluster_name))
    error_message = "cluster_name must start alphanumeric and contain only alphanumerics, hyphens and underscores, up to 100 characters."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. \"1.31\". EKS supports a narrow window of versions; a cluster left behind the window is force-upgraded by AWS on their schedule rather than yours."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as \"1.31\", not a patch version."
  }
}

variable "vpc_id" {
  description = "VPC the cluster runs in. From the foundation: module.vpc.vpc_id. This module never creates a VPC."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the node groups and the cluster ENIs. Private subnets: module.vpc.private_subnet_ids. Nodes in public subnets get public IPs and are directly reachable, which is not a cluster you want."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "control_plane_subnet_ids" {
  description = "Subnets for the control plane ENIs. Null uses subnet_ids. Set this to the intra/private subnets when the node subnets should stay separate."
  type        = list(string)
  default     = null
}

variable "cluster_endpoint_private_access" {
  description = "Reach the API server from inside the VPC."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Reach the API server from the internet. Convenient in dev; in production pair a private endpoint with a bastion, a VPN or a CI runner inside the VPC."
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Source CIDRs allowed to reach the public API endpoint. Meaningless unless cluster_endpoint_public_access is true."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.cluster_endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "cluster_endpoint_public_access_cidrs must not contain 0.0.0.0/0. A Kubernetes API server open to the whole internet is one credential leak away from cluster-admin."
  }
}

variable "node_groups" {
  description = <<-EOT
    EKS managed node groups, keyed by a short name.

    min_size / max_size / desired_size are per group. desired_size is set once at
    creation and then ignored on subsequent applies — the Cluster Autoscaler or
    Karpenter owns it after that, and Terraform fighting the autoscaler over
    replica count is a classic source of surprise scale-downs.

    capacity_type "SPOT" is legitimate for stateless and batch workloads; a
    SPOT-only cluster with no ON_DEMAND group has no capacity floor when the spot
    pool is exhausted.
  EOT
  type = map(object({
    instance_types = optional(list(string), ["t3.large"])
    capacity_type  = optional(string, "ON_DEMAND")
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")

    min_size     = optional(number, 2)
    max_size     = optional(number, 6)
    desired_size = optional(number, 2)

    disk_size = optional(number, 50)
    disk_type = optional(string, "gp3")

    labels = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string
    })), {})

    subnet_ids           = optional(list(string))
    max_unavailable      = optional(number, 1)
    force_update_version = optional(bool, false)

    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for k, g in var.node_groups : contains(["ON_DEMAND", "SPOT"], g.capacity_type)])
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }

  validation {
    condition     = alltrue([for k, g in var.node_groups : g.min_size <= g.desired_size && g.desired_size <= g.max_size])
    error_message = "Each node group needs min_size <= desired_size <= max_size."
  }
}

variable "node_security_group_ids" {
  description = "Additional security groups attached to the nodes, from module.security_groups.eks_node_sg_id. The EKS module also creates its own node group with the rules the control plane requires; these are added alongside it."
  type        = list(string)
  default     = []
}

variable "cluster_security_group_ids" {
  description = "Additional security groups attached to the control plane ENIs, from module.security_groups.eks_cluster_sg_id."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key encrypting Kubernetes secrets in etcd. Null makes the EKS module create its own key. Secrets are stored base64-encoded, not encrypted, without this."
  type        = string
  default     = null
}

variable "create_kms_key" {
  description = "Whether the EKS module creates its own Secrets encryption key. Set it explicitly — false alongside kms_key_arn — whenever that ARN is built in the same configuration: it is unknown at plan, and inferring this from it fails the plan. Null infers it from kms_key_arn == null."
  type        = bool
  default     = null
}

variable "cluster_enabled_log_types" {
  description = "Control plane logs published to CloudWatch. \"audit\" is the one that answers \"who did this to the cluster\" — dropping it to save money removes the only record."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  validation {
    condition = alltrue([
      for t in var.cluster_enabled_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)
    ])
    error_message = "Log types must be from api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "cluster_log_retention_days" {
  description = "Retention for the control plane log group."
  type        = number
  default     = 90
}

variable "cluster_log_kms_key_arn" {
  description = "KMS key for the control plane log group."
  type        = string
  default     = null
}

variable "cluster_addons" {
  description = <<-EOT
    EKS managed addons. The four below are the ones a cluster is not functional
    without: the VPC CNI provides pod networking, CoreDNS provides in-cluster
    DNS, kube-proxy provides Service routing, and the EBS CSI driver is what
    makes a PersistentVolumeClaim bind at all on a modern cluster.

    Leaving the version as null tracks the default addon version for the
    cluster's Kubernetes version, which is what you want unless you are pinning
    for a specific reason.

    irsa_role_key names an entry of irsa_roles whose ARN becomes the addon's
    service_account_role_arn. The role trusts this cluster's OIDC provider, so a
    caller cannot build it before the module and pass the ARN in.
  EOT
  type = map(object({
    version                     = optional(string)
    most_recent                 = optional(bool, true)
    resolve_conflicts_on_create = optional(string, "OVERWRITE")
    resolve_conflicts_on_update = optional(string, "PRESERVE")
    service_account_role_arn    = optional(string)
    irsa_role_key               = optional(string)
    configuration_values        = optional(string)
    before_compute              = optional(bool, false)
  }))
  default = {
    coredns            = {}
    kube-proxy         = {}
    vpc-cni            = { before_compute = true }
    aws-ebs-csi-driver = {}
  }
}

variable "enable_irsa" {
  description = "Create the OIDC provider that lets a Kubernetes service account assume an IAM role. This is the only way to give a pod AWS permissions without giving them to the whole node."
  type        = bool
  default     = true
}

variable "irsa_roles" {
  description = <<-EOT
    IAM roles assumable by Kubernetes service accounts, keyed by a short name.

    These live here rather than in the iam module because their trust policy has
    to name this cluster's OIDC provider, which does not exist until the cluster
    does. namespace_service_accounts entries take the form "namespace:serviceaccount".
  EOT
  type = map(object({
    description                = string
    namespace_service_accounts = list(string)
    managed_policy_arns        = optional(list(string), [])
    inline_policy              = optional(string)
  }))
  default = {}
}

variable "authentication_mode" {
  description = "API, API_AND_CONFIG_MAP or CONFIG_MAP. API is the current mechanism — access entries are managed as AWS resources rather than by editing a ConfigMap, so a bad edit cannot lock everyone out."
  type        = string
  default     = "API_AND_CONFIG_MAP"

  validation {
    condition     = contains(["API", "API_AND_CONFIG_MAP", "CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode must be API, API_AND_CONFIG_MAP or CONFIG_MAP."
  }
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Give the identity that ran the apply cluster-admin. Convenient, but it ties admin access to whichever CI role created the cluster — name the admins in access_entries instead for anything long-lived."
  type        = bool
  default     = true
}

variable "access_entries" {
  description = "EKS access entries mapping IAM principals to Kubernetes access policies."
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string))
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        type       = string
        namespaces = optional(list(string))
      })
    })), {})
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to the cluster and every resource it owns."
  type        = map(string)
  default     = {}
}
