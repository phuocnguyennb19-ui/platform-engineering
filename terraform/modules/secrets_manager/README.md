# secrets_manager

Secrets Manager secrets whose values stay out of Terraform. Wraps
`terraform-aws-secrets-manager` (v1.1.0).

By default a secret is created with an empty `"{}"` placeholder and Terraform never touches its
value again (`ignore_secret_changes`): the real value is written by a person, a pipeline or a
rotation function, and never enters the state. `generate_password = true` generates a random
value in Terraform instead — it is then stored in the state, so only use it with an encrypted,
access-controlled backend. Public resource policies are blocked; deletion is recoverable for 30
days by default.

## Usage

```hcl
module "secrets" {
  source = "../../modules/secrets_manager"

  name_prefix = "platform-dev"

  secrets = {
    stripe-api-key = {}                                    # value set out of band
    db-app         = { generate_password = true }
  }

  tags = local.tags
}
```

```bash
# write the real value — it never passes through Terraform
aws secretsmanager put-secret-value --secret-id platform-dev/stripe-api-key --secret-string file://value.json
```

Every input not listed below has a default — 2 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name_prefix` | `string` | A secret is named "<name_prefix>/<key>". |

## Outputs

| Name | Description |
|---|---|
| `secret_arns` | Map of secret key to ARN — what an ECS task's `secrets` or an IAM policy references. |
| `secret_ids` | Map of secret key to ID. |
| `secret_names` | Map of secret key to name. |
| `secret_version_ids` | Map of secret key to the version Terraform created. |

## Tests

`tests/secrets_manager.tftest.hcl` — `terraform init -backend=false && terraform test` (Terraform ≥ 1.7).
