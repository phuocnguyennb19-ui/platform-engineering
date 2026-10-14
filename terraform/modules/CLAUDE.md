# CLAUDE.md — terraform/modules

22 reusable AWS Terraform modules. They are the L1 layer of `terraform/`; the L2 layer is
`terraform/stacks/` with its YAML configuration (`../CLAUDE.md`).

| | Owns | Never contains |
|---|---|---|
| **modules/** (here) | reusable infrastructure modules, typed Terraform inputs, module contract tests | YAML parsing, developer configuration, environment names or policy, state, deployment CI |
| **stacks/** + `environments/`, `../applications/*/terraform/`, `shared/` | YAML config, validation, defaults, environment policy, composition, state | reusable modules |

Do not create a third layer to solve an architectural problem, and do not move
responsibilities across this line. Stacks source each module as `../../modules/<name>`: a
capability they need is added here and is in every stack's next plan, in every environment —
there is no tag between a module change and production.

`terraform/` holds no root `.tf`; CI fails if one appears. Earlier callers outside this repository
(`ecs-platform`, `dev-app-no01`) pin tags of the former `terraform-module` repository, which this
repository does not publish.

## Commands

Run from `terraform/`. Nothing needs AWS credentials; `ci/terraform/modules.yml` runs all of it
(`make modules-validate` from the repository root).

```bash
terraform fmt -check -recursive modules examples
for d in modules/*/ examples/complete/; do (cd "$d" && terraform init -backend=false && terraform validate); done

# contract tests — Terraform >= 1.7 (mock_provider); module CI validates on 1.5.7
cd modules/<name> && terraform init -backend=false && terraform test
```

## Rules for a module

- **Typed inputs only.** Never `yamldecode`, `file()` of config, `global_config`, or a
  `type = any` bag. Use precise object types with `optional()` defaults. CI rejects YAML.
- **No environment knowledge.** A module never branches on `dev`/`prod`. It exposes the knob
  (`deletion_protection_enabled`), defaults it to the safe value, and the stacks decide.
- **Validation = infrastructure capability only** (AWS limits, impossible combinations,
  dangerous grants). Whether a config is allowed in an environment is platform policy.
- **Derived values live in `locals`** and are passed to the upstream module from there, so the
  contract tests can assert on exactly what upstream receives (tests cannot see inside a child
  module).
- **Decide `count` / `for_each` from known values.** An ARN created in the same apply is unknown
  at plan: add an explicit bool beside it (`alb.enable_https`, `ecs-service.enable_load_balancer`,
  `ecs-cluster.service_connect_namespace_name`).
- No provider blocks, no `depends_on` between modules; module directories are kebab-case (the
  six data/edge modules keep their snake_case names).
- Terraform `>= 1.5.7`, AWS provider `>= 5.80.0, < 6.0.0` in every `versions.tf`.

## Changing a module

1. Read its `README.md`, `variables.tf` and `tests/` first — the input may exist.
2. Find every stack that sources it: `grep -rn 'modules/<name>"' ../stacks`.
3. Change `variables.tf` / `locals.tf` / `main.tf` / `outputs.tf`; add a `tests/*.tftest.hcl`
   case for the new behaviour and for the input it must reject.
4. Update the module's `README.md` and its snippet in `../examples/README.md`.
5. fmt, validate, test (above), then `make stacks-validate`. Add a `../CHANGELOG.md` entry.

A removed/renamed input, a renamed module directory or a changed output must change its callers
in `stacks/` in the same commit. A module change used by a stack is HIGH (root `CLAUDE.md`):
its plan in every environment is what gets reviewed.
