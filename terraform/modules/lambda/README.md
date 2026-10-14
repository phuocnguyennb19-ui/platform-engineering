# lambda

## Usage

```hcl
module "lambda" {
  source = "../../modules/lambda"

  name = local.name_prefix

  tags = local.tags
}
```

Every input not listed above has a default — 5 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Name prefix. Each function is named "<name>-<key>". |

## Outputs

| Name | Description |
|---|---|
| `function_arns` | Map of function key to ARN. |
| `function_names` | Map of function key to name. |
| `function_invoke_arns` | Map of function key to invoke ARN — what an API Gateway integration or an ALB target group references. |
| `function_qualified_arns` | Map of function key to the published-version ARN. |
| `execution_role_arns` | Map of function key to execution role ARN. Attach extra permissions to these rather than widening policy_statements when the grant is owned elsewhere. |
| `execution_role_names` | Map of function key to execution role name. |
| `log_group_names` | Map of function key to CloudWatch log group name. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
