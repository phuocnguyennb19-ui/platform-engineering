#!/usr/bin/env bash
# The app value layers are defined once, in applications/helmfile.yaml.gotmpl. Argo CD cannot
# read a helmfile, so kubernetes/argocd/bootstrap/applicationset-apps.yaml repeats them: fail when the
# two lists differ for any app × dev/staging/prod. Offline; needs helmfile, yq (mikefarah).
set -euo pipefail
cd "$(dirname "$0")/../.."
HF=applications/helmfile.yaml.gotmpl
AS=${AS:-kubernetes/argocd/bootstrap/applicationset-apps.yaml}
norm() { python3 -c 'import os,sys; [print(os.path.normpath(l.strip())) for l in sys.stdin if l.strip()]'; }
rc=0
for env in dev staging prod; do
  for app in $(helmfile -e "$env" -f "$HF" list --allow-no-matching-release 2>/dev/null | awk 'NR > 1 { print $1 }'); do
    want=$(helmfile -e "$env" -f "$HF" -l name="$app" build 2>/dev/null \
      | yq 'select(.releases) | .releases[0].values[] | select(tag == "!!str")' | sed 's|^|applications/|' | norm)
    got=$(yq '.spec.template.spec.sources[0].helm.valueFiles[]' "$AS" \
      | sed -e 's|^\$values/||' -e "s|{{.path.path}}|applications/$app/k8s|g" \
            -e "s|{{index .metadata.labels \"platform.example.com/environment\"}}|$env|g" | norm)
    if [ "$want" != "$got" ]; then
      echo "[FAIL] $app @ $env: ApplicationSet valueFiles differ from $HF"
      diff <(echo "$want") <(echo "$got") | sed 's/^/       /'; rc=1
    fi
  done
done
[ "$rc" -eq 0 ] && echo "[OK] ApplicationSet value layers = $HF (dev/staging/prod)"
exit "$rc"
