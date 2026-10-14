locals {
  queues = {
    for k, q in var.queues : k => merge(q, {
      name            = q.fifo ? "${var.name_prefix}-${k}.fifo" : "${var.name_prefix}-${k}"
      dlq_name        = q.fifo ? "${var.name_prefix}-${k}-dlq.fifo" : "${var.name_prefix}-${k}-dlq"
      sqs_managed_sse = q.kms_key_arn == null
      create_dlq      = q.dead_letter != null
    })
  }
}
