locals {
  environments_dir = "${var.config_root}/environments"
  applications_dir = coalesce(var.applications_root, "${var.config_root}/applications")
  env_path         = "infra-base/terraform/environments/${var.environment}"

  env_raw = {
    for k in ["environment", "core", "backend"] : k => yamldecode(
      fileexists("${local.environments_dir}/${var.environment}/${k}.yaml")
      ? (trimspace(file("${local.environments_dir}/${var.environment}/${k}.yaml")) == "" ? "{}" : file("${local.environments_dir}/${var.environment}/${k}.yaml"))
      : "{}"
    )
  }
  env_docs    = { for k, d in local.env_raw : k => [d, {}][can(keys(d)) ? 0 : 1] }
  environment = local.env_docs.environment
  core        = local.env_docs.core
  backend     = local.env_docs.backend

  all_environments = {
    for f in fileset(local.environments_dir, "*/environment.yaml") :
    dirname(f) => try(yamldecode(file("${local.environments_dir}/${f}")), {})
  }

  account_id     = try(tostring(local.environment.account.id), "")
  region         = try(tostring(local.environment.region.name), "")
  name_prefix    = try(tostring(local.environment.name_prefix), "")
  tags           = try(tomap(local.environment.tags), {})
  tag_source     = try(tostring(local.environment.release.image_tag_source), "")
  promote_from   = try(tostring(local.environment.release.promote_from), "")
  backend_bucket = try(tostring(local.backend.bucket), "")
  backend_region = try(tostring(local.backend.region), "")

  promotion_consumer_account_ids = distinct([
    for e, d in local.all_environments : tostring(d.account.id)
    if e != var.environment && try(tostring(d.release.promote_from), "") == var.environment && can(regex("^[0-9]{12}$", try(tostring(d.account.id), "")))
  ])

  shared_registry = [
    for e, d in local.all_environments : e
    if e != var.environment && local.account_id != "" && try(tostring(d.account.id), "") == local.account_id && try(tostring(d.region.name), "") == local.region
  ]

  environment_errors = concat(
    [for k in ["environment", "core", "backend"] : "${local.env_path}/${k}.yaml does not exist" if !fileexists("${local.environments_dir}/${var.environment}/${k}.yaml")],
    try(tostring(local.environment.environment), "") == var.environment ? [] : ["${local.env_path}/environment.yaml: environment must be \"${var.environment}\""],
    can(regex("^[0-9]{12}$", local.account_id)) ? [] : ["${local.env_path}/environment.yaml: account.id must be the 12-digit AWS account ID, quoted"],
    can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", local.region)) ? [] : ["${local.env_path}/environment.yaml: region.name must be an AWS region"],
    can(regex("^[a-z][a-z0-9-]{0,19}$", local.name_prefix)) ? [] : ["${local.env_path}/environment.yaml: name_prefix must match ^[a-z][a-z0-9-]{0,19}$"],
    can(tomap(try(local.environment.tags, {}))) ? [] : ["${local.env_path}/environment.yaml: tags must be a map of strings"],
    contains(["pipeline", "config"], local.tag_source) ? [] : ["${local.env_path}/environment.yaml: release.image_tag_source must be pipeline or config"],
    local.promote_from == "" || (local.promote_from != var.environment && contains(keys(local.all_environments), local.promote_from)) ? [] : ["${local.env_path}/environment.yaml: release.promote_from must name another environment"],
    [for k in ["application", "applications", "image", "container", "cpu", "memory", "resources", "deployment"] : "${local.env_path}/environment.yaml: ${k} is not environment configuration" if contains(keys(local.environment), k)],
    [for k in ["application", "applications", "image", "container", "resources", "deployment", "environment", "secrets"] : "${local.env_path}/core.yaml: ${k} is application configuration" if contains(keys(local.core), k)],
    [for k in ["ecs", "eks"] : "${local.env_path}/core.yaml: ${k}.enabled must be true or false" if !can(tobool(local.core[k].enabled))],
    local.backend_bucket != "" ? [] : ["${local.env_path}/backend.yaml: bucket is required"],
    can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", local.backend_region)) ? [] : ["${local.env_path}/backend.yaml: region must be an AWS region"],
    try(local.backend.encrypt, null) == true ? [] : ["${local.env_path}/backend.yaml: encrypt must be true"],
    try(local.backend.use_lockfile, null) == true ? [] : ["${local.env_path}/backend.yaml: use_lockfile must be true"],
    contains(keys(local.backend), "key") ? ["${local.env_path}/backend.yaml: key is derived per layer and must not be set"] : [],
    length(local.shared_registry) == 0 ? [] : ["${local.env_path}/environment.yaml: account ${local.account_id} in ${local.region} is also used by ${join(", ", local.shared_registry)}; repository names would collide"],
  )

  # Each application keeps its Terraform config in <applications_dir>/<app>/terraform/.
  app_files = fileset(local.applications_dir, "*/terraform/*.yaml")
  app_dirs  = toset([for f in local.app_files : split("/", f)[0]])

  apps = {
    for d in local.app_dirs : d => {
      has_base = fileexists("${local.applications_dir}/${d}/terraform/app.yaml")
      enabled  = fileexists("${local.applications_dir}/${d}/terraform/${var.environment}.yaml")
      base     = yamldecode(fileexists("${local.applications_dir}/${d}/terraform/app.yaml") ? (trimspace(file("${local.applications_dir}/${d}/terraform/app.yaml")) == "" ? "{}" : file("${local.applications_dir}/${d}/terraform/app.yaml")) : "{}")
      override = yamldecode(fileexists("${local.applications_dir}/${d}/terraform/${var.environment}.yaml") ? (trimspace(file("${local.applications_dir}/${d}/terraform/${var.environment}.yaml")) == "" ? "{}" : file("${local.applications_dir}/${d}/terraform/${var.environment}.yaml")) : "{}")
      overlays = [for f in local.app_files : trimsuffix(basename(f), ".yaml") if split("/", f)[0] == d && basename(f) != "app.yaml"]
    }
  }

  repository_pattern = "^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$"
  repositories       = [for d, a in local.apps : try(tostring(a.base.image.repository), "")]
  duplicate_repos    = distinct([for r in local.repositories : r if r != "" && length([for x in local.repositories : x if x == r]) > 1])

  app_errors = {
    for d, a in local.apps : d => concat(
      a.has_base ? [] : ["applications/${d}/terraform/app.yaml does not exist"],
      can(keys(a.base)) && can(keys(a.override)) ? [] : ["applications/${d}/terraform: app.yaml and ${var.environment}.yaml must be YAML mappings"],
      try(tostring(a.base.application.name), "") == d ? [] : ["applications/${d}/terraform/app.yaml: application.name must be \"${d}\""],
      can(regex(local.repository_pattern, try(tostring(a.base.image.repository), ""))) ? [] : ["applications/${d}/terraform/app.yaml: image.repository must be a valid ECR repository name"],
      [for k in ["resources", "deployment", "environment", "secrets", "cpu", "memory", "replicas"] : "applications/${d}/terraform/app.yaml: ${k} belongs in <environment>.yaml" if contains(try(keys(a.base), []), k)],
      contains(try(keys(a.override), []), "application") ? ["applications/${d}/terraform/${var.environment}.yaml: application must not be overridden"] : [],
      try(a.override.image.repository, null) == null ? [] : ["applications/${d}/terraform/${var.environment}.yaml: image.repository is set only in app.yaml"],
    )
  }

  global_app_errors = concat(
    flatten([for d, a in local.apps : [for o in a.overlays : "applications/${d}/terraform/${o}.yaml: no environment named ${o}" if !contains(keys(local.all_environments), o)]]),
    [for r in local.duplicate_repos : "applications/*/terraform: image.repository ${r} is declared by more than one application"],
    local.route_errors,
  )

  # network is flat, so <environment>.yaml wins key by key, as in the deep merge.
  routes = {
    for d, a in local.apps : d => {
      host     = lower(try(coalesce(try(tostring(a.override.network.host), null), try(tostring(a.base.network.host), null)), ""))
      path     = try(coalesce(try(tostring(a.override.network.path), null), try(tostring(a.base.network.path), null)), "/")
      explicit = try(coalesce(try(tonumber(a.override.network.priority), null), try(tonumber(a.base.network.priority), null)), 0)
    } if a.enabled && a.has_base && length(setintersection(toset(concat(try(keys(a.base.network), []), try(keys(a.override.network), []))), toset(["host", "path", "priority"]))) > 0
  }

  # Unset priorities hash into 10000-49999, so explicit ones (1-9999) are always evaluated first.
  route_priority = {
    for d, r in local.routes : d => r.explicit != 0 ? r.explicit : parseint(substr(sha256("${r.host}${r.path}"), 0, 4), 16) % 40000 + 10000
  }

  route_keys  = { for d, r in local.routes : d => "${r.host}${r.path}" }
  route_hosts = [for d, r in local.routes : r.host]
  route_errors = concat(
    [for d, r in local.routes : "applications/${d}/terraform: network.host must be a lowercase DNS name" if !can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", r.host))],
    [for d, r in local.routes : "applications/${d}/terraform: network.path must start with / and must not end with / (except /)" if !can(regex("^(/|(/[A-Za-z0-9._~-]+)+)$", r.path))],
    [for d, r in local.routes : "applications/${d}/terraform: network.priority must be an integer between 1 and 9999" if r.explicit != 0 && !(r.explicit >= 1 && r.explicit <= 9999 && floor(r.explicit) == r.explicit)],
    [for d, k in local.route_keys : "applications/${d}/terraform: ${k} is also routed by ${join(", ", [for o, ok in local.route_keys : o if ok == k && o != d])}" if length([for o, ok in local.route_keys : o if ok == k]) > 1],
    [for d, p in local.route_priority : "applications/${d}/terraform: listener priority ${p} is also used by ${join(", ", [for o, op in local.route_priority : o if op == p && o != d])}; set network.priority" if length([for o, op in local.route_priority : o if op == p]) > 1],
    [for d, r in local.routes : "applications/${d}/terraform: host ${r.host} is shared with another application, so network.priority must be set to order the rules" if r.explicit == 0 && length([for h in local.route_hosts : h if h == r.host]) > 1],
  )

  applications = {
    for d, a in local.apps : d => {
      repository = try(tostring(a.base.image.repository), "")
      runtime    = try(tostring(a.base.runtime.type), "")
    } if a.enabled && a.has_base
  }
}

module "merge" {
  source = "../deep-merge"

  base     = try(local.apps[var.application].base, {})
  override = try(local.apps[var.application].override, {})
}

locals {
  selected = var.application != null && contains(keys(local.apps), coalesce(var.application, "-"))
  app_path = "applications/${coalesce(var.application, "-")}/terraform"
  m        = module.merge.merged

  pipeline_tag = trimspace(var.image_tag)
  config_tag   = try(tostring(local.apps[var.application].override.image.tag), "")
  merged_tag   = try(tostring(local.m.image.tag), "")
  image_tag    = local.tag_source == "pipeline" ? (local.pipeline_tag != "" ? local.pipeline_tag : local.merged_tag) : local.config_tag

  application = var.application == null ? null : {
    name                     = var.application
    runtime                  = try(tostring(local.m.runtime.type), "")
    repository               = try(tostring(local.m.image.repository), "")
    image_tag                = local.image_tag
    port                     = try(tonumber(local.m.container.port), 0)
    health_check_command     = try(tolist(local.m.container.health_check_command), null)
    health_check_path        = try(tostring(local.m.container.health_check_path), null)
    readonly_root_filesystem = try(tobool(local.m.container.readonly_root_filesystem), null)
    cpu                      = try(tonumber(local.m.resources.cpu), 0)
    memory                   = try(tonumber(local.m.resources.memory), 0)
    replicas                 = try(tonumber(local.m.deployment.replicas), 0)
    namespace                = try(tostring(local.m.deployment.namespace), var.application)
    autoscaling_enabled      = try(local.m.deployment.autoscaling, null) != null
    autoscaling_min          = try(tonumber(local.m.deployment.autoscaling.min), 0)
    autoscaling_max          = try(tonumber(local.m.deployment.autoscaling.max), 0)
    environment              = { for k, v in try(local.m.environment, {}) : k => tostring(v) if can(tostring(v)) }
    secrets                  = { for k, v in try(local.m.secrets, {}) : k => tostring(v) if can(tostring(v)) }
    network = !contains(keys(local.routes), var.application) ? null : {
      host     = local.routes[var.application].host
      path     = local.routes[var.application].path
      priority = local.route_priority[var.application]
    }

    # Optional ECS settings. Every default equals what the service stack did before these
    # keys existed, so an application that sets none of them plans exactly as it did.
    ephemeral_storage_gb              = try(tonumber(local.m.resources.ephemeral_storage_gb), null)
    architecture                      = try(tostring(local.m.resources.architecture), "X86_64")
    autoscaling_cpu_target            = try(tonumber(local.m.deployment.autoscaling.cpu_target), 70)
    autoscaling_memory_target         = try(tonumber(local.m.deployment.autoscaling.memory_target), 70)
    autoscaling_scale_in_cooldown     = try(tonumber(local.m.deployment.autoscaling.scale_in_cooldown), 300)
    autoscaling_scale_out_cooldown    = try(tonumber(local.m.deployment.autoscaling.scale_out_cooldown), 60)
    minimum_healthy_percent           = try(tonumber(local.m.deployment.minimum_healthy_percent), 100)
    maximum_percent                   = try(tonumber(local.m.deployment.maximum_percent), 200)
    circuit_breaker                   = try(tobool(local.m.deployment.circuit_breaker), true)
    health_check_grace_period_seconds = try(tonumber(local.m.deployment.health_check_grace_period_seconds), 60)
    platform_version                  = try(tostring(local.m.deployment.platform_version), "LATEST")
    execute_command                   = try(tobool(local.m.deployment.execute_command), null)
    log_retention_days                = try(tonumber(local.m.deployment.log_retention_days), null)
    capacity_providers = {
      for k, v in try(local.m.deployment.capacity_providers, {}) : k => {
        weight = try(tonumber(v.weight), 1)
        base   = try(tonumber(v.base), 0)
      }
    }

    target_group = {
      deregistration_delay = try(tonumber(local.m.network.target_group.deregistration_delay), 30)
      slow_start           = try(tonumber(local.m.network.target_group.slow_start), 0)
      stickiness_enabled   = try(tobool(local.m.network.target_group.stickiness.enabled), false)
      stickiness_duration  = try(tonumber(local.m.network.target_group.stickiness.duration), 86400)
      health_check = {
        path                = try(tostring(local.m.network.target_group.health_check.path), null)
        matcher             = try(tostring(local.m.network.target_group.health_check.matcher), "200-399")
        interval            = try(tonumber(local.m.network.target_group.health_check.interval), 15)
        timeout             = try(tonumber(local.m.network.target_group.health_check.timeout), 5)
        healthy_threshold   = try(tonumber(local.m.network.target_group.health_check.healthy_threshold), 2)
        unhealthy_threshold = try(tonumber(local.m.network.target_group.health_check.unhealthy_threshold), 3)
      }
    }

    # Extra ingress to the tasks beyond ALB → container.port (which the core ECS group allows).
    ingress_rules = [
      for r in try(tolist(local.m.network.security_group.ingress), []) : {
        port        = try(tonumber(r.port), 0)
        protocol    = lower(try(tostring(r.protocol), "tcp"))
        cidr_blocks = try([for c in r.cidr_blocks : tostring(c)], [])
        description = try(tostring(r.description), "")
      }
    ]

    iam_policy_arns = try([for a in local.m.iam.policy_arns : tostring(a)], [])
    iam_statements = [
      for s in try(tolist(local.m.iam.statements), []) : {
        sid       = try(tostring(s.sid), null)
        effect    = try(tostring(s.effect), "Allow")
        actions   = try([for a in s.actions : tostring(a)], [])
        resources = try([for x in s.resources : tostring(x)], [])
        conditions = [
          for c in try(tolist(s.conditions), []) : {
            test     = try(tostring(c.test), "")
            variable = try(tostring(c.variable), "")
            values   = try([for v in c.values : tostring(v)], [])
          }
        ]
      }
    ]
  }

  log_retention_values = [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653]
  open_cidrs           = ["0.0.0.0/0", "::/0"]
  is_int               = { for k, v in(local.a == null ? {} : {
    ephemeral_storage_gb = coalesce(local.a.ephemeral_storage_gb, 21)
    cpu_target           = local.a.autoscaling_cpu_target
    memory_target        = local.a.autoscaling_memory_target
  }) : k => floor(v) == v }

  fargate_memory = {
    "256"   = [512, 1024, 2048]
    "512"   = range(1024, 4097, 1024)
    "1024"  = range(2048, 8193, 1024)
    "2048"  = range(4096, 16385, 1024)
    "4096"  = range(8192, 30721, 1024)
    "8192"  = range(16384, 61441, 4096)
    "16384" = range(32768, 122881, 8192)
  }

  secret_arn     = "^arn:aws[a-z-]*:(secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+|ssm:[a-z0-9-]+:[0-9]{12}:parameter/.+)$"
  env_var_name   = "^[A-Za-z_][A-Za-z0-9_]*$"
  a              = local.application
  runtime_valid  = local.a == null ? false : contains(["ecs", "eks"], local.a.runtime)
  raw_env        = try(local.m.environment, {})
  raw_secrets    = try(local.m.secrets, {})
  raw_env_keys   = can(keys(local.raw_env)) ? keys(local.raw_env) : []
  raw_secret_ids = can(keys(local.raw_secrets)) ? keys(local.raw_secrets) : []

  service_errors = var.application == null ? [] : !local.selected ? ["${local.app_path} does not exist"] : !local.apps[var.application].enabled ? concat(
    local.app_errors[var.application],
    ["${local.app_path}/${var.environment}.yaml does not exist; the application is not enabled in ${var.environment}"],
    ) : concat(
    local.app_errors[var.application],
    local.runtime_valid ? [] : ["${local.app_path}: runtime.type must be ecs or eks"],
    local.a.runtime != "eks" ? [] : ["${local.app_path}: eks applications are deployed by helm-project (helmfile or Argo CD); Terraform manages only their ECR repository"],
    !local.runtime_valid || try(tobool(local.core[local.a.runtime].enabled), false) ? [] : ["${local.app_path}: runtime ${local.a.runtime} is not enabled in ${local.env_path}/core.yaml"],
    local.a.port >= 1 && local.a.port <= 65535 && floor(local.a.port) == local.a.port ? [] : ["${local.app_path}: container.port must be an integer between 1 and 65535"],
    local.a.runtime != "ecs" || contains(try(local.fargate_memory[tostring(local.a.cpu)], []), local.a.memory) ? [] : ["${local.app_path}/${var.environment}.yaml: resources.cpu ${local.a.cpu} / resources.memory ${local.a.memory} is not a valid Fargate size"],
    local.a.replicas >= 1 && floor(local.a.replicas) == local.a.replicas ? [] : ["${local.app_path}/${var.environment}.yaml: deployment.replicas must be an integer of at least 1"],
    !local.a.autoscaling_enabled || (local.a.autoscaling_min >= 1 && local.a.autoscaling_max >= local.a.autoscaling_min && floor(local.a.autoscaling_min) == local.a.autoscaling_min && floor(local.a.autoscaling_max) == local.a.autoscaling_max) ? [] : ["${local.app_path}: deployment.autoscaling needs integers min >= 1 and max >= min"],
    can(keys(local.raw_env)) ? [] : ["${local.app_path}: environment must be a map"],
    can(keys(local.raw_secrets)) ? [] : ["${local.app_path}: secrets must be a map"],
    [for k in local.raw_env_keys : "${local.app_path}: environment.${k} must be a string, number or bool" if !can(tostring(local.raw_env[k]))],
    [for k in local.raw_env_keys : "${local.app_path}: environment variable name ${k} is invalid" if !can(regex(local.env_var_name, k))],
    [for k in local.raw_secret_ids : "${local.app_path}: secrets.${k} must be a Secrets Manager or SSM parameter ARN" if !can(regex(local.secret_arn, try(tostring(local.raw_secrets[k]), "")))],
    [for k in local.raw_secret_ids : "${local.app_path}: secret name ${k} is invalid" if !can(regex(local.env_var_name, k))],
    [for k in local.raw_secret_ids : "${local.app_path}: ${k} is both an environment variable and a secret" if contains(local.raw_env_keys, k)],
    local.tag_source != "config" || local.config_tag != "" ? [] : ["${local.app_path}/${var.environment}.yaml: image.tag is required, ${var.environment} deploys only the tag pinned in Git"],
    local.tag_source != "config" || local.pipeline_tag == "" || local.config_tag == "" || local.pipeline_tag == local.config_tag ? [] : ["IMAGE_TAG ${local.pipeline_tag} does not match image.tag ${local.config_tag} in ${local.app_path}/${var.environment}.yaml"],
    local.tag_source != "pipeline" || local.image_tag != "" ? [] : ["image tag is required: pass IMAGE_TAG or set image.tag in ${local.app_path}/${var.environment}.yaml"],
    local.image_tag != "latest" ? [] : ["image tag must not be latest"],
    local.image_tag == "" || can(regex("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$", local.image_tag)) ? [] : ["image tag ${local.image_tag} is not a valid tag"],
    [for p in module.merge.too_deep : "${local.app_path}: ${p} is nested deeper than the merge supports"],
    local.a.runtime != "ecs" ? [] : local.ecs_errors,
  )

  tg = local.a == null ? null : local.a.target_group
  hc = local.a == null ? null : local.a.target_group.health_check

  ecs_errors = local.a == null ? [] : concat(
    local.a.ephemeral_storage_gb == null || try(local.a.ephemeral_storage_gb >= 21 && local.a.ephemeral_storage_gb <= 200 && local.is_int.ephemeral_storage_gb, false) ? [] : ["${local.app_path}: resources.ephemeral_storage_gb must be an integer between 21 and 200"],
    contains(["X86_64", "ARM64"], local.a.architecture) ? [] : ["${local.app_path}: resources.architecture must be X86_64 or ARM64"],
    local.a.minimum_healthy_percent >= 0 && local.a.minimum_healthy_percent <= 100 ? [] : ["${local.app_path}: deployment.minimum_healthy_percent must be between 0 and 100"],
    local.a.maximum_percent >= 100 && local.a.maximum_percent <= 200 ? [] : ["${local.app_path}: deployment.maximum_percent must be between 100 and 200"],
    local.a.health_check_grace_period_seconds >= 0 && local.a.health_check_grace_period_seconds <= 2147483647 ? [] : ["${local.app_path}: deployment.health_check_grace_period_seconds must not be negative"],
    can(regex("^(LATEST|[0-9]+\\.[0-9]+\\.[0-9]+)$", local.a.platform_version)) ? [] : ["${local.app_path}: deployment.platform_version must be LATEST or a version such as 1.4.0"],
    local.a.log_retention_days == null || contains(local.log_retention_values, local.a.log_retention_days) ? [] : ["${local.app_path}: deployment.log_retention_days must be one of ${join(", ", local.log_retention_values)}"],
    local.a.autoscaling_cpu_target >= 1 && local.a.autoscaling_cpu_target <= 100 && local.is_int.cpu_target ? [] : ["${local.app_path}: deployment.autoscaling.cpu_target must be an integer between 1 and 100"],
    local.a.autoscaling_memory_target >= 1 && local.a.autoscaling_memory_target <= 100 && local.is_int.memory_target ? [] : ["${local.app_path}: deployment.autoscaling.memory_target must be an integer between 1 and 100"],
    local.a.autoscaling_scale_in_cooldown >= 0 && local.a.autoscaling_scale_out_cooldown >= 0 ? [] : ["${local.app_path}: deployment.autoscaling cooldowns must not be negative"],
    [for k in keys(local.a.capacity_providers) : "${local.app_path}: deployment.capacity_providers.${k} must be FARGATE or FARGATE_SPOT" if !contains(["FARGATE", "FARGATE_SPOT"], k)],
    [for k, v in local.a.capacity_providers : "${local.app_path}: deployment.capacity_providers.${k} needs weight >= 0 and base >= 0" if v.weight < 0 || v.base < 0],
    length(local.a.capacity_providers) == 0 || sum(concat([0], [for v in values(local.a.capacity_providers) : v.weight])) > 0 ? [] : ["${local.app_path}: deployment.capacity_providers needs at least one weight above 0"],
    local.tg.deregistration_delay >= 0 && local.tg.deregistration_delay <= 3600 ? [] : ["${local.app_path}: network.target_group.deregistration_delay must be between 0 and 3600"],
    local.tg.slow_start == 0 || (local.tg.slow_start >= 30 && local.tg.slow_start <= 900) ? [] : ["${local.app_path}: network.target_group.slow_start must be 0 or between 30 and 900"],
    local.tg.stickiness_duration >= 1 && local.tg.stickiness_duration <= 604800 ? [] : ["${local.app_path}: network.target_group.stickiness.duration must be between 1 and 604800"],
    local.hc.path == null || can(regex("^/", coalesce(local.hc.path, "-"))) ? [] : ["${local.app_path}: network.target_group.health_check.path must start with /"],
    can(regex("^[0-9]{3}([-,][0-9]{3})*$", local.hc.matcher)) ? [] : ["${local.app_path}: network.target_group.health_check.matcher must be HTTP codes such as 200 or 200-399"],
    local.hc.interval >= 5 && local.hc.interval <= 300 ? [] : ["${local.app_path}: network.target_group.health_check.interval must be between 5 and 300"],
    local.hc.timeout >= 2 && local.hc.timeout <= 120 && local.hc.timeout < local.hc.interval ? [] : ["${local.app_path}: network.target_group.health_check.timeout must be between 2 and 120 and less than interval"],
    local.hc.healthy_threshold >= 2 && local.hc.healthy_threshold <= 10 && local.hc.unhealthy_threshold >= 2 && local.hc.unhealthy_threshold <= 10 ? [] : ["${local.app_path}: network.target_group.health_check thresholds must be between 2 and 10"],
    [for i, r in local.a.ingress_rules : "${local.app_path}: network.security_group.ingress[${i}].port must be between 1 and 65535" if !(r.port >= 1 && r.port <= 65535 && floor(r.port) == r.port)],
    [for i, r in local.a.ingress_rules : "${local.app_path}: network.security_group.ingress[${i}].protocol must be tcp or udp" if !contains(["tcp", "udp"], r.protocol)],
    [for i, r in local.a.ingress_rules : "${local.app_path}: network.security_group.ingress[${i}].cidr_blocks must list at least one valid CIDR" if length(r.cidr_blocks) == 0 || !alltrue([for c in r.cidr_blocks : can(cidrhost(c, 0))])],
    [for i, r in local.a.ingress_rules : "${local.app_path}: network.security_group.ingress[${i}] must not open the tasks to 0.0.0.0/0 or ::/0; public traffic goes through the ALB" if length(setintersection(toset(r.cidr_blocks), toset(local.open_cidrs))) > 0],
    [for a in local.a.iam_policy_arns : "${local.app_path}: iam.policy_arns ${a} is not an IAM policy ARN" if !can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+$", a))],
    [for a in local.a.iam_policy_arns : "${local.app_path}: iam.policy_arns must not attach AdministratorAccess" if endswith(a, ":policy/AdministratorAccess")],
    [for i, st in local.a.iam_statements : "${local.app_path}: iam.statements[${i}].effect must be Allow or Deny" if !contains(["Allow", "Deny"], st.effect)],
    [for i, st in local.a.iam_statements : "${local.app_path}: iam.statements[${i}] needs actions and resources" if length(st.actions) == 0 || length(st.resources) == 0],
    [for i, st in local.a.iam_statements : "${local.app_path}: iam.statements[${i}] must not allow action *" if contains(st.actions, "*")],
  )

  errors = distinct(concat(
    local.environment_errors,
    local.global_app_errors,
    var.application == null ? flatten(values(local.app_errors)) : [],
    local.service_errors,
  ))
}
