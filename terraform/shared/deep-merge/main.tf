# Terraform has no recursion: maps merge four levels deep, lists and scalars are replaced, null in override means unset.
locals {
  base     = var.base
  override = var.override

  merged = {
    for k1 in distinct(concat(keys(local.base), keys(local.override))) : k1 => [
      try(local.base[k1], null),
      try(local.override[k1], null),
      try({
        for k2 in distinct(concat(keys(local.base[k1]), keys(local.override[k1]))) : k2 => [
          try(local.base[k1][k2], null),
          try(local.override[k1][k2], null),
          try({
            for k3 in distinct(concat(keys(local.base[k1][k2]), keys(local.override[k1][k2]))) : k3 => [
              try(local.base[k1][k2][k3], null),
              try(local.override[k1][k2][k3], null),
              try({
                for k4 in distinct(concat(keys(local.base[k1][k2][k3]), keys(local.override[k1][k2][k3]))) : k4 => [
                  try(local.base[k1][k2][k3][k4], null),
                  try(local.override[k1][k2][k3][k4], null),
                  null,
                ][try(local.override[k1][k2][k3][k4], null) != null ? 1 : 0]
              }, null),
            ][(try(local.base[k1][k2][k3], null) != null && try(local.override[k1][k2][k3], null) != null && can(keys(local.base[k1][k2][k3])) && can(keys(local.override[k1][k2][k3]))) ? 2 : (try(local.override[k1][k2][k3], null) != null ? 1 : 0)]
          }, null),
        ][(try(local.base[k1][k2], null) != null && try(local.override[k1][k2], null) != null && can(keys(local.base[k1][k2])) && can(keys(local.override[k1][k2]))) ? 2 : (try(local.override[k1][k2], null) != null ? 1 : 0)]
      }, null),
    ][(try(local.base[k1], null) != null && try(local.override[k1], null) != null && can(keys(local.base[k1])) && can(keys(local.override[k1]))) ? 2 : (try(local.override[k1], null) != null ? 1 : 0)]
  }
}

locals {
  too_deep = flatten([
    for k1 in try(keys(local.override), []) : [
      for k2 in try(keys(local.override[k1]), []) : [
        for k3 in try(keys(local.override[k1][k2]), []) : [
          for k4 in try(keys(local.override[k1][k2][k3]), []) : "${k1}.${k2}.${k3}.${k4}"
          if can(keys(local.override[k1][k2][k3][k4])) && can(keys(local.base[k1][k2][k3][k4]))
        ]
      ]
    ]
  ])
}
