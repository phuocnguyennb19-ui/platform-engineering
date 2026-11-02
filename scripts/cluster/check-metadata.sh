#!/usr/bin/env bash
# Offline checks of environments/<env>/kubernetes/cluster/{<cluster>,environment,target}.yaml that a JSON
# schema cannot express.
# Field types, enums and policy (staging/production never auto-deploy, prod/production name
# mapping) are schemas/*.schema.json — the single source, checked by `make k8s-env-schema`.
# This script adds only:
#   · the YAML subset lib/metadata.sh can read, and the keys the scripts read are readable
#   · cluster: name = file name; it sits in the folder of its environment, whose
#     environment.yaml exists; provisioning.source exists
#   · environment.yaml: name matches its folder; security.podSecurityStandard equals the PSA
#     label of <env>/namespace/namespaces.yaml
#   · target.yaml / target.local.yaml: names a cluster file of the same folder whose
#     environment matches the Helm environment it serves
# No cluster, no network.
#
#   bash scripts/cluster/check-metadata.sh [<file>...]     # default: every file
#
# Exit: 0 all valid · 1 a rule failed
set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BASE=$HERE                                 # scripts/cluster
REPO=$(cd "$HERE/../.." && pwd)
K8S="$REPO/environments"
# env_of <path> → the environment folder a file lives in (environments/<env>/kubernetes/cluster/…)
env_of() { local p=${1#*environments/}; echo "${p%%/*}"; }
# shellcheck source=lib/metadata.sh
. "$HERE/lib/metadata.sh"

rc=0
bad() { echo "[FAIL] $1: $2"; rc=1; }

# The subset lib/metadata.sh reads: no tabs, even indentation, block mappings, one document.
check_subset() {
  local f=$1 n
  n=$(awk '/\t/ { print NR; exit }' "$f"); [ -z "$n" ] || bad "$f" "tab at line $n"
  n=$(awk '/^[[:space:]]*(#|$)/ { next } { match($0, /^ */); if (RLENGTH % 2) { print NR; exit } }' "$f")
  [ -z "$n" ] || bad "$f" "odd indentation at line $n"
  n=$(awk '/^[[:space:]]*(#|$)/ { next } /^---|^[[:space:]]*- |:[[:space:]]*[[{]/ { print NR; exit }' "$f")
  [ -z "$n" ] || bad "$f" "flow style, list or second document at line $n (not readable by lib/metadata.sh)"
  if grep -Eq '^(apiVersion|kind):' "$f"; then bad "$f" "apiVersion/kind would make it look like a Kubernetes manifest"; fi
}

need() {  # need <file> <key>... — each key must be readable (non-empty) by meta_get
  local f=$1 k; shift
  for k in "$@"; do [ -n "$(meta_get "$f" "$k")" ] || bad "$f" "$k missing or not readable"; done
}

# psa_label <manifest> <namespace> → pod-security.kubernetes.io/enforce of that Namespace
psa_label() {
  awk -v ns="$2" '
    /^---/ { kind = ""; name = ""; level = "" }
    /^kind:[[:space:]]*Namespace/ { kind = "ns" }
    /^  name:/ { name = $2 }
    /pod-security\.kubernetes\.io\/enforce:/ { level = $2 }
    kind == "ns" && name == ns && level != "" { print level; exit }' "$1"
}

check_environment() {
  local f=$1 name hf psa manifest live
  check_subset "$f"
  need "$f" schema name names.helmfile delivery.autoDeploy security.podSecurityStandard
  name=$(meta_get "$f" name) hf=$(meta_get "$f" names.helmfile) psa=$(meta_get "$f" security.podSecurityStandard)
  [ "$(meta_env_dir "$name")" = "$(env_of "$f")" ] \
    || bad "$f" "name '$name' does not belong in folder environments/$(env_of "$f")/"
  manifest=environments/$(meta_env_dir "$name")/kubernetes/namespace/namespaces.yaml
  if [ ! -f "$REPO/$manifest" ]; then bad "$f" "namespace manifest $manifest not found"; return; fi
  live=$(psa_label "$REPO/$manifest" "$hf")
  if [ -z "$live" ]; then bad "$f" "no Namespace '$hf' with a PSA enforce label in $manifest"
  elif [ "$live" != "$psa" ]; then bad "$f" "podSecurityStandard '$psa' but $manifest enforces '$live' on '$hf'"
  fi
}

check_cluster() {
  local f=$1 name env src cap
  check_subset "$f"
  need "$f" schema name provider environment context provisioning.method provisioning.source \
            delivery.owner delivery.ciDeployAllowed
  for cap in $META_CAPABILITIES; do need "$f" "capabilities.$cap.expected" "capabilities.$cap.verified"; done
  name=$(meta_get "$f" name) env=$(meta_get "$f" environment) src=$(meta_get "$f" provisioning.source)
  [ "$name" = "$(basename "$f" .yaml)" ] || bad "$f" "name '$name' differs from the file name"
  if [ -n "$env" ]; then
    [ "$(env_of "$f")" = "$(meta_env_dir "$env")" ] \
      || bad "$f" "environment '$env' belongs in environments/$(meta_env_dir "$env")/kubernetes/cluster/"
    [ -f "$K8S/$(meta_env_dir "$env")/kubernetes/cluster/environment.yaml" ] \
      || bad "$f" "environment '$env' has no $(meta_env_dir "$env")/cluster/environment.yaml"
  fi
  [ -z "$src" ] || [ -e "$REPO/$src" ] || bad "$f" "provisioning.source '$src' does not exist"
}

# Helm environment → the cluster `environment:` that may serve it.
check_target() {
  local f=$1 dir e want cluster cenv
  check_subset "$f"
  dir=$(dirname "$f") e=$(env_of "$f")
  case "$e" in dev|staging|prod) ;; *) bad "$f" "not under environments/<dev|staging|prod>/kubernetes/cluster/"; return ;; esac
  [ "$(meta_get "$f" schema)" = "kubernetes-target/v1alpha1" ] || bad "$f" "schema must be kubernetes-target/v1alpha1"
  cluster=$(meta_get "$f" cluster)
  [ -n "$cluster" ] || { [ "$(basename "$f")" = target.local.yaml ] || bad "$f" "cluster missing"; return; }
  case "$e" in prod) want=production ;; *) want=$e ;; esac
  if [ ! -f "$dir/$cluster.yaml" ]; then bad "$f" "cluster '$cluster' has no environments/$e/kubernetes/cluster/$cluster.yaml"; return; fi
  cenv=$(meta_get "$dir/$cluster.yaml" environment)
  [ "$cenv" = "$want" ] || bad "$f" "$e → $cluster serves environment '$cenv', not '$want'"
}

if [ "$#" -eq 0 ]; then
  set -- "$K8S"/dev/kubernetes/cluster/*.yaml "$K8S"/staging/kubernetes/cluster/*.yaml "$K8S"/prod/kubernetes/cluster/*.yaml
fi
for f in "$@"; do
  case "$(basename "$f")" in target.yaml|target.local.yaml) check_target "$f"; continue ;; esac
  case "$(meta_get "$f" schema)" in
    kubernetes-environment/v1alpha1)          check_cluster "$f" ;;
    kubernetes-environment-defaults/v1alpha1) check_environment "$f" ;;
    *) bad "$f" "unknown or missing schema" ;;
  esac
done
[ "$rc" -eq 0 ] && echo "[OK] $# metadata files valid"
exit "$rc"
