locals {
  tables = {
    for k, t in var.tables : k => merge(t, {
      name           = "${var.name_prefix}-${k}"
      ttl_enabled    = t.ttl_attribute_name != null
      stream_enabled = t.stream_view_type != null
      global_secondary_indexes = [
        for i in t.global_secondary_indexes : { for ik, iv in i : ik => iv if iv != null }
      ]
    })
  }
}
