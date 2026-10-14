variables {
  config_root = "./fixtures/valid"
}

run "registry_loads_enabled_applications" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "dev"
  }

  assert {
    condition     = length(output.errors) == 0
    error_message = "valid fixture must produce no errors: ${join("; ", output.errors)}"
  }

  assert {
    condition     = join(",", sort(keys(output.applications))) == "api,web" && output.applications.web.repository == "web-api"
    error_message = "both applications are enabled in dev"
  }

  assert {
    condition     = join(",", output.promotion_consumer_account_ids) == "222222222222" && output.name == "acme-dev"
    error_message = "prod promotes from dev, so dev must grant prod's account"
  }
}

run "application_without_overlay_is_not_enabled" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = join(",", keys(output.applications)) == "web"
    error_message = "api has no prod.yaml"
  }
}

run "dev_pipeline_tag_overrides_and_values_merge" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "dev"
    application = "web"
    image_tag   = "abc123"
  }

  assert {
    condition     = length(output.errors) == 0
    error_message = join("; ", output.errors)
  }

  assert {
    condition     = output.application.image_tag == "abc123" && output.application.repository == "web-api" && output.application.port == 8080
    error_message = "pipeline tag and app.yaml values expected"
  }

  assert {
    condition     = join(" ", output.application.health_check_command) == "CMD /web -check" && output.application.environment.RETRIES == "3"
    error_message = "dev.yaml must replace the list and stringify scalars"
  }
}

run "dev_without_any_tag_fails" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "dev"
    application = "web"
  }

  assert {
    condition     = anytrue([for e in output.errors : strcontains(e, "image tag is required")])
    error_message = "missing tag must be reported"
  }
}

run "dev_falls_back_to_yaml_tag" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "dev"
    application = "api"
  }

  assert {
    condition     = length(output.errors) == 0 && output.application.image_tag == "abc123"
    error_message = "dev.yaml tag is the fallback"
  }
}

run "latest_is_rejected" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "dev"
    application = "web"
    image_tag   = "latest"
  }

  assert {
    condition     = anytrue([for e in output.errors : strcontains(e, "must not be latest")])
    error_message = "latest must be rejected"
  }
}

run "prod_uses_pinned_tag" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "prod"
    application = "web"
  }

  assert {
    condition     = length(output.errors) == 0 && output.application.image_tag == "9f21abc" && output.application.autoscaling_max == 6
    error_message = join("; ", output.errors)
  }
}

run "prod_matching_pipeline_tag_is_accepted" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "prod"
    application = "web"
    image_tag   = "9f21abc"
  }

  assert {
    condition     = length(output.errors) == 0
    error_message = join("; ", output.errors)
  }
}

run "prod_mismatched_pipeline_tag_fails" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "prod"
    application = "web"
    image_tag   = "abc123"
  }

  assert {
    condition     = anytrue([for e in output.errors : strcontains(e, "does not match image.tag 9f21abc")])
    error_message = "mismatch must be reported"
  }
}

run "not_enabled_in_environment_fails" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "prod"
    application = "api"
  }

  assert {
    condition     = anytrue([for e in output.errors : strcontains(e, "prod.yaml does not exist")])
    error_message = "missing overlay must be reported"
  }
}

run "unknown_application_fails" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "dev"
    application = "nope"
  }

  assert {
    condition     = join(";", output.errors) == "applications/nope/terraform does not exist"
    error_message = join("; ", output.errors)
  }
}

run "invalid_configuration_is_reported" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    config_root = "./fixtures/invalid"
    environment = "dev"
  }

  assert {
    condition = alltrue([for want in [
      "backend.yaml: key is derived per layer",
      "one/terraform/app.yaml: application.name must be \"one\"",
      "one/terraform/app.yaml: resources belongs in <environment>.yaml",
      "two/terraform/dev.yaml: image.repository is set only in app.yaml",
      "two/terraform/prd.yaml: no environment named prd",
      "image.repository shared is declared by more than one application",
    ] : anytrue([for e in output.errors : strcontains(e, want)])])
    error_message = join("; ", output.errors)
  }
}

run "invalid_runtime_and_sizes_are_reported" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    config_root = "./fixtures/invalid"
    environment = "dev"
    application = "two"
    image_tag   = "abc123"
  }

  assert {
    condition = alltrue([for want in [
      "runtime.type must be ecs or eks",
      "container.port must be an integer",
      "deployment.replicas must be an integer",
    ] : anytrue([for e in output.errors : strcontains(e, want)])])
    error_message = join("; ", output.errors)
  }
}

run "network_merges_and_gets_a_derived_priority" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "prod"
    application = "web"
  }

  assert {
    condition     = output.application.network.host == "web.prod.example.com" && output.application.network.path == "/" && output.application.network.priority >= 10000 && output.application.network.priority <= 49999
    error_message = jsonencode(output.application.network)
  }
}

run "application_without_network_has_no_route" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    environment = "dev"
    application = "api"
  }

  assert {
    condition     = output.application.network == null
    error_message = "api declares no network"
  }
}

run "conflicting_routes_are_reported" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    config_root = "./fixtures/routes"
    environment = "dev"
  }

  assert {
    condition = alltrue([for want in [
      "applications/b/terraform: shop.example.com/api is also routed by c",
      "applications/a/terraform: host shop.example.com is shared with another application",
      "applications/c/terraform: network.priority must be an integer between 1 and 9999",
      "applications/d/terraform: network.host must be a lowercase DNS name",
      "applications/d/terraform: network.path must start with /",
    ] : anytrue([for e in output.errors : strcontains(e, want)])])
    error_message = join("\n", output.errors)
  }
}

run "eks_application_is_not_deployed_by_terraform" {
  module {
    source = "../shared/config"
  }

  command = plan

  variables {
    config_root = "./fixtures/invalid"
    environment = "dev"
    application = "three"
    image_tag   = "abc123"
  }

  assert {
    condition     = anytrue([for e in output.errors : strcontains(e, "eks applications are deployed by helm-project")])
    error_message = join("\n", output.errors)
  }
}
