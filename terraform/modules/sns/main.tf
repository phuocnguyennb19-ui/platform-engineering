module "sns" {
  for_each = local.topics
  source   = "git::https://github.com/terraform-aws-modules/terraform-aws-sns.git?ref=v6.1.1"

  name         = each.value.name
  display_name = each.value.display_name

  fifo_topic                  = each.value.fifo
  content_based_deduplication = each.value.content_based_deduplication

  kms_master_key_id = each.value.kms_key

  source_topic_policy_documents = each.value.policy != null ? [each.value.policy] : []

  subscriptions = {
    for k, s in each.value.subscriptions : k => {
      protocol             = s.protocol
      endpoint             = s.endpoint
      raw_message_delivery = s.raw_message_delivery
      filter_policy        = s.filter_policy
    }
  }

  tags = var.tags
}
