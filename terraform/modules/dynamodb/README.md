# dynamodb

DynamoDB tables. Wraps `terraform-aws-dynamodb-table` (v4.1.0).

Encryption at rest is always on (AWS-owned key, or `kms_key_arn`). Point-in-time recovery and
deletion protection default to **on** — a caller turns them off explicitly for a throwaway
environment. Every key used by the table or an index must be declared in `attributes`; the
module rejects one that is not.

## Usage

```hcl
module "tables" {
  source = "../../modules/dynamodb"

  name_prefix = "platform-dev"

  tables = {
    orders = {
      hash_key  = "pk"
      range_key = "sk"
      attributes = [
        { name = "pk", type = "S" },
        { name = "sk", type = "S" },
      ]
      ttl_attribute_name = "expires_at"
    }
  }

  tags = local.tags
}
```

Every input not listed below has a default — 2 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name_prefix` | `string` | A table is named "<name_prefix>-<key>". |

## Outputs

| Name | Description |
|---|---|
| `dynamodb_table_arns` | Map of table key to ARN. |
| `dynamodb_table_ids` | Map of table key to ID. |
| `dynamodb_table_names` | Map of table key to name. |
| `dynamodb_table_stream_arns` | Map of table key to stream ARN (null without a stream). |

## Tests

`tests/dynamodb.tftest.hcl` — `terraform init -backend=false && terraform test` (Terraform ≥ 1.7).
