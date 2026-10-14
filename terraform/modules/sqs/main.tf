module "sqs" {
  for_each = local.queues
  source   = "git::https://github.com/terraform-aws-modules/terraform-aws-sqs.git?ref=v4.2.1"

  name = each.value.name

  fifo_queue                  = each.value.fifo
  content_based_deduplication = each.value.content_based_deduplication

  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds
  max_message_size           = each.value.max_message_size
  delay_seconds              = each.value.delay_seconds
  receive_wait_time_seconds  = each.value.receive_wait_time_seconds

  sqs_managed_sse_enabled = each.value.sqs_managed_sse
  kms_master_key_id       = each.value.kms_key_arn

  create_dlq                    = each.value.create_dlq
  dlq_name                      = each.value.dlq_name
  dlq_message_retention_seconds = try(each.value.dead_letter.message_retention_seconds, null)
  dlq_sqs_managed_sse_enabled   = each.value.sqs_managed_sse
  dlq_kms_master_key_id         = each.value.kms_key_arn
  redrive_policy = each.value.create_dlq ? {
    maxReceiveCount = each.value.dead_letter.max_receive_count
  } : {}

  create_queue_policy           = each.value.policy != null
  source_queue_policy_documents = each.value.policy != null ? [each.value.policy] : []

  tags = var.tags
}
