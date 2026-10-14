#!/usr/bin/env bash
# Final values of one app in one environment — every layer merged in the order Argo CD
# (and local/) uses — printed as YAML: one block per top-level key, each setting under it on
# one JSON-like line ({…} / […]); multi-line strings (files) stay as block text.
# usage: app-values.sh <app> <env>     env: dev | staging | prod | onprem-<tier> | local | all
# Merge = Helm's: maps merge key by key, lists are replaced, a null removes the key.
set -euo pipefail
cd "$(dirname "$0")/../.."
APP=$1; ENV=$2
A=applications/$APP/k8s
[ -f "$A/values.yaml" ] || { echo "no $A/values.yaml" >&2; exit 1; }

layers() {
  local env=$1 tier=${1#onprem-}
  echo k8s/charts/application/values.yaml
  echo infra-base/k8s/env-values/app-values.yaml.gotmpl
  if [ "$env" = local ]; then
    echo local/values/app-values.yaml
    echo "$A/values.yaml"; echo "$A/local/values.yaml"; return
  fi
  echo "infra-base/k8s/env-values/$tier/app-values.yaml.gotmpl"
  [ "$env" = "$tier" ] || echo "infra-base/k8s/env-values/$env/app-values.yaml.gotmpl"
  echo "$A/values.yaml"; echo "$A/$tier/values.yaml"
  [ "$env" = "$tier" ] || echo "$A/$env/values.yaml"
}

one() {
  local env=$1 files=()
  while read -r f; do
    [ -f "$f" ] || { echo "missing layer: $f" >&2; exit 1; }
    files+=("$f")
  done < <(layers "$env")
  yq eval-all '. as $l ireduce ({}; . * $l)
               | del(.. | select(. == null))
               | ... comments = ""
               | (.[] | select(tag == "!!map" or tag == "!!seq") | .[]
                  | select(tag == "!!map" or tag == "!!seq")
                  | select([.. | select(tag == "!!str" and test("\n"))] | length == 0)) style="flow"
               | (.[] | select((tag == "!!map" or tag == "!!seq") and length == 0)) style="flow"' "${files[@]}" \
    | awk '/^[A-Za-z_]/ && prev ~ /^[ -]/ {print ""} {print; prev=$0}'     # blank line after each block
}

case "$ENV" in
  all) for e in dev staging prod local $(cd "$A" && ls -d onprem-* 2>/dev/null); do
         [ -f "$A/$e/values.yaml" ] || continue
         printf '# ── %s ──\n' "$e"; one "$e"; echo; done ;;
  dev|staging|prod|local|onprem-dev|onprem-staging|onprem-prod)
       [ -f "$A/${ENV}/values.yaml" ] || { echo "no $A/$ENV/values.yaml" >&2; exit 1; }
       one "$ENV" ;;
  *) echo "ENV must be dev|staging|prod|onprem-<tier>|local|all" >&2; exit 1 ;;
esac
