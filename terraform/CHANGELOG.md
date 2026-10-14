# Changelog

Consumers pin a tag. Major versions break a caller's plan; read the migration notes first.

## Unreleased

Fixed:

- `ec2`: **every plan failed.** The module tags each volume on its own `root_block_device` /
  `ebs_block_device` block, and the upstream `ec2-instance` module sets `volume_tags` unless
  `enable_volume_tags = false`; the AWS provider rejects the two together with "Conflicting
  configuration arguments". The module now turns `volume_tags` off, since it tags the volumes
  itself. No consumer was affected — `platform-engine` does not compose `ec2` — and the module's
  first contract test is what found it.

Added:

- Contract tests for the eight modules that had none: `ecr`, `kms`, `elasticache`, `cloudwatch`,
  `route53`, `ec2`, `lambda` and `acm`. Coverage is now 22 of 22 modules, 115 checks. The ECR
  lifecycle policy and encryption fallback, the KMS alias naming and the rotation that cannot be
  switched off, ElastiCache's cluster-mode and multi-AZ interlocks, every CloudWatch alarm
  notifying on OK as well as ALARM, Route53's alias/TTL interlock and public-versus-private zone
  switch, the EC2 AMI lookup running only when an instance needs it, and Lambda's package-source
  and VPC-attachment contracts. Behaviour unchanged apart from the `ec2` fix above.
  `acm`, `ec2` and `lambda` wrap upstream modules, which a contract test cannot see inside, so
  those assert the input contract and the module's own locals.

## v2.0.0 — 2026-09-21

**Breaking.** The library takes typed Terraform inputs only.

- `s3`, `sqs`, `sns`, `dynamodb`, `secrets_manager`, `waf` no longer read a YAML file or take
  `global_config` / `config_file` / `manual_config`. Each has a typed interface — see its
  `README.md`. They no longer derive names from an environment or project, and no longer
  switch behaviour on the environment name: the caller passes the name and the policy.
  - `s3`: `name` is the bucket name. ACLs are disabled (`BucketOwnerEnforced`), the bucket
    policy denies non-TLS and pre-1.2 TLS access, every public access block setting is on.
  - `sqs` / `sns` / `dynamodb`: a map keyed by short name under `name_prefix`. SNS topics are
    always encrypted (`alias/aws/sns` when no key is given). DynamoDB point-in-time recovery
    and deletion protection default to on.
  - `secrets_manager`: values never pass through Terraform unless `generate_password = true`;
    names are `<name_prefix>/<key>`.
  - `waf`: AWS managed rule groups by name plus an optional `rate_limit`, instead of raw rules.
- The repository root no longer holds a composition (`main.tf`, `locals.tf`, …). Composition
  and the YAML mapping belong to platform-engine. Callers of the old engine stay on `v1.3.0`.
- `ecs-service`: `tasks_iam_role_statements` is typed and rejects action `"*"` and
  `"<service>:*"` on resource `"*"`.

Added (no migration needed):

- `ecs-service.service_connect` — join ECS Service Connect for private service-to-service calls.
- `ecs-cluster.service_connect_namespace_name` — create the Cloud Map HTTP namespace; output
  `service_connect_namespace_arn`.
- `security-groups.allow_ecs_to_ecs` — task-to-task traffic on `application_port`, by security
  group reference.
- `eks.cluster_addons[*].irsa_role_key` — give an addon one of the module's own `irsa_roles`
  (e.g. the CloudWatch Observability addon); the ARN cannot be passed in, the role trusts the
  cluster's OIDC provider.

Fixed:

- `eks.cluster_addons[*].version` was never applied: the upstream module reads `addon_version`, so
  a pinned addon version was silently ignored and every addon tracked the default for the cluster's
  Kubernetes version. It is now passed through.
- Contract tests (`modules/*/tests/*.tftest.hcl`, Terraform ≥ 1.7) and `.gitlab-ci.yml`
  (fmt, typed-inputs guard, validate, test). Now covering `vpc`, `iam`, `rds` and `alb` as well:
  subnet derivation and the Kubernetes subnet tags, the permissions boundary on every role the
  module creates, the TLS-forcing parameter group per engine, and the ALB listener set.
- `alb.enable_http_redirect`: documented what `false` actually does — with HTTPS on it closes
  port 80 rather than serving application traffic there. Behaviour unchanged; the description
  said neither, and a test now pins it so it cannot become a plaintext listener by accident.

Migration: replace each legacy module call with its typed form (`examples/README.md` has one
per module), then `terraform plan` — a renamed resource needs a `moved` block in the caller.

## v1.3.0

- `ecs-service.enable_load_balancer` — an explicit bool beside `target_group_arn`, so a target
  group created in the same apply no longer fails the plan with "Invalid count argument".
- Root composition: optional `global.account_id` → provider `allowed_account_ids`.

## v1.2.1 and earlier

See the git history.
