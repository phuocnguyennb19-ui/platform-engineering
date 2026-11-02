#!/usr/bin/env bash
# Guard for the Argo CD App-of-Apps. The root app (kubernetes/argocd/root-app.yaml, project
# `bootstrap`) syncs kubernetes/argocd/bootstrap/ with prune + selfHeal and may write AppProjects
# and ApplicationSets — so whatever is merged there is applied with that power. A permissive
# AppProject, or an ApplicationSet whose Applications use another project, would turn a merge
# into cluster-admin. Refuses, offline:
#
#   root-app.yaml   anything but AppProject `bootstrap` + Application `platform-bootstrap`;
#                   `bootstrap` allowing more than AppProject/ApplicationSet in ns infra, from
#                   this repository, with no cluster-scoped kind; the root app in another project
#                   or pointing at another path
#   bootstrap/      any kind but AppProject / ApplicationSet; any AppProject but `platform`;
#                   `platform` with a cluster-scoped kind, a `*` anywhere, a source other than
#                   this repository, a destination namespace other than dev/staging/prod, roles
#                   or sourceNamespaces; an ApplicationSet whose Applications are not in `platform`
#                   (also via templatePatch)
#
#   args: [<repository URL>]   default: the repoURL of root-app.yaml (CI passes ${CI_PROJECT_URL}.git)
# Needs yq (mikefarah) v4.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=${ROOT:-kubernetes/argocd/root-app.yaml}
BOOT=${BOOT:-kubernetes/argocd/bootstrap}
repo=${1:-$(yq 'select(.kind == "Application") | .spec.source.repoURL' "$ROOT")}
rc=0
fail() { echo "[FAIL] $*"; rc=1; }

# ── root-app.yaml ──────────────────────────────────────────────
kinds=$(yq -N '.kind + "/" + .metadata.name' "$ROOT" | sort | tr '\n' ' ')
[ "$kinds" = "AppProject/bootstrap Application/platform-bootstrap " ] \
  || fail "$ROOT: must hold exactly AppProject/bootstrap and Application/platform-bootstrap (got: $kinds)"
want_boot='{"clusterResourceWhitelist":[],"destinations":[{"namespace":"infra","server":"https://kubernetes.default.svc"}],"namespaceResourceWhitelist":[{"group":"argoproj.io","kind":"AppProject"},{"group":"argoproj.io","kind":"ApplicationSet"}],"sourceRepos":["'"$repo"'"]}'
got_boot=$(yq ea -o=json -I=0 'select(.kind == "AppProject") | .spec | del(.description) | sort_keys(..)' "$ROOT")
[ "$got_boot" = "$want_boot" ] \
  || fail "$ROOT: AppProject bootstrap must allow only AppProject + ApplicationSet in ns infra from $repo, no cluster-scoped kind"
app=$(yq ea -o=json -I=0 'select(.kind == "Application") | [.spec.project, .spec.source.repoURL, .spec.source.path, .spec.destination.namespace]' "$ROOT")
[ "$app" = '["bootstrap","'"$repo"'","kubernetes/argocd/bootstrap","infra"]' ] \
  || fail "$ROOT: Application platform-bootstrap must be project bootstrap, source $repo path kubernetes/argocd/bootstrap, destination ns infra (got: $app)"

# ── bootstrap/ ─────────────────────────────────────────────────
files=$(find "$BOOT" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | sort)
[ -n "$files" ] || fail "$BOOT: no manifests"
for f in $files; do
  for k in $(yq -N 'select(.kind) | .kind + "/" + .metadata.name' "$f"); do
    case "$k" in
      AppProject/platform|ApplicationSet/*) ;;
      *) fail "$f: $k — only AppProject/platform and ApplicationSets belong in $BOOT" ;;
    esac
  done

  # AppProject platform
  if [ "$(yq -N 'select(.kind == "AppProject") | .metadata.name' "$f")" = platform ]; then
    p() { yq ea -N -o=json -I=0 "select(.kind == \"AppProject\") | .spec | $1" "$f"; }
    [ "$(p '.clusterResourceWhitelist // [] | length')" = 0 ] || fail "$f: AppProject platform must not allow cluster-scoped kinds"
    [ "$(p '[.. | select(tag == "!!str") | select(test("\\*"))] | length')" = 0 ] || fail "$f: AppProject platform must not contain a '*' wildcard"
    [ "$(p '.sourceRepos')" = '["'"$repo"'"]' ] || fail "$f: AppProject platform sourceRepos must be exactly [$repo]"
    [ "$(p '[.destinations[] | select(.namespace != "dev" and .namespace != "staging" and .namespace != "prod")] | length')" = 0 ] \
      || fail "$f: AppProject platform destinations must be namespaces dev / staging / prod only"
    [ "$(p '(.roles // []) + (.sourceNamespaces // []) | length')" = 0 ] || fail "$f: AppProject platform must not define roles or sourceNamespaces here"
    [ "$(p '.namespaceResourceWhitelist // [] | length')" -gt 0 ] || fail "$f: AppProject platform needs an explicit namespaceResourceWhitelist"
  fi

  # ApplicationSets: every generated Application in project platform
  for n in $(yq -N 'select(.kind == "ApplicationSet") | .metadata.name' "$f"); do
    proj=$(yq -N "select(.kind == \"ApplicationSet\" and .metadata.name == \"$n\") | .spec.template.spec.project" "$f")
    [ "$proj" = platform ] || fail "$f: ApplicationSet $n must generate Applications in project platform (got: $proj)"
    yq -N "select(.kind == \"ApplicationSet\" and .metadata.name == \"$n\") | .spec.templatePatch // \"\"" "$f" | grep -Eq '^[[:space:]]*project:' \
      && fail "$f: ApplicationSet $n templatePatch must not set project"
  done
done

[ "$rc" -eq 0 ] && echo "[OK] Argo CD bootstrap: root app in project bootstrap; bootstrap/ holds only AppProject platform (scoped) + ApplicationSets in project platform"
exit "$rc"
