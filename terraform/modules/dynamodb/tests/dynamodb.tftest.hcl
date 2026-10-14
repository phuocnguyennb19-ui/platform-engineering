mock_provider "aws" {}

variables {
  name_prefix = "platform-dev"
  tables = {
    orders = {
      hash_key  = "pk"
      range_key = "sk"
      attributes = [
        { name = "pk", type = "S" },
        { name = "sk", type = "S" },
        { name = "status", type = "S" },
      ]
      global_secondary_indexes = [{ name = "by-status", hash_key = "status" }]
      ttl_attribute_name       = "expires_at"
    }
  }
}

run "safe_defaults" {
  command = plan

  assert {
    condition     = local.tables["orders"].name == "platform-dev-orders"
    error_message = "Table names must be <name_prefix>-<key>."
  }

  assert {
    condition     = local.tables["orders"].point_in_time_recovery_enabled && local.tables["orders"].deletion_protection_enabled
    error_message = "Point-in-time recovery and deletion protection must default to on."
  }

  assert {
    condition     = local.tables["orders"].billing_mode == "PAY_PER_REQUEST"
    error_message = "On-demand billing must be the default."
  }

  assert {
    condition     = local.tables["orders"].ttl_enabled && !local.tables["orders"].stream_enabled
    error_message = "TTL follows ttl_attribute_name; streams stay off without stream_view_type."
  }

  assert {
    condition     = !contains(keys(local.tables["orders"].global_secondary_indexes[0]), "range_key")
    error_message = "Unset optional index fields must not be passed upstream as nulls."
  }
}

run "rejects_undeclared_key_attribute" {
  command = plan

  variables {
    tables = {
      bad = {
        hash_key   = "pk"
        attributes = [{ name = "id", type = "S" }]
      }
    }
  }

  expect_failures = [var.tables]
}

run "rejects_provisioned_without_capacity" {
  command = plan

  variables {
    tables = {
      bad = {
        hash_key     = "pk"
        attributes   = [{ name = "pk", type = "S" }]
        billing_mode = "PROVISIONED"
      }
    }
  }

  expect_failures = [var.tables]
}
