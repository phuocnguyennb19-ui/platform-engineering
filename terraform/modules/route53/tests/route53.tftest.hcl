mock_provider "aws" {
  mock_data "aws_route53_zone" {
    defaults = { zone_id = "Z0123456789ABCDEFGHIJ", name_servers = ["ns-1.awsdns.com", "ns-2.awsdns.org"] }
  }
}

variables {
  zone_name = "staging.example.com"
}

# The default is to look a zone up, not create one. Creating a public zone that already exists
# elsewhere produces a second zone with different nameservers and no error — the records simply
# never resolve, which is the failure this default exists to prevent.
run "the_zone_is_looked_up_by_default" {
  command = plan

  assert {
    condition     = length(aws_route53_zone.this) == 0
    error_message = "create_zone must default to false: an environment attaches records to a zone it does not own"
  }

  assert {
    condition     = length(data.aws_route53_zone.this) == 1
    error_message = "the existing zone must be looked up instead"
  }

  assert {
    condition     = data.aws_route53_zone.this[0].name == "staging.example.com"
    error_message = "the lookup must use the zone name the caller gave"
  }
}

run "creating_a_zone_is_opt_in_and_safe_by_default" {
  command = plan
  variables {
    create_zone = true
  }

  assert {
    condition     = length(aws_route53_zone.this) == 1 && length(data.aws_route53_zone.this) == 0
    error_message = "create_zone true creates the zone and looks nothing up"
  }

  assert {
    condition     = !aws_route53_zone.this[0].force_destroy
    error_message = "force_destroy must default off: a zone someone else depends on should not be destroyable with records in it"
  }

  assert {
    condition     = length(aws_route53_zone.this[0].vpc) == 0
    error_message = "a public zone carries no VPC association"
  }
}

# VPC association is gated on private_zone, not on vpc_ids being present: associating a VPC with a
# public zone is not a configuration AWS accepts. Only the empty side is assertable at plan — a
# written vpc block carries a computed vpc_region, so the populated set reads as unknown.
run "a_public_zone_ignores_vpc_ids" {
  command = plan
  variables {
    create_zone  = true
    private_zone = false
    vpc_ids      = ["vpc-0aaa", "vpc-0bbb"]
  }

  assert {
    condition     = length(aws_route53_zone.this[0].vpc) == 0
    error_message = "vpc_ids must reach the zone only when it is private"
  }
}

# The lookup side of the same switch: a private zone is looked up as private, so a public zone of
# the same name is not what the records attach to.
run "a_private_zone_is_looked_up_as_private" {
  command = plan
  variables {
    private_zone = true
  }

  assert {
    condition     = data.aws_route53_zone.this[0].private_zone
    error_message = "the lookup must ask for the private zone, not a public zone of the same name"
  }
}

# An alias record takes no TTL — AWS rejects the pair — and a plain record must keep one. The
# module decides, so the caller never sends the rejected combination.
run "an_alias_record_drops_the_ttl_and_a_plain_record_keeps_it" {
  command = plan
  variables {
    records = {
      apex = {
        name = "staging.example.com"
        type = "A"
        alias = {
          name    = "dualstack.platform-staging-alb-123.ap-southeast-1.elb.amazonaws.com"
          zone_id = "Z1LMS91P8CMLE5"
        }
      }
      txt = {
        name    = "_verify.staging.example.com"
        type    = "TXT"
        ttl     = 60
        records = ["token"]
      }
    }
  }

  assert {
    condition     = aws_route53_record.this["apex"].ttl == null
    error_message = "an alias record must not carry a TTL"
  }

  assert {
    condition     = length(aws_route53_record.this["apex"].alias) == 1
    error_message = "the alias block must be written for an alias record"
  }

  assert {
    condition     = aws_route53_record.this["txt"].ttl == 60
    error_message = "a plain record keeps the TTL the caller chose"
  }

  assert {
    condition     = length(aws_route53_record.this["txt"].alias) == 0
    error_message = "a plain record carries no alias block"
  }

  assert {
    condition     = aws_route53_record.this["apex"].alias[0].evaluate_target_health
    error_message = "target health evaluation defaults on, so a failed ALB stops being answered"
  }
}

# Weighted routing is written only where a weight was asked for; an empty policy block on every
# record would change how Route53 answers.
run "weighted_routing_only_where_a_weight_is_given" {
  command = plan
  variables {
    records = {
      plain = { name = "a.staging.example.com", type = "A", records = ["10.0.0.1"] }
      blue = {
        name                    = "b.staging.example.com"
        type                    = "A"
        records                 = ["10.0.0.2"]
        set_identifier          = "blue"
        weighted_routing_weight = 90
      }
    }
  }

  assert {
    condition     = length(aws_route53_record.this["plain"].weighted_routing_policy) == 0
    error_message = "a record with no weight gets no routing policy block"
  }

  assert {
    condition     = aws_route53_record.this["blue"].weighted_routing_policy[0].weight == 90
    error_message = "the weight the caller chose must reach the record"
  }
}

run "rejects_a_record_that_sets_both_records_and_alias" {
  command = plan
  variables {
    records = {
      both = {
        name    = "a.staging.example.com"
        type    = "A"
        records = ["10.0.0.1"]
        alias   = { name = "alb.example.com", zone_id = "Z1LMS91P8CMLE5" }
      }
    }
  }
  expect_failures = [var.records]
}

run "rejects_a_record_that_sets_neither" {
  command = plan
  variables {
    records = {
      empty = { name = "a.staging.example.com", type = "A" }
    }
  }
  expect_failures = [var.records]
}
