#!/usr/bin/env bash
# Final values of one app in one environment — every layer merged in the order of
# applications/helmfile.yaml.gotmpl (= Argo CD's) — printed as YAML: one block per top-level key, each setting under it on
# one JSON-like line ({…} / […]); multi-line strings (files) stay as block text.
# usage: app-values.sh <app> <env>     env: dev | staging | prod | all
# Merge = Helm's: maps merge key by key, lists are replaced, a null removes the key.
set -euo pipefail
cd "$(dirname "$0")/../.."
APP=$1; ENV=$2
A=applications/$APP/k8s
[ -d "$A" ] || { echo "no $A" >&2; exit 1; }

layers() {   # chart defaults, then the release's values files from applications/helmfile.yaml.gotmpl
  echo kubernetes/charts/application/values.yaml
  helmfile -e "$1" -f applications/helmfile.yaml.gotmpl -l name="$APP" build 2>/dev/null \
    | yq 'select(.releases) | .releases[0].values[] | select(tag == "!!str")' \
    | python3 -c 'import os,sys; [print(os.path.normpath("applications/" + l.strip())) for l in sys.stdin if l.strip()]'
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
  all) for e in dev staging prod; do
         [ -f "$A/$e/values.yaml" ] || continue
         printf '# ── %s ──\n' "$e"; one "$e"; echo; done ;;
  dev|staging|prod)
       [ -f "$A/${ENV}/values.yaml" ] || { echo "no $A/$ENV/values.yaml" >&2; exit 1; }
       one "$ENV" ;;
  *) echo "ENV must be dev|staging|prod|all" >&2; exit 1 ;;
esac
