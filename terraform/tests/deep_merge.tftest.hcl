run "override_wins_and_maps_merge" {
  module {
    source = "../shared/deep-merge"
  }

  command = plan

  variables {
    base = {
      application = { name = "a" }
      image       = { repository = "a-api", tag = "base" }
      container   = { port = 8080, health_check_command = ["CMD", "a"] }
    }
    override = {
      image     = { tag = "abc123" }
      container = { health_check_command = ["CMD", "b"] }
      resources = { cpu = 512 }
    }
  }

  assert {
    condition     = output.merged.image.repository == "a-api" && output.merged.image.tag == "abc123"
    error_message = "nested keys must merge, override must win"
  }

  assert {
    condition     = output.merged.container.health_check_command == ["CMD", "b"] && output.merged.container.port == 8080
    error_message = "lists must be replaced, siblings kept"
  }

  assert {
    condition     = output.merged.resources.cpu == 512 && output.merged.application.name == "a"
    error_message = "keys present on one side only must survive"
  }
}

run "lists_are_replaced_not_appended" {
  module {
    source = "../shared/deep-merge"
  }

  command = plan

  variables {
    base     = { l = ["a", "b", "c"] }
    override = { l = ["z"] }
  }

  assert {
    condition     = output.merged.l == ["z"]
    error_message = "lists must be replaced"
  }
}

run "null_override_keeps_base" {
  module {
    source = "../shared/deep-merge"
  }

  command = plan

  variables {
    base     = { image = { repository = "r", tag = "t" } }
    override = { image = { tag = null } }
  }

  assert {
    condition     = output.merged.image.tag == "t"
    error_message = "null in override must mean unset"
  }
}

run "scalar_replaces_map_and_map_replaces_scalar" {
  module {
    source = "../shared/deep-merge"
  }

  command = plan

  variables {
    base     = { a = { x = 1 }, b = "s" }
    override = { a = "flat", b = { y = 2 } }
  }

  assert {
    condition     = output.merged.a == "flat" && output.merged.b.y == 2
    error_message = "type change must replace"
  }
}

run "four_levels_merge_and_deeper_is_reported" {
  module {
    source = "../shared/deep-merge"
  }

  command = plan

  variables {
    base     = { l1 = { l2 = { l3 = { keep = 1, l4 = { deep = 1 } } } } }
    override = { l1 = { l2 = { l3 = { add = 2, l4 = { other = 2 } } } } }
  }

  assert {
    condition     = output.merged.l1.l2.l3.keep == 1 && output.merged.l1.l2.l3.add == 2
    error_message = "level three maps must merge"
  }

  assert {
    condition     = output.too_deep == ["l1.l2.l3.l4"]
    error_message = "a map pair below level four must be reported"
  }
}
