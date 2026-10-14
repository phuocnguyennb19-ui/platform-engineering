mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:sts::111122223333:assumed-role/ci/s" }
  }
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-1" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::114774131450:root" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name               = "platform-dev"
  vpc_id             = "vpc-00000000"
  subnet_ids         = ["subnet-0dd", "subnet-0ee"]
  security_group_ids = ["sg-0aaa"]

  target_groups = {
    api = {
      port        = 8080
      protocol    = "HTTP"
      target_type = "ip"
      health_check = {
        path    = "/healthz"
        matcher = "200"
      }
    }
    web = {
      port        = 8080
      protocol    = "HTTP"
      target_type = "ip"
      health_check = {
        path    = "/healthz"
        matcher = "200"
      }
    }
  }
}

run "without_a_certificate_it_serves_plain_http" {
  command = plan

  assert {
    condition     = local.https_enabled == false
    error_message = "no certificate and no explicit enable_https means no HTTPS listener."
  }

  assert {
    condition     = keys(local.listeners) == ["http"]
    error_message = "an HTTP-only ALB must have exactly one listener."
  }

  assert {
    condition     = try(local.listeners.http.forward.target_group_key, null) == "api" && !can(local.listeners.http.redirect)
    error_message = "the HTTP listener must forward to the default target group, not redirect."
  }

  assert {
    condition     = local.default_tg_key == "api"
    error_message = "the default target group must be the first key in sort order when none is named."
  }
}

# The platform issues the certificate in the same apply, so certificate_arn is unknown at plan.
# enable_https exists so the listener set stays decidable; this is what keeps that true.
run "enable_https_decides_the_listener_without_the_arn" {
  command = plan

  variables {
    enable_https    = true
    certificate_arn = null
  }

  assert {
    condition     = local.https_enabled == true
    error_message = "enable_https must decide the HTTPS listener on its own."
  }

  assert {
    condition     = length(setsubtract(toset(keys(local.listeners)), toset(["http", "https"]))) == 0 && length(local.listeners) == 2
    error_message = "HTTPS must add a second listener beside the redirect."
  }
}

run "https_redirects_port_80_permanently" {
  command = plan

  variables {
    certificate_arn = "arn:aws:acm:ap-southeast-1:111122223333:certificate/abc"
  }

  assert {
    condition     = local.listeners.http.redirect.status_code == "HTTP_301" && local.listeners.http.redirect.port == "443"
    error_message = "port 80 must issue a permanent redirect to 443."
  }

  assert {
    condition     = !can(local.listeners.http.forward)
    error_message = "a redirecting HTTP listener must not also forward application traffic."
  }

  assert {
    condition     = local.listeners.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
    error_message = "the HTTPS listener must default to the TLS 1.3 policy."
  }
}

# Host-based rules belong on whichever listener actually serves traffic, or a second service is
# unreachable: on a redirecting HTTP listener they would 301 before matching.
run "listener_rules_land_on_the_serving_listener" {
  command = plan

  variables {
    certificate_arn = "arn:aws:acm:ap-southeast-1:111122223333:certificate/abc"
    listener_rules = {
      web = {
        priority         = 10
        target_group_key = "web"
        host_headers     = ["web.example.com"]
      }
    }
  }

  assert {
    condition     = try(length(local.listeners.https.rules), 0) == 1
    error_message = "with HTTPS the rules must be attached to the HTTPS listener."
  }

  assert {
    condition     = !can(local.listeners.http.rules)
    error_message = "a redirecting HTTP listener must carry no rules."
  }

  assert {
    condition     = local.listener_rules.web.actions[0].target_group_key == "web"
    error_message = "a rule must forward to the target group it names."
  }

  assert {
    condition     = local.listener_rules.web.conditions[0].host_header.values == tolist(["web.example.com"])
    error_message = "host_headers must become a host_header condition."
  }
}

# enable_http_redirect = false closes port 80 rather than serving plaintext on it, so the only
# way to reach the ALB is TLS. Locking this down in a test: turning it into a plaintext forward
# would be a silent downgrade for anyone who set the flag to mean "no redirect".
run "disabling_the_redirect_closes_port_80_rather_than_opening_it" {
  command = plan

  variables {
    enable_http_redirect = false
    certificate_arn      = "arn:aws:acm:ap-southeast-1:111122223333:certificate/abc"
    listener_rules = {
      web = {
        priority         = 10
        target_group_key = "web"
        host_headers     = ["web.example.com"]
      }
    }
  }

  assert {
    condition     = keys(local.listeners) == ["https"]
    error_message = "with HTTPS on and the redirect off there must be no plaintext listener at all."
  }

  assert {
    condition     = try(length(local.listeners.https.rules), 0) == 1
    error_message = "the rules must still reach the only listener that serves traffic."
  }
}

# The plaintext forward path is reachable only when there is no HTTPS listener.
run "http_only_alb_forwards_and_carries_its_rules" {
  command = plan

  variables {
    listener_rules = {
      web = {
        priority         = 10
        target_group_key = "web"
        host_headers     = ["web.example.com"]
      }
    }
  }

  assert {
    condition     = try(local.listeners.http.forward.target_group_key, null) == "api" && try(length(local.listeners.http.rules), 0) == 1
    error_message = "an HTTP-only ALB serves traffic on port 80 and carries the rules there."
  }
}

# AWS rejects a target group name over 32 characters, and only at apply.
run "target_group_names_stay_within_the_aws_limit" {
  command = plan

  variables {
    name = "platform-preprod-really-long-abc"
  }

  assert {
    condition     = alltrue([for k, tg in local.target_groups : length(tg.name) <= 32])
    error_message = "target group names must be truncated to 32 characters."
  }
}

run "rejects_a_single_subnet" {
  command = plan

  variables {
    subnet_ids = ["subnet-0dd"]
  }

  expect_failures = [var.subnet_ids]
}

run "rejects_a_name_aws_would_refuse" {
  command = plan

  variables {
    name = "platform-preprod-far-too-long-for-an-alb-name"
  }

  expect_failures = [var.name]
}
