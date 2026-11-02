#!/bin/sh
# Hook of every app release in applications/helmfile.yaml.gotmpl, run by helmfile before it
# installs, upgrades or uninstalls one (events preapply, presync, preuninstall). Never on
# template/diff/lint/list. Refuses unless ALL of these hold:
#
#   1. Every selector names the app:  helmfile … -l name=<app>    (no -l, or -l layer=app → refused)
#   2. The target's owner is helmfile — the app tier is not handed to Argo CD
#   3. A kube context is configured and exists in kubeconfig (it is the
#      release's --kube-context; the current-context is never used)
#   Owner and context come from environments/<env>/kubernetes/cluster/target(.local).yaml → <cluster>.yaml,
#   or from APP_TIER_OWNER / KUBE_CONTEXT_<ENV> for one command (resolved by the helmfile).
#   Plain KUBE_CONTEXT is not read for apps (one variable for every env could send prod values to
#   a dev cluster); when it is set and differs from the resolved context, the guard refuses.
#   4. No REPLACE_WITH_ placeholder left in the value files of this release
#   5. No Argo CD Application <app>-<env> exists on that cluster (two owners would fight); when
#      that cannot be checked (RBAC, timeout, network) the guard refuses — fail closed
#   6. prod: CONFIRM_DEPLOY=<app>@prod
#
#   args: <env> <release> <kube-context> <placeholder-file|""> <owner> <target-cluster>
set -eu

env=${1:-} rel=${2:-} ctx=${3:-} placeholder=${4:-} owner=${5:-} cluster=${6:-}
conf="environments/$env/kubernetes/cluster/target.yaml (or target.local.yaml)"
deny() { echo "[BLOCKED] $rel @ $env: $*" >&2; exit 1; }
[ -n "$env" ] && [ -n "$rel" ] || deny "usage: release-guard.sh <env> <release> <kube-context> <placeholder-file>"

# 1. The parent of this hook is the helmfile process; its argv carries the selectors.
args=$(ps -o args= -p "$PPID" 2>/dev/null) || deny "cannot read the helmfile command line (ps) — refusing"
sels=$(printf '%s\n' "$args" | awk '{
  for (i = 1; i <= NF; i++) {
    if ($i == "-l" || $i == "--selector") { print $(i + 1); i++ }
    else if ($i ~ /^--selector=/) { sub(/^--selector=/, "", $i); print $i }
    else if ($i ~ /^-l./)          { sub(/^-l/, "", $i); print $i }
  } }')
[ -n "$sels" ] || deny "no selector — run: helmfile -e $env -l name=$rel sync"
printf '%s\n' "$sels" | grep -Eqv "(^|,)name=$rel(,|\$)" \
  && deny "every selector must name the app (got: $(printf '%s ' $sels)) — run: helmfile -e $env -l name=$rel sync"

# 2. single owner
[ -n "$cluster" ] || [ -n "$ctx" ] || deny "no target for '$env' in $conf — add cluster: <name>"
[ "$owner" = helmfile ] \
  || deny "owner of ${cluster:-the target} is '${owner:-<unset>}', not helmfile (clusters/${cluster:-<cluster>}.yaml delivery.owner, or APP_TIER_OWNER=helmfile) — Argo CD must not own it"
# 3. explicit cluster
envvar=KUBE_CONTEXT_$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')
[ -n "$ctx" ] || deny "no kube context for '$env' (cluster ${cluster:-?} still has a <placeholder>) — set context: in $conf, or $envvar"
[ -z "${KUBE_CONTEXT:-}" ] || [ "$KUBE_CONTEXT" = "$ctx" ] \
  || deny "KUBE_CONTEXT='$KUBE_CONTEXT' is set but apps use '$ctx' — plain KUBE_CONTEXT is not read for apps; unset it, or use $envvar=<context>"
kubectl config get-contexts -o name 2>/dev/null | grep -Fxq -- "$ctx" \
  || deny "kube context '$ctx' is not in kubeconfig (kubectl config get-contexts -o name)"

# 4. unfilled placeholders (comment lines excluded at render time)
[ -z "$placeholder" ] || deny "REPLACE_WITH_ placeholder in $placeholder — fill it first"

# 5. Argo CD must not own this release on that cluster (ApplicationSet names it <app>-<env>)
if [ -n "$ctx" ]; then
  out=$(kubectl --context="$ctx" --request-timeout=10s get applications.argoproj.io -A -o name 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out" | grep -Eq "/$rel-$env\$" \
      && deny "Argo CD Application '$rel-$env' exists on $ctx — it owns this release"
  else
    case "$out" in
      *"doesn't have a resource type"*) ;;  # Argo CD not installed: no second owner
      *) deny "could not check for an Argo CD Application on $ctx ($(printf '%s' "$out" | head -n 1)) — refusing; fix access to the cluster and retry" ;;
    esac
  fi
fi

# 6. production needs a typed confirmation
case "$env" in
  prod)
    [ "${CONFIRM_DEPLOY:-}" = "$rel@$env" ] || deny "production: set CONFIRM_DEPLOY=$rel@$env to confirm" ;;
esac

echo "[OK] $rel @ $env → cluster '${cluster:-<$envvar>}' context '$ctx'"
