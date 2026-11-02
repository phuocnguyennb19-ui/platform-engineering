# shellcheck shell=bash
# Reader for environments/<env>/kubernetes/cluster/*.yaml. Sourced, never executed.
#
# The files are a constrained YAML subset — block mappings, 2-space indent, scalar values,
# `#` comments — which schemas/*.schema.json describe and check-metadata.sh enforces. That
# keeps the reader to awk, so preflight needs no yq, jq or Python on an operator's machine.

# meta_get <file> <dotted.key> → the scalar at that path (quotes and comments stripped),
# empty when absent. Exit status 0 even when absent; test the output.
meta_get() {
  awk -v want="$2" '
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */); depth = RLENGTH / 2
      line = substr($0, RLENGTH + 1)
      if (line !~ /^[A-Za-z0-9_-]+:/) next
      key = line; sub(/:.*/, "", key)
      val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
      sub(/[[:space:]]+#.*$/, "", val); sub(/[[:space:]]+$/, "", val)
      if (val ~ /^".*"$/ || val ~ /^\047.*\047$/) val = substr(val, 2, length(val) - 2)
      path[depth] = key
      p = path[0]; for (i = 1; i <= depth; i++) p = p "." path[i]
      if (p == want) { print val; exit }
    }' "$1"
}

# meta_placeholder <value> → 0 when the value is an unreplaced <placeholder>.
meta_placeholder() { case "$1" in "<"*">") return 0 ;; *) return 1 ;; esac; }

# meta_env_dir <environment> → its folder under environments/ (Terraform `production` → `prod`).
meta_env_dir() { case "$1" in production) echo prod ;; *) echo "$1" ;; esac; }

# meta_resolve_cluster <name|path> <environments-root> → path of the cluster file, empty if none.
# A name is looked up in <env>/kubernetes/cluster/<name>.yaml of every environment.
meta_resolve_cluster() {
  local e
  if [ -f "$1" ]; then echo "$1"; return; fi
  case "$1" in environment|target|target.local) return ;; esac
  for e in dev staging prod; do
    if [ -f "$2/$e/kubernetes/cluster/$1.yaml" ]; then echo "$2/$e/kubernetes/cluster/$1.yaml"; return; fi
  done
}

META_CAPABILITIES="ingress gatewayAPI prometheusOperator persistentStorage"
