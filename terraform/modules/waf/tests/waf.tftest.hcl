mock_provider "aws" {}

variables {
  name = "platform-dev"
}

run "aws_baseline_by_default" {
  command = plan

  assert {
    condition     = toset(keys(local.managed_rules)) == toset(["common", "bad-inputs", "ip-reputation"])
    error_message = "The AWS baseline rule groups must be on by default."
  }

  assert {
    condition     = alltrue([for r in values(local.managed_rules) : r.override_action == "none"])
    error_message = "Managed groups must block by default, not only count."
  }

  assert {
    condition     = length(local.rate_rules) == 0
    error_message = "No rate-based rule unless rate_limit is set."
  }
}

run "count_mode_and_rate_limit" {
  command = plan

  variables {
    managed_rule_groups = {
      sqli = { priority = 40, name = "AWSManagedRulesSQLiRuleSet", count_only = true }
    }
    rate_limit = 2000
  }

  assert {
    condition     = local.managed_rules["sqli"].override_action == "count"
    error_message = "count_only must run the group in count mode."
  }

  assert {
    condition     = local.rate_rules["rate-limit"].statement.rate_based_statement.limit == 2000 && local.rate_rules["rate-limit"].action == "block"
    error_message = "rate_limit must create a blocking rate-based rule."
  }
}

run "rejects_unknown_scope" {
  command = plan

  variables {
    scope = "GLOBAL"
  }

  expect_failures = [var.scope]
}

run "rejects_rate_limit_below_aws_minimum" {
  command = plan

  variables {
    rate_limit = 10
  }

  expect_failures = [var.rate_limit]
}
