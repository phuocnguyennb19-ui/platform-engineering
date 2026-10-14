# ecr

## Usage

```hcl
module "ecr" {
  source = "../../modules/ecr"

  name = local.name_prefix

  tags = local.tags
}
```

Every input not listed above has a default — 4 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name` | `string` | Name prefix. Repository names become "<name>/<key>" unless use_name_prefix is false. |

## Outputs

| Name | Description |
|---|---|
| `repository_urls` | Map of repository key to registry URL — the value that goes in a container image reference. |
| `repository_arns` | Map of repository key to ARN. Pass these to the iam module's ec2_ecr_pull_repository_arns, or to an IRSA role, to scope pull permission to named repositories. |
| `repository_names` | Map of repository key to full repository name. |
| `registry_id` | Registry (account) ID hosting the repositories. |

## Notes

- Pin a tag in `source`, never a branch.
- A worked, wired-together example is in [`examples/complete`](../../examples/complete).
