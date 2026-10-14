# ecs-cluster

## Usage

```hcl
module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  cluster_name = local.name_prefix

  tags         = local.tags
}
```

Every input not listed above has a default — 13 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `cluster_name` | `string` | ECS cluster name, conventionally "<project>-<environment>-ecs". |

## Outputs

| Name | Description |
|---|---|
| `arn` | Cluster ARN. Consumed by the ecs-service module as cluster_arn. |
| `id` | Cluster ID. |
| `name` | Cluster name. This is the ClusterName dimension for CloudWatch metrics and the value `aws ecs` commands take as --cluster. |
| `capacity_providers` | Capacity providers attached to the cluster. |
| `log_group_name` | Log group receiving execute-command session transcripts. |
| `log_group_arn` | ARN of the execute-command log group. |
| `task_exec_iam_role_arn` | Cluster-wide task execution role ARN, or null when each service creates its own. |
| `task_exec_iam_role_name` | Cluster-wide task execution role name, or null when create_task_exec_iam_role is false. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
