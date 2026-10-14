# sqs

SQS queues, each optionally with a dead-letter queue. Wraps `terraform-aws-sqs` (v4.2.1).

Every queue is encrypted (SQS-managed SSE, or SSE-KMS with `kms_key_arn`) and long-polls by
default. `dead_letter` creates `<name>-dlq` and redrives after `max_receive_count` (default 5)
failed receives.

## Usage

```hcl
module "queues" {
  source = "../../modules/sqs"

  name_prefix = "platform-dev"

  queues = {
    orders = { visibility_timeout_seconds = 60, dead_letter = {} }
    events = { fifo = true, content_based_deduplication = true }
  }

  tags = local.tags
}
```

Every input not listed below has a default — 2 of them. See `variables.tf`.

## Required inputs

| Name | Type | Description |
|---|---|---|
| `name_prefix` | `string` | A queue is named "<name_prefix>-<key>" (plus ".fifo" for FIFO). |

## Outputs

| Name | Description |
|---|---|
| `sqs_queue_arns` | Map of queue key to ARN. |
| `sqs_queue_ids` | Map of queue key to URL (ID). |
| `sqs_queue_urls` | Map of queue key to URL. |
| `sqs_queue_names` | Map of queue key to name. |
| `sqs_dead_letter_queue_arns` | Map of queue key to dead-letter queue ARN, for queues that have one. |

## Tests

`tests/sqs.tftest.hcl` — `terraform init -backend=false && terraform test` (Terraform ≥ 1.7).
