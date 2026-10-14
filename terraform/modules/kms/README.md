# kms

## Usage

```hcl
module "kms" {
  source = "../../modules/kms"

  name = local.name_prefix

  tags = local.tags
}
```

Every input not listed above has a default — 2 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Name prefix, conventionally "<project>-<environment>". Aliases become alias/<name>-<key>. |

## Outputs

| Name | Description |
|---|---|
| `key_arns` | Map of purpose to KMS key ARN. This is what every other module consumes, e.g. module.kms.key_arns["rds"]. |
| `key_ids` | Map of purpose to KMS key ID. |
| `alias_names` | Map of purpose to alias name. |
| `alias_arns` | Map of purpose to alias ARN. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
