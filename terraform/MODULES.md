# terraform/modules

Reusable AWS Terraform modules under `terraform/modules/`. Modules take typed variables and
know nothing about YAML, environments or state. No environment lives here.

Commands below run from `terraform/`.

`terraform/stacks/` consumes them: it turns a developer's YAML (`infra-base/terraform/environments/`,
`applications/<app>/terraform/`) into module inputs and sources each module by relative path inside
this one repository. `terraform/modules` owns infrastructure capability; `terraform/stacks`
owns configuration, policy, composition and state; `k8s/` holds Helm.

```
terraform/stacks          YAML → mapping → policy → composition → state + CI
        │
        │  source = "../../modules/<name>"
        ▼
terraform/modules         modules/ — no tags; a change reaches every stack's next plan
```

## No root composition

Since `v2.0.0` `terraform/` holds no root `.tf`: the YAML-driven engine that
used to live here is gone, and composition belongs to the platform. Callers of
that engine (`ecs-platform`, `dev-app-no01`) must pin `v1.3.0` or earlier.

## Usage

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name       = "platform-dev"
  cidr_block = "10.0.0.0/16"

  tags = { Environment = "dev" }
}
```

Always pin a tag. A `ref` pointing at a branch means an upstream commit can change
a plan you did not ask for.

Start from [`examples/`](examples/): [`examples/README.md`](examples/README.md)
has a call snippet for every module, and
[`examples/complete/`](examples/complete/) is a runnable environment showing how
they wire together.

## Modules

All 22 modules take typed inputs; none reads a file.

| Module | Inputs | Required | Upstream |
|---|---|---|---|
| `acm` | 8 | 2 | `terraform-aws-modules/acm/aws` 5.2.0 |
| `alb` | 26 | 4 | `terraform-aws-modules/alb/aws` 9.17.0 |
| `cloudwatch` | 10 | 1 | `hashicorp/aws` resources |
| `ec2` | 7 | 2 | `terraform-aws-modules/ec2-instance/aws` 5.8.0 |
| `ecr` | 5 | 1 | `hashicorp/aws` resources |
| `ecs-cluster` | 15 | 1 | `terraform-aws-modules/ecs/aws//modules/cluster` 5.11.4 |
| `ecs-service` | 43 | 5 | `terraform-aws-modules/ecs/aws//modules/service` 5.11.4 |
| `eks` | 23 | 4 | `terraform-aws-modules/eks/aws` 20.37.2 |
| `elasticache` | 27 | 3 | `hashicorp/aws` resources |
| `iam` | 12 | 1 | `hashicorp/aws` resources |
| `kms` | 3 | 1 | `hashicorp/aws` resources |
| `lambda` | 6 | 1 | `terraform-aws-modules/lambda/aws` 7.21.1 |
| `rds` | 36 | 6 | `terraform-aws-modules/rds/aws` 6.13.1 |
| `route53` | 7 | 1 | `hashicorp/aws` resources |
| `security-groups` | 21 | 3 | `hashicorp/aws` resources |
| `vpc` | 25 | 2 | `terraform-aws-modules/vpc/aws` 5.21.0 |
| `dynamodb` | 3 | 1 | `terraform-aws-modules/dynamodb-table/aws` 4.1.0 |
| `s3` | 10 | 1 | `terraform-aws-modules/s3-bucket/aws` 4.2.1 |
| `secrets_manager` | 3 | 1 | `terraform-aws-modules/secrets-manager/aws` 1.1.0 |
| `sns` | 3 | 1 | `terraform-aws-modules/sns/aws` 6.1.1 |
| `sqs` | 3 | 1 | `terraform-aws-modules/sqs/aws` 4.2.1 |
| `waf` | 8 | 1 | `terraform-aws-modules/wafv2/aws` 1.1.0 |

Every module has its own `README.md` with the full input and output tables.

## Requirements

| | |
|---|---|
| Terraform | `>= 1.5.7, < 2.0.0` |
| AWS provider | `>= 5.80.0, < 6.0.0` |

The provider is capped below 6.0 because the upstream module set pinned above is
the newest line that supports the 5.x provider. Moving to 6.x requires the next
major of every one of those modules — a coordinated upgrade, not a version bump.

## Conventions

- **Module directories are kebab-case** (`ecs-cluster`), module block labels are
  snake_case (`module "ecs_cluster"`).
- **Typed inputs, not config files.** A module never reads a file from disk and
  never calls `yamldecode`. Whoever calls it decides where values come from.
- **No `depends_on` between modules.** Ordering is expressed by one module's
  output feeding another's input, so Terraform derives the graph itself.
- **No provider blocks in modules.** The provider is configured once, by the
  caller's root; a module that declares one cannot be used twice in the same
  configuration.
- **Optional inputs carry defaults.** If a module can pick a safe value, it does,
  so a caller writes only what is genuinely a decision.

## Validating a change

None of this needs AWS credentials or a state bucket; `.gitlab-ci.yml` runs all of it:

```bash
terraform fmt -check -recursive

# every module and the complete example compile (Terraform 1.5.7)
for d in modules/*/ examples/complete/; do (cd "$d" && terraform init -backend=false && terraform validate); done

# contract tests: plan-only, mocked provider (Terraform >= 1.7)
cd modules/s3 && terraform init -backend=false && terraform test
```

A module's `tests/*.tftest.hcl` pins its contract — secure defaults, derived names, the
mapping onto the upstream module, and the inputs it must reject. CI also fails if a module
reads YAML or if `.tf` reappears at the repository root.

## Releasing

Consumers pin a tag, so a change is not visible to them until one is cut:

```bash
git tag v2.0.1 && git push origin v2.0.1
```

Record every release in `CHANGELOG.md`, with migration notes for a major one.

Bump the minor for a new module or a new optional input; bump the major for a
renamed or removed input, a renamed module directory, or a changed output — each
of those breaks a caller's plan.

## Known gaps

- `examples/complete` does not cover `ecs-cluster`, `ecs-service` or the six data/edge modules;
  their contract tests and the `terraform/stacks` plans exercise them.
- `security-groups` opens one `application_port` from the ALB and between tasks, so services
  share one container port.
- Terraform 1.5.7 stays the deployment CLI; `terraform test` with mocks needs 1.7+, so tests run
  on a separate image (`TF_TEST_VERSION`).
