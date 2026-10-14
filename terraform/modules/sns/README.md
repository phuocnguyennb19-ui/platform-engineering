# sns

SNS topics with typed subscriptions. Wraps `terraform-aws-sns` (v6.1.1).

Every topic is encrypted at rest — with `kms_key_arn`, or the AWS-managed `alias/aws/sns` key.
An AWS service publisher (CloudWatch, EventBridge) needs a customer-managed key. Plain `http`
subscriptions are rejected.

## Usage

```hcl
module "topics" {
  source = "../../modules/sns"

  name_prefix = "platform-dev"

  topics = {
    orders = {
      subscriptions = {
        worker = { protocol = "sqs", endpoint = module.queues.sqs_queue_arns["orders"] }
      }
    }
  }

  tags = local.tags
}
```

Every input not listed below has a default — 2 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name_prefix` | `string` | A topic is named "<name_prefix>-<key>" (plus ".fifo" for FIFO). |

## Outputs

| Name | Description |
|---|---|
| `sns_topic_arns` | Map of topic key to ARN. |
| `sns_topic_ids` | Map of topic key to ID. |
| `sns_topic_owners` | Map of topic key to owning account. |

## Tests

`tests/sns.tftest.hcl` — `terraform init -backend=false && terraform test` (Terraform ≥ 1.7).
