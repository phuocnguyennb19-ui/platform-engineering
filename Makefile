SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ENV ?= dev
ENVS := dev staging prod
TERRAFORM ?= terraform
MODULE ?=
CHART := charts/application
APPS := $(filter-out _%,$(notdir $(patsubst %/k8s/,%,$(wildcard applications/*/k8s/))))   # applications/_template is not an app
STACKS := stacks/core stacks/registry stacks/service


.PHONY: help validate k8s-validate chart-lint argocd-render argocd-manifests argocd-guard platform-template \
        sops-check sops-recipients-check gitleaks modules-validate modules-fmt-check modules-typed-inputs modules-tf-validate modules-test \
        stacks-validate stacks-lint stacks-config stacks-fmt-check stacks-tf-validate stacks-test fmt check-env \
        new-app app-render app-values docs-reference docs-check \
        k8s-env-test k8s-env-schema k8s-preflight

help:
	@echo "make validate                    k8s-validate + k8s-env-test + modules-fmt-check + modules-typed-inputs + stacks-fmt-check (offline, no key)"
	@echo "kubernetes/"
	@echo "  make k8s-validate              chart-lint + argocd-render + sops-check"
	@echo "  make chart-lint                lint + render every kubernetes/$(CHART)/ci/*-values.yaml"
	@echo "  make argocd-render             render every app in $(ENVS) (applications/helmfile.yaml.gotmpl) + ApplicationSet layer check"
	@echo "  make argocd-manifests          client dry-run of kubernetes/argocd/root-app.yaml + bootstrap/"
	@echo "  make argocd-guard              root app + bootstrap/ cannot widen Argo CD (projects, kinds, sources)"
	@echo "  make platform-template ENV=    helmfile -e ENV -l layer=platform template (needs ENV age key)"
	@echo "  make sops-check                every environments/<env>/kubernetes/secrets.enc.yaml is SOPS-encrypted"
	@echo "  make sops-recipients-check     no age recipient shared across environments, none left as REPLACE_WITH_"
	@echo "                                 (not in validate until the key cutover in docs/20-runbooks/platform.md §2.1.1)"
	@echo "terraform/modules"
	@echo "  make modules-validate          fmt-check + typed-inputs + tf-validate + test"
	@echo "  make modules-test [MODULE=]    terraform test (Terraform >= 1.7)"
	@echo "terraform/stacks"
	@echo "  make stacks-validate           lint + config + fmt-check + tf-validate + test (Terraform >= 1.10)"
	@echo "make fmt                         terraform fmt -recursive terraform/"
	@echo "make gitleaks                    gitleaks detect --redact"
	@echo "applications / docs (docs/README.md)"
	@echo "  make new-app APP=<name> RUNTIME=eks|ecs   scaffold applications/<name> from applications/_template"
	@echo "  make app-render APP=<name> ENV=<env>   print one app's manifests (dev|staging|prod)"
	@echo "  make app-values APP=<name> ENV=<env>|all   final merged values of one app (every layer), JSON-like YAML"
	@echo "  make docs-reference           regenerate chart reference, schemas and applications/_template/k8s/<env>/values.yaml from the chart"
	@echo "  make docs-check               fail when the generated docs are stale"
	@echo "environments/<env>/kubernetes/cluster (cluster targets; tooling docs/clusters/README.md)"
	@echo "  make k8s-env-test              metadata rules + preflight tests against a stub kubectl (offline)"
	@echo "  make k8s-env-schema            yamllint + check-jsonschema of clusters/ and environments/"
	@echo "  make k8s-preflight CLUSTER=<name> [CONTEXT=] [KUBECONFIG_FILE=]   READ-ONLY checks of a live cluster"
	@echo "TERRAFORM=<cmd> overrides the terraform binary. Nothing here syncs, plans or applies — deploy: helmfile -e <env> -l name=<app> sync (root helmfile)."

validate: k8s-validate k8s-env-test modules-fmt-check modules-typed-inputs stacks-fmt-check

check-env:
	@case "$(ENV)" in dev|staging|prod) ;; *) echo "ENV must be one of: $(ENVS)"; exit 1 ;; esac

k8s-validate: chart-lint argocd-render argocd-guard sops-check

argocd-guard:
	bash scripts/deploy/check-argocd-bootstrap.sh

chart-lint:
	@cd kubernetes; fail=0; \
	for f in $(CHART)/ci/*-values.yaml; do \
	  printf '── lint %s\n' "$$(basename "$$f")"; \
	  helm lint $(CHART) -f "$$f" >/dev/null || fail=1; \
	  helm template ci $(CHART) -f "$$f" >/dev/null || fail=1; \
	done; \
	[ "$$fail" -eq 0 ] || { echo "chart ci matrix failed"; exit 1; }

# The app value layers live in ONE place: applications/helmfile.yaml.gotmpl.
APP_HF = helmfile -f applications/helmfile.yaml.gotmpl

# Every app × every environment through that helmfile, then the ApplicationSet's copy of the
# layers checked against it (Argo CD cannot read a helmfile).
argocd-render:
	@fail=0; for env in $(ENVS); do \
	  printf '── render apps @ %s\n' "$$env"; \
	  $(APP_HF) -e "$$env" template --skip-deps --allow-no-matching-release >/dev/null 2>&1 \
	    || { $(APP_HF) -e "$$env" template --skip-deps --allow-no-matching-release 2>&1 | tail -5; fail=1; }; \
	done; \
	bash scripts/docs/check-argocd-layers.sh || fail=1; \
	[ "$$fail" -eq 0 ] || { echo "app render failed"; exit 1; }

argocd-manifests:
	kubectl apply --dry-run=client --validate=false -f kubernetes/argocd/root-app.yaml
	kubectl apply --dry-run=client --validate=false -R -f kubernetes/argocd/bootstrap/

platform-template: check-env
	cd kubernetes && helmfile -e $(ENV) -l layer=platform template >/dev/null

sops-check:
	@rc=0; \
	for f in environments/*/kubernetes/secrets.enc.yaml; do \
	  if grep -q '^sops:' "$$f" || grep -q 'ENC\[' "$$f"; then echo "[OK]   $$f"; \
	  else echo "[FAIL] $$f is plaintext — sops -e -i $$f"; rc=1; fi; \
	done; \
	exit $$rc

# Recipient separation, read from public metadata only: the age recipients in
# .sops.yaml and in each secrets file's `sops:` block. Nothing is decrypted, and
# no key is printed — only environment names and counts.
#   1. .sops.yaml has no REPLACE_WITH_ recipient left
#   2. no age recipient appears in the .sops.yaml rules of two environments
#   3. no age recipient appears in the secrets files of two environments
#   4. every file is encrypted only to the recipients of its own .sops.yaml rule
# Kept out of `validate`: it fails until the cutover in docs/20-runbooks/platform.md §2.1.1 is done.
sops-recipients-check:
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; rc=0; \
	n=$$(awk '!/^ *#/ && /REPLACE_WITH_/ { c++ } END { print c+0 }' .sops.yaml); \
	[ "$$n" -eq 0 ] || { echo "[FAIL] .sops.yaml: $$n recipient(s) still REPLACE_WITH_"; rc=1; }; \
	awk '/path_regex:/ { env=""; if (match($$0, /environments\/[a-z0-9-]+\/kubernetes\/secrets/)) env=substr($$0, RSTART+13, RLENGTH-32) } \
	     env != "" && /^ *age:/ { sub(/^ *age: */, ""); n=split($$0, k, /[ ,]+/); \
	       for (i=1; i<=n; i++) if (k[i] ~ /^age1/) print k[i] > ("'"$$tmp"'/rule." env) }' .sops.yaml; \
	for f in environments/*/kubernetes/secrets.enc.yaml; do \
	  env=$$(basename "$$(dirname "$$(dirname "$$f")")"); \
	  sed -n 's/^ *- recipient: *\(age1[0-9a-z]*\).*/\1/p' "$$f" | sort -u > "$$tmp/file.$$env"; \
	done; \
	for kind in rule file; do \
	  for a in "$$tmp"/$$kind.*; do for b in "$$tmp"/$$kind.*; do \
	    [ -f "$$a" ] && [ -f "$$b" ] && [[ "$$a" < "$$b" ]] || continue; \
	    n=$$(comm -12 <(sort -u "$$a") <(sort -u "$$b") | wc -l | tr -d ' '); \
	    [ "$$n" -eq 0 ] || { echo "[FAIL] $$kind: $${a##*.} and $${b##*.} share $$n age recipient(s)"; rc=1; }; \
	  done; done; \
	done; \
	for fe in "$$tmp"/file.*; do \
	  env=$${fe##*.}; [ -s "$$fe" ] || continue; \
	  n=$$(comm -23 "$$fe" <(sort -u "$$tmp/rule.$$env" 2>/dev/null) | wc -l | tr -d ' '); \
	  [ "$$n" -eq 0 ] || { echo "[FAIL] environments/$$env/kubernetes/secrets.enc.yaml: $$n age recipient(s) not in its .sops.yaml rule"; rc=1; }; \
	done; \
	[ "$$rc" -eq 0 ] && echo "[OK]   SOPS age recipients are separate per environment"; \
	exit $$rc

gitleaks:
	gitleaks detect --source . --redact --verbose --exit-code 1

modules-validate: modules-fmt-check modules-typed-inputs modules-tf-validate modules-test

modules-fmt-check:
	cd terraform && $(TERRAFORM) fmt -check -recursive modules examples

modules-typed-inputs:
	@if grep -rnE 'yamldecode|global_config|config_file' --include='*.tf' terraform/modules; then \
	  echo "modules take typed Terraform inputs only"; exit 1; fi
	@if find terraform -maxdepth 1 -name '*.tf' | grep -q .; then \
	  echo "terraform/ holds no root .tf"; exit 1; fi

modules-tf-validate:
	@cd terraform; fail=0; \
	for d in modules/*/ examples/complete/; do \
	  if (cd "$$d" && $(TERRAFORM) init -backend=false -input=false >/dev/null && $(TERRAFORM) validate -no-color >/dev/null); then \
	    echo "ok    $$d"; else echo "FAIL  $$d"; fail=1; fi; \
	done; \
	exit $$fail

modules-test:
	@cd terraform; fail=0; \
	for d in $(if $(MODULE),modules/$(MODULE)/,modules/*/); do \
	  [ -d "$${d}tests" ] || continue; \
	  echo "== $$d"; \
	  (cd "$$d" && $(TERRAFORM) init -backend=false -input=false >/dev/null && $(TERRAFORM) test -no-color) || fail=1; \
	done; \
	exit $$fail

stacks-validate: stacks-lint stacks-config stacks-fmt-check stacks-tf-validate stacks-test

stacks-lint:
	cd terraform && yamllint --strict ../environments/*/terraform ../applications/*/terraform

stacks-config:
	cd terraform && check-jsonschema --check-metaschema schema/*.json
	@cd terraform; for t in environment core backend; do \
	  check-jsonschema --schemafile "schema/$$t.schema.json" ../environments/*/terraform/"$$t.yaml"; \
	done
	cd terraform && find ../applications -path '*/terraform/app.yaml' -exec check-jsonschema --schemafile schema/app.schema.json {} +
	cd terraform && find ../applications -path '*/terraform/*.yaml' ! -name app.yaml -exec check-jsonschema --schemafile schema/app-environment.schema.json {} +

stacks-fmt-check:
	cd terraform && $(TERRAFORM) fmt -check -recursive stacks shared tests

stacks-tf-validate:
	@cd terraform; for d in $(STACKS); do \
	  echo "== $$d"; \
	  (cd "$$d" && $(TERRAFORM) init -backend=false -input=false >/dev/null && $(TERRAFORM) validate); \
	done

stacks-test:
	cd terraform/tests && $(TERRAFORM) init -backend=false -input=false -test-directory=. >/dev/null && $(TERRAFORM) test -test-directory=.

fmt:
	cd terraform && $(TERRAFORM) fmt -recursive

# ── applications / docs ─────────────────────────────────────────────────────
# Scaffolds a new application from applications/_template (never from another
# applications/<app>, whose every folder is a live app for Helmfile, Argo CD and Terraform).
# eks: k8s/ + terraform/ (ECR only) · ecs: terraform-ecs/ copied as terraform/, no k8s/.
# Writes files only; nothing is planned, built or deployed.
RUNTIME ?= eks
new-app:
	@echo "$(APP)" | grep -Eq '^[a-z0-9][a-z0-9-]{0,52}$$' || { echo "APP must match ^[a-z0-9][a-z0-9-]{0,52}$$ (release + ECR name)"; exit 1; }
	@case "$(RUNTIME)" in eks|ecs) ;; *) echo "RUNTIME must be eks or ecs"; exit 1 ;; esac
	@[ ! -e "applications/$(APP)" ] || { echo "applications/$(APP) already exists — not overwriting"; exit 1; }
	@mkdir -p "applications/$(APP)"
	@if [ "$(RUNTIME)" = eks ]; then \
	  cp -R applications/_template/k8s applications/_template/terraform "applications/$(APP)/"; \
	else \
	  cp -R applications/_template/terraform-ecs "applications/$(APP)/terraform"; \
	fi
	@find "applications/$(APP)" -type f -name '*.yaml' -exec sed -i.bak 's/__APP__/$(APP)/g' {} + && find "applications/$(APP)" -name '*.bak' -delete
	@echo "created applications/$(APP) ($(RUNTIME)):"; find "applications/$(APP)" -type f | sort | sed 's/^/  /'
	@echo "next: fill every REPLACE_WITH_ marker, then: make stacks-config$(if $(filter eks,$(RUNTIME)), argocd-render,)"
	@echo "guide: docs/10-onboard-app.md"

docs-reference:
	@bash scripts/docs/gen-chart-reference.sh
	@bash scripts/docs/gen-app-template.sh
	@echo "wrote applications/_template/k8s/<env>/values.yaml (every chart key, one file per environment)"

docs-check:
	@tmp=$$(mktemp -d); bash scripts/docs/gen-chart-reference.sh "$$tmp" >/dev/null; \
	rc=0; for f in reference/application-chart.md schemas/application-values.overlay.schema.json; do \
	  diff -q "$$tmp/$$f" "docs/$$f" >/dev/null || { echo "[STALE] docs/$$f — run: make docs-reference"; rc=1; }; \
	done; \
	bash scripts/docs/gen-app-template.sh "$$tmp/tpl" && diff -rq "$$tmp/tpl" applications/_template/k8s >/dev/null \
	  || { echo "[STALE] applications/_template/k8s/<env>/values.yaml — run: make docs-reference"; rc=1; }; \
	rm -rf "$$tmp"; [ "$$rc" -eq 0 ] && echo "[OK] generated docs are current"; exit $$rc

# One app, one environment, printed (the same helmfile as argocd-render).
app-render:
	@[ -f "applications/$(APP)/k8s/$(ENV)/values.yaml" ] || { echo "usage: make app-render APP=<app> ENV=<env> (applications/<app>/k8s/<env>/values.yaml)"; exit 1; }
	@$(APP_HF) -e $(ENV) -l name=$(APP) template --skip-deps 2>/dev/null

# One app's FINAL values in one environment (or ENV=all): every layer merged like Argo CD does.
app-values:
	@bash scripts/docs/app-values.sh "$(APP)" "$(ENV)"

# Cluster metadata (environments/<env>/kubernetes/cluster/) + its tooling (scripts/cluster/: schemas,
# scripts, tests) and the read-only preflight. Nothing here deploys.
K8S_ENV := scripts/cluster
K8S_ENV_DIRS := environments/dev/kubernetes/cluster environments/staging/kubernetes/cluster environments/prod/kubernetes/cluster
K8S_CLUSTERS = $(filter-out %/environment.yaml %/target.yaml %/target.local.yaml,$(wildcard $(addsuffix /*.yaml,$(K8S_ENV_DIRS))))

k8s-env-test:
	@for f in $(K8S_ENV)/*.sh $(K8S_ENV)/lib/*.sh $(K8S_ENV)/tests/*.sh; do bash -n "$$f" || exit 1; done; echo "bash -n: ok"
	@if command -v shellcheck >/dev/null; then shellcheck -x $(K8S_ENV)/*.sh $(K8S_ENV)/lib/*.sh $(K8S_ENV)/tests/*.sh; else echo "shellcheck not installed — skipped"; fi
	bash $(K8S_ENV)/check-metadata.sh
	bash $(K8S_ENV)/tests/preflight-test.sh

# Same tools, pins and yamllint config as stacks-lint/stacks-config (ci/terraform/requirements.txt).
k8s-env-schema:
	yamllint --strict -c terraform/.yamllint.yml $(K8S_ENV_DIRS)
	check-jsonschema --check-metaschema $(K8S_ENV)/schemas/*.json
	check-jsonschema --schemafile $(K8S_ENV)/schemas/cluster.schema.json $(K8S_CLUSTERS)
	check-jsonschema --schemafile $(K8S_ENV)/schemas/environment.schema.json $(addsuffix /environment.yaml,$(K8S_ENV_DIRS))

# Read-only: get/list/discovery + auth can-i against the named context. Never switches context.
k8s-preflight:
	@[ -n "$(CLUSTER)" ] || { echo "usage: make k8s-preflight CLUSTER=<$(subst $(eval) ,|,$(basename $(notdir $(K8S_CLUSTERS))))> [CONTEXT=<ctx>] [KUBECONFIG_FILE=<file>]"; exit 2; }
	bash $(K8S_ENV)/preflight.sh --cluster "$(CLUSTER)" $(if $(CONTEXT),--context "$(CONTEXT)") $(if $(KUBECONFIG_FILE),--kubeconfig "$(KUBECONFIG_FILE)")
