SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ENV ?= dev
ENVS := dev staging prod
TERRAFORM ?= terraform
MODULE ?=
CHART := charts/application
APPS := $(notdir $(patsubst %/k8s/,%,$(wildcard applications/*/k8s/)))
STACKS := stacks/core stacks/registry stacks/service


.PHONY: help validate k8s-validate chart-lint argocd-render argocd-manifests platform-template app-template \
        sops-check gitleaks modules-validate modules-fmt-check modules-typed-inputs modules-tf-validate modules-test \
        stacks-validate stacks-lint stacks-config stacks-fmt-check stacks-tf-validate stacks-test fmt check-env \
        new-app app-render app-values docs-reference docs-check

help:
	@echo "make validate                    k8s-validate + modules-fmt-check + modules-typed-inputs + stacks-fmt-check (offline, no key)"
	@echo "k8s/"
	@echo "  make k8s-validate              chart-lint + argocd-render + sops-check"
	@echo "  make chart-lint                lint + render every k8s/$(CHART)/ci/*-values.yaml"
	@echo "  make argocd-render             render every applications/<app>/k8s in $(ENVS)"
	@echo "  make argocd-manifests          client dry-run of argocd/root-app.yaml + bootstrap/"
	@echo "  make platform-template ENV=    helmfile -e ENV -l layer=platform template (needs ENV age key)"
	@echo "  make app-template ENV=         helmfile -e ENV -l layer=app template (needs ENV age key)"
	@echo "  make sops-check                every infra-base/k8s/env-values/<env>/secrets.enc.yaml is SOPS-encrypted"
	@echo "terraform/modules"
	@echo "  make modules-validate          fmt-check + typed-inputs + tf-validate + test"
	@echo "  make modules-test [MODULE=]    terraform test (Terraform >= 1.7)"
	@echo "terraform/stacks"
	@echo "  make stacks-validate           lint + config + fmt-check + tf-validate + test (Terraform >= 1.10)"
	@echo "make fmt                         terraform fmt -recursive terraform/"
	@echo "make gitleaks                    gitleaks detect --redact"
	@echo "applications / docs (docs/README.md)"
	@echo "  make new-app APP=<name> RUNTIME=eks|ecs   scaffold applications/<name> from docs/templates/<runtime>-app"
	@echo "  make app-render APP=<name> ENV=[onprem-]dev|staging|prod   print one app's manifests, every value layer applied"
	@echo "  make app-values APP=<name> ENV=<env>|all   final merged values of one app (every layer), JSON-like YAML"
	@echo "  make docs-reference           regenerate chart reference, schemas and the full EKS values template from the chart"
	@echo "  make docs-check               fail when the generated docs are stale"
	@echo "TERRAFORM=<cmd> overrides the terraform binary. No target plans, applies or syncs."

validate: k8s-validate modules-fmt-check modules-typed-inputs stacks-fmt-check

check-env:
	@case "$(ENV)" in dev|staging|prod) ;; *) echo "ENV must be one of: $(ENVS)"; exit 1 ;; esac

k8s-validate: chart-lint argocd-render sops-check

chart-lint:
	@cd k8s; fail=0; \
	for f in $(CHART)/ci/*-values.yaml; do \
	  printf '── lint %s\n' "$$(basename "$$f")"; \
	  helm lint $(CHART) -f "$$f" >/dev/null || fail=1; \
	  helm template ci $(CHART) -f "$$f" >/dev/null || fail=1; \
	done; \
	[ "$$fail" -eq 0 ] || { echo "chart ci matrix failed"; exit 1; }

argocd-render:
	@cd k8s; fail=0; \
	for app in $(APPS); do \
	  for env in $(ENVS); do \
	    printf '── render %s @ %s\n' "$$app" "$$env"; \
	    helm template "$$app" $(CHART) \
	      -f ../infra-base/k8s/env-values/app-values.yaml.gotmpl -f "../infra-base/k8s/env-values/$$env/app-values.yaml.gotmpl" \
	      -f "../applications/$$app/k8s/values.yaml" -f "../applications/$$app/k8s/$$env/values.yaml" >/dev/null || fail=1; \
	    [ -f "../applications/$$app/k8s/onprem-$$env/values.yaml" ] || continue; \
	    printf '── render %s @ onprem-%s\n' "$$app" "$$env"; \
	    helm template "$$app" $(CHART) \
	      -f ../infra-base/k8s/env-values/app-values.yaml.gotmpl -f "../infra-base/k8s/env-values/$$env/app-values.yaml.gotmpl" \
	      -f "../infra-base/k8s/env-values/onprem-$$env/app-values.yaml.gotmpl" \
	      -f "../applications/$$app/k8s/values.yaml" -f "../applications/$$app/k8s/$$env/values.yaml" \
	      -f "../applications/$$app/k8s/onprem-$$env/values.yaml" >/dev/null || fail=1; \
	  done; \
	done; \
	[ "$$fail" -eq 0 ] || { echo "app render failed"; exit 1; }

argocd-manifests:
	kubectl apply --dry-run=client --validate=false -f argocd/root-app.yaml
	kubectl apply --dry-run=client --validate=false -R -f argocd/bootstrap/

platform-template: check-env
	cd k8s && helmfile -e $(ENV) -l layer=platform template >/dev/null

app-template: check-env
	cd k8s && CHART_PATH="$(CURDIR)/k8s/$(CHART)" helmfile -e $(ENV) -l layer=app template >/dev/null

sops-check:
	@rc=0; \
	for f in infra-base/k8s/env-values/*/secrets.enc.yaml; do \
	  if grep -q '^sops:' "$$f" || grep -q 'ENC\[' "$$f"; then echo "[OK]   $$f"; \
	  else echo "[FAIL] $$f is plaintext — sops -e -i $$f"; rc=1; fi; \
	done; \
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
	cd terraform && yamllint --strict ../infra-base/terraform/environments ../applications/*/terraform

stacks-config:
	cd terraform && check-jsonschema --check-metaschema schema/*.json
	@cd terraform; for t in environment core backend; do \
	  check-jsonschema --schemafile "schema/$$t.schema.json" ../infra-base/terraform/environments/*/"$$t.yaml"; \
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
# Scaffolds a new application from docs/templates/<runtime>-app (never from
# applications/, whose every folder is a live app for Argo CD and Terraform).
# Writes files only; nothing is planned, built or deployed.
RUNTIME ?= eks
new-app:
	@echo "$(APP)" | grep -Eq '^[a-z0-9][a-z0-9-]{0,52}$$' || { echo "APP must match ^[a-z0-9][a-z0-9-]{0,52}$$ (release + ECR name)"; exit 1; }
	@case "$(RUNTIME)" in eks|ecs) ;; *) echo "RUNTIME must be eks or ecs"; exit 1 ;; esac
	@[ ! -e "applications/$(APP)" ] || { echo "applications/$(APP) already exists — not overwriting"; exit 1; }
	@mkdir -p "applications/$(APP)"
	@cp -R "docs/templates/$(RUNTIME)-app/." "applications/$(APP)/"
	@find "applications/$(APP)" -type f -name '*.yaml' -exec sed -i.bak 's/__APP__/$(APP)/g' {} + && find "applications/$(APP)" -name '*.bak' -delete
	@echo "created applications/$(APP) ($(RUNTIME)):"; find "applications/$(APP)" -type f | sort | sed 's/^/  /'
	@echo "next: fill every REPLACE_WITH_ marker, then: make stacks-config$(if $(filter eks,$(RUNTIME)), argocd-render,)"
	@echo "guide: docs/app-onboarding.md"

docs-reference:
	@bash docs/tools/gen-chart-reference.sh
	@python3 docs/tools/gen-app-values.py docs/tools/eks-app-values.base.yaml | python3 docs/tools/strip-notes.py - > docs/templates/eks-app/k8s/values.yaml
	@echo "wrote docs/templates/eks-app/k8s/values.yaml (every chart option, commented, key/value only)"

docs-check:
	@tmp=$$(mktemp -d); bash docs/tools/gen-chart-reference.sh "$$tmp" >/dev/null; \
	rc=0; for f in reference/application-chart.md schemas/application-values.overlay.schema.json; do \
	  diff -q "$$tmp/$$f" "docs/$$f" >/dev/null || { echo "[STALE] docs/$$f — run: make docs-reference"; rc=1; }; \
	done; \
	python3 docs/tools/gen-app-values.py docs/tools/eks-app-values.base.yaml | python3 docs/tools/strip-notes.py - | diff -q - docs/templates/eks-app/k8s/values.yaml >/dev/null \
	  || { echo "[STALE] docs/templates/eks-app/k8s/values.yaml — run: make docs-reference"; rc=1; }; \
	rm -rf "$$tmp"; [ "$$rc" -eq 0 ] && echo "[OK] generated docs are current"; exit $$rc

# One app, one environment, the same layers as argocd-render — printed, for reading.
app-render:
	@case "$(ENV)" in dev|staging|prod|onprem-dev|onprem-staging|onprem-prod) ;; *) echo "ENV must be one of: $(ENVS) $(addprefix onprem-,$(ENVS))"; exit 1 ;; esac
	@[ -f "applications/$(APP)/k8s/$(ENV)/values.yaml" ] || { echo "applications/$(APP)/k8s/$(ENV)/values.yaml not found"; exit 1; }
	@tier="$(patsubst onprem-%,%,$(ENV))"; \
	cd k8s && helm template "$(APP)" $(CHART) --namespace "$$tier" \
	  -f ../infra-base/k8s/env-values/app-values.yaml.gotmpl -f "../infra-base/k8s/env-values/$$tier/app-values.yaml.gotmpl" \
	  $(if $(filter onprem-%,$(ENV)),-f "../infra-base/k8s/env-values/$(ENV)/app-values.yaml.gotmpl") \
	  -f "../applications/$(APP)/k8s/values.yaml" -f "../applications/$(APP)/k8s/$$tier/values.yaml" \
	  $(if $(filter onprem-%,$(ENV)),-f "../applications/$(APP)/k8s/$(ENV)/values.yaml")

# One app's FINAL values in one environment (or ENV=all): every layer merged like Argo CD does.
app-values:
	@bash docs/tools/app-values.sh "$(APP)" "$(ENV)"
