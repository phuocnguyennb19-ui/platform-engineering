# CLAUDE.md — terraform

The project policy is the root `CLAUDE.md` (two layers — `modules/` and `stacks/` — never a
third). This file adds what is specific to `terraform/`; module rules are in
`modules/CLAUDE.md`. `README.md` holds the full configuration contract. Commands run from
`terraform/`.

## Layout

```text
../environments/<env>/terraform/{environment,core,backend}.yaml   (values, not here)
../applications/<app>/terraform/{app,<env>}.yaml
schema/       JSON schemas for the two value directories above
stacks/core/      Terraform root — shared infrastructure; knows no application
stacks/registry/  Terraform root — ECR per image.repository of apps enabled in the environment
stacks/service/   Terraform root — one ECS application per state; EKS apps belong to kubernetes/
shared/       stack-internal modules used by all three roots (config, deep-merge)
tests/        one test root: *.tftest.hcl + fixtures/ for every shared module
modules/      L1 reusable AWS modules (modules/CLAUDE.md)
examples/     module examples
```

Stacks source modules by relative path, `../../modules/<name>`. There are no release tags: a
module change is in every stack's next plan, in every environment.

## Rules

- **No application in Terraform.** Adding or changing an application is YAML under
  `../applications/<app>/terraform/`. A change that needs Terraform, CI or core edits for one application is
  a design defect — fix the generic code instead.
- **Tests live in `tests/`, never beside a shared module.** Each `run` block names its module with
  `module { source = "../shared/<name>" }`, and fixtures are `tests/fixtures/<case>/`.
- **Each YAML file owns its keys.** `shared/config` rejects a key in the wrong file; add a new key
  there (validation and mapping), in `schema/`, and in `README.md` together.
- **Never guess environment values.** `account.id`, backend `bucket`/`region`, pinned image tags,
  `eks.access_entries`, and the `.sops.yaml` recipients stay empty until the user supplies them;
  the plan names what is missing.
- **Paths:** each stack reads `config_root = "${path.root}/../../../environments"` (`shared/config`
  reads `<dir>/terraform/{environment,core,backend}.yaml` and picks the folder whose `environment.yaml`
  says `environment: <ENVIRONMENT>` — `production` lives in `environments/prod/terraform/`), `applications_root = "${path.root}/../../../applications"` (repository
  root: `shared/config` reads `<app>/terraform/*.yaml`) and `../../shared/config`. Moving a stack means
  updating both, `STACK_DIR` in `ci/terraform/platform.yml`, and the loops in its `validate` job
  and in the root `Makefile`.
- **Pins:** image digests, `YQ_APK`/`AWS_CLI_APK` (must match the Alpine release in `TF_IMAGE`),
  `ci/terraform/requirements.txt` hashes and crane checksums move together with the thing they
  pin.
- **State addresses:** keep module and resource names stable; a rename needs a `moved` block, and
  removing a resource that must survive needs `removed { lifecycle { destroy = false } }`. State
  keys (`<env>/core/core.tfstate`, `<env>/registry/registry.tfstate`,
  `<env>/services/<app>.tfstate`) do not depend on directory names.

## Environments and CI

Environments here are `dev | staging | production` — never `prod` (that is Helm's name).
`ENVIRONMENT` selects `../environments/<env>/terraform/` and, through `allowed_account_ids`, the only account a
run may touch.

- Plans and applies run in GitLab (`ci/terraform/platform.yml`): `plan:*` saves `tfplan`,
  `apply:*` applies exactly that file under `resource_group`. Apply is manual except
  `apply:registry` on a dev push, which refuses a plan that deletes anything, and dev
  `apply:service`. Keep all of that, the OIDC role split (`TF_PLAN_ROLE_ARN` read-only,
  `TF_APPLY_ROLE_ARN` protected), `check-inputs` and `.tfp-guard`.
- `stacks/core` is shared by every application and by Helm (cluster name, IRSA roles, KMS, ECR
  mirror): any change there is at least HIGH. So is any change to a module a stack uses.

## Validate

`make stacks-validate` from the repository root, or:

```bash
yamllint --strict ../environments/*/terraform ../applications/*/terraform
terraform fmt -check -recursive stacks shared tests
(cd tests && terraform init -backend=false -test-directory=. && terraform test -test-directory=.)
for d in stacks/core stacks/registry stacks/service; do (cd $d && terraform init -backend=false && terraform validate); done
```

Terraform >= 1.10 is required (S3 `use_lockfile`). Root-level behaviour is verified with
`terraform test` and `mock_provider` in a scratch copy, never by planning against AWS from here.
