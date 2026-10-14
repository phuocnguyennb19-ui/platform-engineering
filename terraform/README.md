# terraform

Terraform for the platform: environment configuration, application deployment configuration,
configuration validation, Terraform composition (`stacks/`), state layout and the deployment
pipeline (`ci/terraform/platform.yml`). Reusable AWS modules live beside it in `modules/` and
are sourced by relative path (`../../modules/<name>` from a stack) — no tags; a module change
reaches every stack's next plan. Helm lives in `k8s/` of the same repository.

Commands below run from `terraform/`.
Application repositories own source, Dockerfile and the image pipeline, and nothing else.

The Terraform code names no application. Applications exist only as YAML: adding one is a new
`applications/<app>/terraform/` directory at the repository root, with no Terraform, CI or core change.

```text
../infra-base/terraform/environments/<env>/environment.yaml    account, region, name prefix, tags, release policy
../infra-base/terraform/environments/<env>/core.yaml           shared infrastructure: vpc, ecs, eks, alb, dns, iam, ecr, logs
../infra-base/terraform/environments/<env>/backend.yaml        state bucket, region, encrypt, use_lockfile
../applications/<app>/terraform/app.yaml     identity, runtime, image repository, container defaults
../applications/<app>/terraform/<env>.yaml   per-environment values; its presence enables the app there
schema/*.schema.json                   JSON Schema for each of the five file kinds
stacks/core/                           Terraform root, layer 1: network, clusters, ALB, DNS, ACM, IAM, CloudWatch
stacks/registry/                       Terraform root, layer 2: one ECR repository per image.repository
stacks/service/                        Terraform root, layer 3: every ECS application (EKS apps: k8s/)
shared/
  config/                              YAML loading, validation, mapping to typed values; used by all three roots
  deep-merge/                          explicit deep merge (Terraform merge() is shallow)
tests/                                 every terraform test and its fixtures, for both shared modules
modules/                               reusable AWS modules (typed inputs, contract tests)
examples/                              module call snippets and a wired example
../ci/terraform/                       platform.yml, modules.yml, requirements.txt (included by ../.gitlab-ci.yml)
CLAUDE.md                              working rules for terraform/
```

`stacks/core/`, `stacks/registry/` and `stacks/service/` are the only directories Terraform runs
in. `shared/` holds platform-internal modules: they read this YAML, so they belong here and not
in `modules/`, whose modules never read configuration.

## Layers and state

| Layer | Root | Knows about applications | State key |
|---|---|---|---|
| core | `stacks/core/` | no | `<env>/core/core.tfstate` |
| registry | `stacks/registry/` | only `image.repository` of apps with `<env>.yaml` | `<env>/registry/registry.tfstate` |
| service | `stacks/service/` | one: `var.application` | `<env>/services/<app>.tfstate` |

Every `backend.tf` is `terraform { backend "s3" {} }`. Bucket, region, `encrypt` and
`use_lockfile` come from `../infra-base/terraform/environments/<env>/backend.yaml`; the key is derived per layer
and must not be set there. Locking is S3-native, hence Terraform >= 1.10. The service layer reads
the core and registry states from the same bucket.

Every root sets `allowed_account_ids` to `account.id` from `environment.yaml`, so a plan run with
another environment's credentials fails before it reads anything.

## Configuration contract

### environment.yaml

| Key | |
|---|---|
| `environment` | must equal the directory name |
| `account.id` | 12-digit account ID, quoted |
| `region.name` | AWS region |
| `name_prefix` | resource names are `<name_prefix>-<env>[-<app>]` |
| `tags` | map of strings, applied to every resource |
| `release.image_tag_source` | `pipeline` — `IMAGE_TAG` overrides YAML; `config` — only the tag in `<env>.yaml` deploys |
| `release.promote_from` | environment whose ECR this one copies images from |

`application`, `image`, `cpu`, `memory`, `resources`, `deployment` and `container` are rejected.

### core.yaml

`vpc` (required), `ecs.enabled` and `eks.enabled` (required),
`eks.addon_roles` (IRSA roles for the add-ons k8s/ installs — `external-dns`,
`cluster-autoscaler`, `velero` — each with its `service_accounts`; the role is
`<cluster>-irsa-<key>`, the policy is that project's documented minimum, and `velero` also gets
the bucket `<name>-velero-<account>`), `eks.access_entries` (IAM principals, such as the plan and apply roles, mapped to cluster access
policies — passed to the eks module as is),
`alb` (`enabled`, `internal`, `deletion_protection`, `ingress_cidrs`, `target_port_range` —
container ports the ALB may reach on ECS tasks besides 8080), `dns` (`zone_name`,
`create_zone`; enables Route53 and an ACM certificate for `zone` and `*.zone`), `iam` (`enabled`,
`ec2_instance_role`, `rds_monitoring_role`), `ecr` (`image_tag_mutability` must stay `IMMUTABLE`,
`force_delete`, `mirror_repositories` — third-party repositories such as `bitnami/postgresql`
that the k8s/ mirror job fills), `sops.kms_key` (a KMS key for the k8s/ SOPS
secrets; output `sops_kms_key_arn`), `logs.retention_days`, `alerts.subscriptions`. A public ALB requires `dns`,
because its HTTPS listener needs the certificate. Application keys are rejected.

### app.yaml

| Key | Required | |
|---|---|---|
| `application.name` | yes | must equal the directory name |
| `runtime.type` | yes | `ecs` or `eks`; the runtime must be enabled in `core.yaml`. An `eks` application only gets its ECR repository here — k8s/ (helmfile or Argo CD) deploys it, and a service plan for it is refused |
| `image.repository` | yes | ECR repository name; set here and nowhere else |
| `container.port` | yes | |
| `container.health_check_command` | no | ECS container health check |
| `container.health_check_path` | no | ECS target group health check |
| `container.readonly_root_filesystem` | no | ECS |

`resources`, `deployment`, `environment`, `secrets`, `cpu`, `memory` and `replicas` are rejected
here: they are per-environment.

### &lt;env&gt;.yaml

| Key | Required | |
|---|---|---|
| `resources.cpu` | ecs | CPU units, 1024 = 1 vCPU; a valid Fargate size |
| `resources.memory` | ecs | MiB, valid for the Fargate CPU |
| `deployment.replicas` | ecs | integer >= 1 |
| `deployment.autoscaling.min`, `.max` | no | enables autoscaling |
| `image.tag` | per policy | required where `release.image_tag_source` is `config` |
| `environment` | no | plain variables, never a credential |
| `secrets` | no | `NAME: <Secrets Manager or SSM parameter ARN>` |
| `runtime`, `container` | no | override `app.yaml` |
| `network` | no | routing, see below; may also be set in `app.yaml` |

For an `eks` application the file may be `{}`: its presence enables the ECR repository in that
environment. `application` and `image.repository` are rejected. A file whose name is not an environment
(`prd.yaml` beside `production`) is rejected rather than silently ignored.

### network

| Key | |
|---|---|
| `network.host` | lowercase DNS name; required when `network` is present |
| `network.path` | default `/`; `/api` matches `/api` and `/api/*` |
| `network.priority` | 1-9999, lower is evaluated first; required when two applications share a host |

For `ecs`, the service root creates an `ip` target group on `container.port`, a listener rule
on the core ALB (HTTPS when core has `dns`, otherwise HTTP), attaches the ECS service to it,
and, when the host is inside the core Route53 zone, an alias record. Health checks use
`container.health_check_path`, else `/`. Without an explicit priority the rule gets a
priority hashed from host and path into 10000-49999. Across every application enabled in an
environment, the plan rejects a duplicated host and path, a duplicated priority, and a shared
host without explicit priorities. `network` applies to `ecs` applications; EKS routing is the
k8s/ chart's Ingress.

The plan also fails when `network` is set but core has no ALB, when `container.port` is neither
8080 nor inside `alb.target_port_range`, or when the host is not covered by the core
certificate (the zone and one level below it).

### Merge rules

`<env>.yaml` is deep-merged over `app.yaml` by `shared/deep-merge`, not by `merge()`:

- the environment value wins;
- maps merge key by key, four levels deep — a map pair nested deeper is reported as an error;
- lists and scalars are replaced, never appended;
- a `null` in `<env>.yaml` means "not set" and keeps the `app.yaml` value;
- duplicate keys inside one file fail `yamllint` in CI (`yamldecode` silently keeps the last one).

## Validation

| Where | What |
|---|---|
| CI `config` | `yamllint --strict` (duplicate keys, syntax), every file against its JSON Schema |
| `shared/config`, every plan | files exist (`fileexists()` before `file()`), names match directories, account, region, backend, forbidden keys, unknown environment files, duplicate repositories, runtime valid and enabled, Fargate CPU/memory pairs, replicas, autoscaling, variable names, secret ARNs, image tag policy and `latest` |
| service plan | the ECR repository exists in this environment's registry state, the core state has the runtime's cluster, and the tag exists in ECR (`data.aws_ecr_image`) |

The schemas check shape and accept the empty `account.id`, `bucket` and `region` placeholders;
the plan rejects them. All errors are listed in one message.

## Images

The repository comes only from `app.yaml` and is looked up as
`registry.repository_urls[image.repository]`, never by application name. `IMAGE_REPOSITORY` is
refused by the pipeline.

| Environment | `image_tag_source` | Tag deployed |
|---|---|---|
| dev | `pipeline` | `IMAGE_TAG`, else `image.tag` from YAML |
| staging | `config` | `image.tag` in `staging.yaml`; `IMAGE_TAG`, if passed, must equal it |
| production | `config` | `image.tag` in `production.yaml`; `IMAGE_TAG`, if passed, must equal it |

Images are promoted by digest: `dev ECR → staging ECR → production ECR`. `promote:image` resolves
the tag's digest in the `promote_from` registry and copies that digest to this environment's
registry with `crane`; an existing tag holding another digest fails the job. Each environment
deploys only from its own registry, so production never pulls from dev. The registry layer grants
pull on each repository to the account of every environment that promotes from it.

## Pipeline

```text
MR, main, web (no APP_NAME):
  check-inputs, config, validate → plan:core, plan:registry → apply:core (manual, main)
                                                            → apply:registry (dev push: automatic, else manual)

application trigger (APP_NAME, ENVIRONMENT, IMAGE_TAG):
  check-inputs, config, validate → promote:image → plan:service → apply:service
                                   (staging, production)          (dev automatic, else manual; main only)
```

Every image is pinned by digest (`TF_IMAGE` and the `alpine` and `python` images), Alpine
packages by exact version (`YQ_APK`, `AWS_CLI_APK`, matching the Alpine release inside
`TF_IMAGE`), the validators by hash (`ci/terraform/requirements.txt`, compiled from
`ci/terraform/requirements.in` inside the pinned python image), and `crane` by version and SHA-256 for
x86_64 and arm64 runners. Moving `TF_IMAGE` to another Alpine release requires updating the two
package versions; `apk` fails the job rather than install something else.

`plan:*` keeps `tfplan` as an artifact and `apply:*` applies exactly that file. The automatic
`apply:registry` refuses a plan that deletes anything; run it from the web UI to apply a
deletion manually.

CI/CD variables, each scoped to the GitLab environment `dev`, `staging` or `production`:

| Variable | |
|---|---|
| `TF_PLAN_ROLE_ARN` | role trusting this project's GitLab OIDC token: read-only, state read/write, `ecr:DescribeImages`, EKS read access for Helm plans |
| `TF_APPLY_ROLE_ARN` | apply role, also used by `promote:image` (ECR push here, pull from the `promote_from` account). Make it protected, and protect the `production` environment with required approval |

The application project triggers this one, so its pipeline user needs Developer here, and
"Minimum role to use pipeline variables" in this project must allow Developer.

Application pipeline:

```yaml
trigger-platform:
  stage: deploy
  variables:
    APP_NAME: birthday-app
    ENVIRONMENT: dev
    IMAGE_TAG: $CI_COMMIT_SHORT_SHA
  trigger:
    project: $PLATFORM_PROJECT_PATH
    branch: main
    strategy: depend
```

## Adding an application

1. `../applications/<app>/terraform/app.yaml` and `../applications/<app>/terraform/dev.yaml`.
2. Merge to `main`. The dev pipeline plans the registry and applies it: the ECR repository
   `image.repository` now exists in dev.
3. The application pipeline builds, scans, pushes to that repository and triggers this project
   with `APP_NAME`, `ENVIRONMENT=dev`, `IMAGE_TAG`; the service root deploys it.
4. For staging and production add `staging.yaml` / `production.yaml` with `image.tag`, run the
   pipeline from the web UI with that `ENVIRONMENT` to create the repository, then trigger
   `APP_NAME` + `ENVIRONMENT`: the image is promoted and deployed after manual approval.

## First use of an environment

1. Create the state bucket (versioned, encrypted, public access blocked) and fill
   `backend.yaml`.
2. Set `account.id` in `environment.yaml`.
3. Create the plan and apply roles and the CI/CD variables above.
4. Apply `core`, then `registry`, then deploy services.

## Local

```bash
export ENVIRONMENT=dev
BACKEND="$PWD/../infra-base/terraform/environments/$ENVIRONMENT/backend.yaml"
init() {
  terraform init -backend-config="bucket=$(yq '.bucket' $BACKEND)" -backend-config="region=$(yq '.region' $BACKEND)" \
    -backend-config="encrypt=true" -backend-config="use_lockfile=true" -backend-config="key=$1"
}

(cd stacks/core && init "$ENVIRONMENT/core/core.tfstate" && terraform plan -var="environment=$ENVIRONMENT")
(cd stacks/registry && init "$ENVIRONMENT/registry/registry.tfstate" && terraform plan -var="environment=$ENVIRONMENT")
(cd stacks/service && init "$ENVIRONMENT/services/birthday-app.tfstate" && \
  terraform plan -var="environment=$ENVIRONMENT" -var="application=birthday-app" -var="image_tag=<commit-sha>")
```

Each root reads `../../../infra-base/terraform/environments` and `../../../applications`, so run Terraform inside `stacks/core/`, `stacks/registry/` or `stacks/service/`.
Validation without AWS:

```bash
yamllint --strict environments applications
terraform fmt -check -recursive stacks shared tests
(cd tests && terraform init -backend=false -test-directory=. && terraform test -test-directory=.)
for d in stacks/core stacks/registry stacks/service; do (cd $d && terraform init -backend=false && terraform validate); done
```
