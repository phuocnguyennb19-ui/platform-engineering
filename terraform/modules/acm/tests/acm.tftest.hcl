mock_provider "aws" {}

variables {
  domain_name = "staging.example.com"
  zone_id     = "Z0123456789ABCDEFGHIJ"
}

# This module is a thin wrapper around terraform-aws-modules/acm, and a contract test cannot see
# inside a child module: the DNS-only validation method and wait_for_validation are pinned by the
# module call itself, not observable from here. What is testable is the input contract, and that
# the wrapper plans at all — which is what catches an upstream input renamed under a version bump.

run "the_default_certificate_plans" {
  command = plan

  assert {
    condition     = var.key_algorithm == "RSA_2048"
    error_message = "the default key algorithm is the widely compatible one"
  }
}

# A wildcard does not cover the apex, so the apex is carried as a SAN rather than as a second
# certificate.
run "a_wildcard_with_the_apex_as_a_san_plans" {
  command = plan
  variables {
    domain_name               = "*.example.com"
    subject_alternative_names = ["example.com"]
  }

  assert {
    condition     = length(var.subject_alternative_names) == 1
    error_message = "the apex belongs on the same certificate as the wildcard"
  }
}

run "an_elliptic_curve_algorithm_is_accepted" {
  command = plan
  variables {
    key_algorithm = "EC_prime256v1"
  }
}

run "rejects_an_unknown_key_algorithm" {
  command = plan
  variables {
    key_algorithm = "RSA_1024"
  }
  expect_failures = [var.key_algorithm]
}
