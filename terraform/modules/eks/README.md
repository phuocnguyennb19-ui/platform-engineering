# eks

## Usage

```hcl
module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.name_prefix
  kubernetes_version = "1.31"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids

  tags               = local.tags
}
```

Every input not listed above has a default — 19 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `cluster_name` | `string` | EKS cluster name. |
| `kubernetes_version` | `string` | Kubernetes minor version, e.g. "1.31". EKS supports a narrow window of versions; a cluster left behind the window is force-upgraded by AWS on their schedule rather than yours. |
| `vpc_id` | `string` | VPC the cluster runs in. From the foundation: module.vpc.vpc_id. This module never creates a VPC. |
| `subnet_ids` | `list(string)` | Subnets for the node groups and the cluster ENIs. Private subnets: module.vpc.private_subnet_ids. Nodes in public subnets get public IPs and are directly reachable, which is not a cluster you want. |

## Outputs

| Name | Description |
|---|---|
| `cluster_name` | Cluster name. |
| `cluster_arn` | Cluster ARN. |
| `cluster_endpoint` | Kubernetes API server endpoint. |
| `cluster_version` | Kubernetes version actually running, which may be ahead of the requested minor after an AWS-initiated patch. |
| `cluster_certificate_authority_data` | Base64 CA certificate for the API server. Needed to build a kubeconfig. Not a secret — it is a public certificate — but it is bulky, so it is not printed by default. |
| `cluster_security_group_id` | Security group EKS created for the control plane. |
| `node_security_group_id` | Security group EKS created for the nodes. Add rules here for anything that must reach the nodes and is not already covered by the platform's own node security group. |
| `oidc_provider_arn` | IAM OIDC provider ARN. Required to write an IRSA trust policy outside this module. |
| `oidc_provider_url` | OIDC provider URL without the https:// scheme, as it appears in a trust policy condition key. |
| `node_group_arns` | Map of node group key to ARN. |
| `node_group_iam_role_arns` | Map of node group key to the instance role ARN its nodes run as. |
| `irsa_role_arns` | Map of IRSA role key to ARN. Annotate the Kubernetes ServiceAccount with eks.amazonaws.com/role-arn set to one of these. |
| `kubeconfig_command` | The aws CLI command that writes a kubeconfig entry for this cluster. |

## Notes

- Pin a tag in `source`, never a branch.
- An addon that needs AWS permissions names one of `irsa_roles` instead of an ARN — the role
  trusts this cluster's OIDC provider, so it cannot exist before the module runs:

  ```hcl
  irsa_roles = {
    cloudwatch = {
      description                = "CloudWatch agent and Fluent Bit"
      namespace_service_accounts = ["amazon-cloudwatch:cloudwatch-agent"]
      managed_policy_arns        = ["arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"]
    }
  }
  cluster_addons = {
    # ...the four defaults, which a non-empty map replaces...
    amazon-cloudwatch-observability = { irsa_role_key = "cloudwatch" }
  }
  ```
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
