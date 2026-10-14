locals {
  topics = {
    for k, t in var.topics : k => merge(t, {
      name    = t.fifo ? "${var.name_prefix}-${k}.fifo" : "${var.name_prefix}-${k}"
      kms_key = coalesce(t.kms_key_arn, "alias/aws/sns")
    })
  }
}
