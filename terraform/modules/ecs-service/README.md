# ecs-service

## Usage

```hcl
module "ecs_service" {
  source = "../../modules/ecs-service"

  name               = local.name_prefix
  cluster_arn        = module.ecs_cluster.arn
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [module.security_groups.ecs_sg_id]
  containers         = {
    api = {
      image     = "111122223333.dkr.ecr.ap-southeast-1.amazonaws.com/api:v1.4.2"
      essential = true
      port_mappings = [{ containerPort = 8080, protocol = "tcp" }]
    }
  }

  tags               = local.tags
}
```

Every input not listed above has a default — 36 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Service name, conventionally "<project>-<environment>-<app>". Also the task definition family. |
| `cluster_arn` | `string` | ECS cluster the service runs in. From the foundation: module.ecs_cluster.arn. |
| `subnet_ids` | `list(string)` | Subnets the task ENIs are created in. Private subnets only — see assign_public_ip in main.tf for why there is no input to place them elsewhere. |
| `security_group_ids` | `list(string)` | Security groups attached to the task ENIs. From module.security_groups.ecs_sg_id. This module never creates its own: the tier-to-tier rules live in one place, and a service that mints a private group is a rule nobody will find during an incident. |
| `containers` | `map(object` |  |

## Outputs

| Name | Description |
|---|---|
| `id` | Service ARN. |
| `name` | Service name. This is the ServiceName dimension for CloudWatch metrics and what `aws ecs update-service --service` takes. |
| `task_definition_arn` | Full ARN of the task definition revision this apply produced, including the revision number. This is the value to record in a deployment log — it is the only unambiguous answer to "what is running". |
| `task_definition_family` | Task definition family. |
| `task_definition_revision` | Task definition revision number. Rolling back means re-deploying a previous revision of this family. |
| `container_definitions` | Rendered container definitions, as ECS received them. Useful for diffing what changed between two applies. |
| `task_exec_iam_role_arn` | Execution role ARN — what ECS assumes to pull the image and read secrets. Grant a secret's resource policy to THIS role, not the task role. |
| `task_exec_iam_role_name` | Execution role name. |
| `tasks_iam_role_arn` | Task role ARN — the identity the application itself uses against AWS APIs. This is the principal to name in an S3 bucket policy or a KMS key policy. |
| `tasks_iam_role_name` | Task role name. |
| `autoscaling_policy_arns` | Map of scaling policy key to ARN. Empty when autoscaling is disabled. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
