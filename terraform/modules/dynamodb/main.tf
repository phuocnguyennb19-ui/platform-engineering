module "dynamodb_table" {
  for_each = local.tables
  source   = "git::https://github.com/terraform-aws-modules/terraform-aws-dynamodb-table.git?ref=v4.1.0"

  name       = each.value.name
  hash_key   = each.value.hash_key
  range_key  = each.value.range_key
  attributes = each.value.attributes

  billing_mode   = each.value.billing_mode
  read_capacity  = each.value.read_capacity
  write_capacity = each.value.write_capacity

  global_secondary_indexes = each.value.global_secondary_indexes

  ttl_enabled        = each.value.ttl_enabled
  ttl_attribute_name = coalesce(each.value.ttl_attribute_name, "")

  stream_enabled   = each.value.stream_enabled
  stream_view_type = each.value.stream_view_type

  server_side_encryption_enabled     = true
  server_side_encryption_kms_key_arn = each.value.kms_key_arn

  point_in_time_recovery_enabled = each.value.point_in_time_recovery_enabled
  deletion_protection_enabled    = each.value.deletion_protection_enabled

  tags = var.tags
}
