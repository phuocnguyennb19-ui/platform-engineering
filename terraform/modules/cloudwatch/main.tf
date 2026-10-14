data "aws_region" "current" {}

locals {
  topic_arn = var.sns_topic_arn != null ? var.sns_topic_arn : one(aws_sns_topic.alarms[*].arn)

  alarm_actions = local.topic_arn != null ? [local.topic_arn] : []
}

resource "aws_sns_topic" "alarms" {
  count = var.create_sns_topic && var.sns_topic_arn == null ? 1 : 0

  name              = "${var.name}-alarms"
  display_name      = "${var.name} infrastructure alarms"
  kms_master_key_id = var.sns_kms_key_arn

  tags = merge(var.tags, { Name = "${var.name}-alarms" })
}

data "aws_iam_policy_document" "topic" {
  count = var.create_sns_topic && var.sns_topic_arn == null ? 1 : 0

  statement {
    sid       = "AllowCloudWatchAlarmsToPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alarms[0].arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudwatch:${data.aws_region.current.name}:*:alarm:*"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["SNS:Publish", "SNS:Subscribe"]
    resources = [aws_sns_topic.alarms[0].arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  count = var.create_sns_topic && var.sns_topic_arn == null ? 1 : 0

  arn    = aws_sns_topic.alarms[0].arn
  policy = data.aws_iam_policy_document.topic[0].json
}

resource "aws_sns_topic_subscription" "this" {
  for_each = var.create_sns_topic && var.sns_topic_arn == null ? var.sns_subscriptions : {}

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = each.value.protocol
  endpoint  = each.value.endpoint
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = var.log_groups

  name              = each.value.name
  retention_in_days = each.value.retention_in_days
  # try(): coalesce() errors when every argument is null.
  kms_key_id   = try(coalesce(each.value.kms_key_arn, var.default_log_kms_key_arn), null)
  skip_destroy = each.value.skip_destroy

  tags = merge(var.tags, each.value.tags, { Name = each.value.name })
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = var.metric_alarms

  alarm_name        = "${var.name}-${each.key}"
  alarm_description = each.value.alarm_description

  namespace   = each.value.namespace
  metric_name = each.value.metric_name
  dimensions  = each.value.dimensions

  statistic          = each.value.extended_statistic == null ? each.value.statistic : null
  extended_statistic = each.value.extended_statistic

  period              = each.value.period
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison_operator
  treat_missing_data  = each.value.treat_missing_data
  unit                = each.value.unit

  alarm_actions             = local.alarm_actions
  ok_actions                = local.alarm_actions
  insufficient_data_actions = []

  tags = merge(var.tags, each.value.tags, {
    Name     = "${var.name}-${each.key}"
    Severity = each.value.severity
  })
}

resource "aws_cloudwatch_dashboard" "this" {
  count = var.create_dashboard && length(var.metric_alarms) > 0 ? 1 : 0

  dashboard_name = "${var.name}-alarms"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = max(3, ceil(length(var.metric_alarms) / 4.0) + 2)
        properties = {
          title  = "${var.name} — alarm state"
          alarms = [for k, v in aws_cloudwatch_metric_alarm.this : v.arn]
        }
      },
    ]
  })
}
