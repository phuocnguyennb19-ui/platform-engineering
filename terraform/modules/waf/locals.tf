locals {
  managed_rules = {
    for k, g in var.managed_rule_groups : k => {
      priority        = g.priority
      override_action = g.count_only ? "count" : "none"
      statement = {
        managed_rule_group_statement = {
          name        = g.name
          vendor_name = g.vendor_name
        }
      }
    }
  }

  rate_rules = var.rate_limit == null ? {} : {
    rate-limit = {
      priority = 1
      action   = "block"
      statement = {
        rate_based_statement = {
          limit              = var.rate_limit
          aggregate_key_type = "IP"
        }
      }
    }
  }
}
