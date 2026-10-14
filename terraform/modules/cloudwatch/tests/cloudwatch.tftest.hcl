mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name = "platform-dev"
  metric_alarms = {
    rds-cpu = {
      alarm_description   = "RDS CPU is high"
      namespace           = "AWS/RDS"
      metric_name         = "CPUUtilization"
      threshold           = 80
      comparison_operator = "GreaterThanThreshold"
    }
  }
}

# An alarm with no action changes colour and tells nobody. Every alarm publishes on ALARM and on
# OK — the OK is what tells on-call the incident is over.
run "every_alarm_notifies_on_both_alarm_and_ok" {
  command = plan
  variables {
    create_sns_topic = false
    sns_topic_arn    = "arn:aws:sns:ap-southeast-1:111122223333:existing-alarms"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["rds-cpu"].alarm_actions == toset(["arn:aws:sns:ap-southeast-1:111122223333:existing-alarms"])
    error_message = "an alarm must publish to the topic"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["rds-cpu"].ok_actions == toset(["arn:aws:sns:ap-southeast-1:111122223333:existing-alarms"])
    error_message = "recovery must notify too, or on-call never learns the incident ended"
  }
}

# An existing topic is used as-is. Creating a second one beside it would split the notifications.
run "an_existing_topic_is_never_duplicated" {
  command = plan
  variables {
    sns_topic_arn = "arn:aws:sns:ap-southeast-1:111122223333:existing-alarms"
  }

  assert {
    condition     = length(aws_sns_topic.alarms) == 0
    error_message = "a caller-supplied topic must not be shadowed by a new one"
  }

  assert {
    condition     = length(aws_sns_topic_policy.alarms) == 0
    error_message = "the module does not rewrite the policy of a topic it does not own"
  }
}

run "the_topic_is_created_when_no_arn_is_given" {
  command = plan

  assert {
    condition     = length(aws_sns_topic.alarms) == 1
    error_message = "with no topic ARN the module creates the one its alarms publish to"
  }

  assert {
    condition     = aws_sns_topic.alarms[0].name == "platform-dev-alarms"
    error_message = "the topic is named after the platform"
  }
}

# treat_missing_data defaults to "missing": for infrastructure metrics an absent datapoint means
# the thing stopped reporting, and "notBreaching" would turn that into silence.
run "a_missing_datapoint_is_not_treated_as_healthy" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["rds-cpu"].treat_missing_data == "missing"
    error_message = "an absent datapoint must not be read as not breaching"
  }
}

# statistic and extended_statistic are mutually exclusive at the API. The module picks one so the
# caller cannot send both.
run "an_extended_statistic_replaces_the_plain_one" {
  command = plan
  variables {
    metric_alarms = {
      latency = {
        alarm_description   = "p99 latency"
        namespace           = "AWS/ApplicationELB"
        metric_name         = "TargetResponseTime"
        extended_statistic  = "p99"
        threshold           = 1
        comparison_operator = "GreaterThanThreshold"
      }
    }
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["latency"].statistic == null
    error_message = "statistic must be dropped when an extended statistic is given"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.this["latency"].extended_statistic == "p99"
    error_message = "the extended statistic must reach the alarm"
  }
}

# Log groups are created here rather than left to the service, which would create them with
# never-expire retention and no key.
run "log_groups_carry_retention_and_the_default_key" {
  command = plan
  variables {
    default_log_kms_key_arn = "arn:aws:kms:ap-southeast-1:111122223333:key/abcd-1234"
    log_groups = {
      api   = { name = "/aws/application/api" }
      audit = { name = "/aws/application/audit", retention_in_days = 365, kms_key_arn = "arn:aws:kms:ap-southeast-1:111122223333:key/audit" }
    }
  }

  assert {
    condition     = aws_cloudwatch_log_group.this["api"].retention_in_days == 30
    error_message = "retention must default to a real value, never to never-expire"
  }

  assert {
    condition     = aws_cloudwatch_log_group.this["api"].kms_key_id == "arn:aws:kms:ap-southeast-1:111122223333:key/abcd-1234"
    error_message = "a group that names no key gets the module's default key"
  }

  assert {
    condition     = aws_cloudwatch_log_group.this["audit"].kms_key_id == "arn:aws:kms:ap-southeast-1:111122223333:key/audit"
    error_message = "a group that names its own key keeps it"
  }
}

run "rejects_a_retention_cloudwatch_does_not_accept" {
  command = plan
  variables {
    log_groups = {
      api = { name = "/aws/application/api", retention_in_days = 45 }
    }
  }
  expect_failures = [var.log_groups]
}

# The dashboard is opt-in, and pointless without alarms to put on it.
run "the_dashboard_is_opt_in" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_dashboard.this) == 0
    error_message = "no dashboard unless the caller asks for one"
  }
}

run "no_dashboard_without_alarms_to_show" {
  command = plan
  variables {
    create_dashboard = true
    metric_alarms    = {}
  }

  assert {
    condition     = length(aws_cloudwatch_dashboard.this) == 0
    error_message = "an alarm dashboard with no alarms is an empty page"
  }
}
