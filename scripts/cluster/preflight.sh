#!/usr/bin/env bash
# Read-only Kubernetes preflight: what a cluster actually provides, before anything is deployed.
#
#   preflight.sh [--cluster <name|file>] [--context <name>] [--kubeconfig <file>]
#   make k8s-preflight CLUSTER=<name> [CONTEXT=<name>] [KUBECONFIG_FILE=<file>]
#
#   --cluster     <name> (environments/<env>/kubernetes/cluster/<name>.yaml) or a path: expected context, app namespace and the capabilities
#                 workloads need, each then checked live. Without it: inventory only.
#   --context     kubeconfig context (or KUBE_CONTEXT). Must equal the metadata context
#                 unless that is still a <placeholder>. Never switched: passed per call.
#   --kubeconfig  read this kubeconfig instead of $KUBECONFIG / ~/.kube/config; nothing is
#                 written to either.
#
# Only get/list/discovery requests plus `kubectl auth can-i` (a SelfSubjectAccessReview:
# persists nothing, audit-logged as `create`). Never reads Secrets or prints kubeconfig.
#
# Results: PASS verified · WARN optional and absent/degraded · UNKNOWN could not be checked
#          FAIL required and failed, or required and could not be verified
# Exit:    0 no FAIL · 1 one or more FAIL · 2 usage error, missing dependency, bad context
# Env:     PREFLIGHT_TIMEOUT (default 10s) → --request-timeout on every kubectl call
# Needs:   bash ≥ 3.2, kubectl, awk, grep, sed, sort, mktemp.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BASE=$HERE                                 # scripts/cluster
K8S=$(cd "$HERE/../../environments" && pwd)
# shellcheck source=lib/metadata.sh
. "$HERE/lib/metadata.sh"

TIMEOUT=${PREFLIGHT_TIMEOUT:-10s}
CLUSTER_ARG=${PREFLIGHT_CLUSTER:-}
CONTEXT_ARG=${KUBE_CONTEXT:-}
KUBECONFIG_ARG=""
CTX=""
PASS=0 WARN=0 FAIL=0 UNKNOWN=0
DENIED=()          # checks that could not be verified for lack of permission
UNV=""             # set by unverified()

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "preflight: $1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cluster)    [ "$#" -ge 2 ] || die "--cluster needs a value"; CLUSTER_ARG=$2; shift 2 ;;
    --context)    [ "$#" -ge 2 ] || die "--context needs a value"; CONTEXT_ARG=$2; shift 2 ;;
    --kubeconfig) [ "$#" -ge 2 ] || die "--kubeconfig needs a value"; KUBECONFIG_ARG=$2; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; die "unknown argument: $1" ;;
  esac
done
echo "$TIMEOUT" | grep -Eq '^[0-9]+(ms|s|m)?$' || die "PREFLIGHT_TIMEOUT must look like 10s, 30s or 1m (got: $TIMEOUT)"
[ -z "$KUBECONFIG_ARG" ] || [ -f "$KUBECONFIG_ARG" ] || die "--kubeconfig: no such file: $KUBECONFIG_ARG"

# ── output ──────────────────────────────────────────────────
result() {  # result PASS|WARN|FAIL|UNKNOWN <check> <message>
  case "$1" in
    PASS) PASS=$((PASS + 1)) ;; WARN) WARN=$((WARN + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;; UNKNOWN) UNKNOWN=$((UNKNOWN + 1)) ;;
  esac
  printf '[%s]%s %-30s %s\n' "$1" "$( [ "$1" = UNKNOWN ] || printf '%*s' $((7 - ${#1})) '')" "$2" "$3"
}
detail() { printf '          %s\n' "$@"; }

# ── 1. dependencies ─────────────────────────────────────────
echo "== Kubernetes preflight (read-only) =="
missing=""
for t in kubectl awk grep sed sort mktemp; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
  result FAIL "1 dependencies" "not found in PATH:$missing"
  exit 2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ── kubectl wrapper ─────────────────────────────────────────
# kc <args...> runs one kubectl call with the explicit kubeconfig/context and sets:
#   KC_OUT    stdout
#   KC_CLASS  ok | notfound | notserved | forbidden | unauthorized | timeout | unreachable | error
#   KC_WHY    first line of stderr (truncated), empty on ok
# Only notfound/notserved mean "absent"; every other failure means "could not verify".
kc() {
  local rc=0 a=(--request-timeout="$TIMEOUT")
  [ -z "$KUBECONFIG_ARG" ] || a+=(--kubeconfig="$KUBECONFIG_ARG")
  [ -z "$CTX" ] || a+=(--context="$CTX")
  KC_OUT=$(kubectl "${a[@]}" "$@" 2>"$TMP/err") || rc=$?
  KC_WHY=""
  if [ "$rc" -eq 0 ]; then KC_CLASS=ok; return 0; fi
  KC_WHY=$(grep -v '^[[:space:]]*$' "$TMP/err" | grep -v '^Warning:' | head -n 1 | cut -c 1-180 || true)
  [ -n "$KC_WHY" ] || KC_WHY="kubectl exited $rc with no error output"
  local err; err=$(cat "$TMP/err")
  case "$err" in
    *"(Forbidden)"*|*" forbidden: "*)                                  KC_CLASS=forbidden ;;
    *"(Unauthorized)"*|*"must be logged in"*|*"getting credentials"*)  KC_CLASS=unauthorized ;;
    *"(NotFound)"*)                                                    KC_CLASS=notfound ;;
    *"doesn't have a resource type"*)                                  KC_CLASS=notserved ;;
    *"Client.Timeout"*|*"deadline exceeded"*|*"i/o timeout"*|*"TLS handshake timeout"*|*"unable to return a response in the time allotted"*)
                                                                       KC_CLASS=timeout ;;
    *"connection refused"*|*"was refused"*|*"no such host"*|*"Unable to connect"*|*"dial tcp"*|*"no route to host"*|*"network is unreachable"*)
                                                                       KC_CLASS=unreachable ;;
    *)                                                                 KC_CLASS=error ;;
  esac
  return 0
}

# Sets UNV to the "could not verify" text of the last failed call and records permission
# denials for the summary. Called directly, never in $(...), so DENIED survives.
unverified() {  # unverified <check>
  case "$KC_CLASS" in
    forbidden|unauthorized) DENIED+=("$1: $KC_CLASS — $KC_WHY") ;;
  esac
  UNV="could not verify ($KC_CLASS): $KC_WHY"
}

minor_of() { echo "$1" | sed -n 's/^v\{0,1\}[0-9][0-9]*\.\([0-9][0-9]*\).*/\1/p'; }

kc version --client
CLIENT_VER=$(echo "$KC_OUT" | sed -n 's/^Client Version: //p' | head -n 1)
result PASS "1 dependencies" "kubectl ${CLIENT_VER:-(version unknown)}, awk, grep, sed, sort, mktemp"

# ── cluster metadata (optional) ─────────────────────────────
META="" META_CTX="" ENV_NAME="" APP_NS="" APP_PSA="" OWNER=""
if [ -n "$CLUSTER_ARG" ]; then
  META=$(meta_resolve_cluster "$CLUSTER_ARG" "$K8S")
  [ -n "$META" ] || die "--cluster: no environments/<env>/kubernetes/cluster/$CLUSTER_ARG.yaml and no such file (available: $(cd "$K8S" && ls -- */kubernetes/cluster/*.yaml | grep -vE '/(environment|target|target\.local)\.yaml$' | sed 's|.*/||; s/\.yaml$//' | tr '\n' ' '))"
  [ "$(meta_get "$META" schema)" = "kubernetes-environment/v1alpha1" ] || die "$META: not a kubernetes-environment/v1alpha1 cluster file"
  META_CTX=$(meta_get "$META" context)
  ENV_NAME=$(meta_get "$META" environment)
  OWNER=$(meta_get "$META" delivery.owner)
  ENV_FILE="$K8S/$(meta_env_dir "$ENV_NAME")/kubernetes/cluster/environment.yaml"
  if [ -f "$ENV_FILE" ]; then
    APP_NS=$(meta_get "$ENV_FILE" names.helmfile)   # namespace = Helm env name
    APP_PSA=$(meta_get "$ENV_FILE" security.podSecurityStandard)
  fi
fi

# ── 2. context: explicit, from metadata, or implicit — then pinned ─
kc config get-contexts -o name
[ "$KC_CLASS" = ok ] || { result FAIL "2 context" "cannot list kubeconfig contexts: $KC_WHY"; exit 2; }
CONTEXTS=$KC_OUT
kc config current-context
CURRENT=$( [ "$KC_CLASS" = ok ] && echo "$KC_OUT" || echo "(none)")

if [ -n "$CONTEXT_ARG" ]; then
  SELECTED=$CONTEXT_ARG HOW="explicit (--context / KUBE_CONTEXT)"
  if [ -n "$META" ] && ! meta_placeholder "$META_CTX" && [ "$META_CTX" != "$CONTEXT_ARG" ]; then
    result FAIL "2 context" "'$CONTEXT_ARG' is not the context of $(basename "$META") ('$META_CTX')"
    echo "          Fix the metadata or pass the matching context; preflight never guesses which one is right."
    exit 2
  fi
elif [ -n "$META" ]; then
  if meta_placeholder "$META_CTX"; then
    result FAIL "2 context" "$(basename "$META") still has context $META_CTX — pass --context <your-alias>"
    exit 2
  fi
  SELECTED=$META_CTX HOW="from cluster metadata $(basename "$META")"
else
  [ "$CURRENT" != "(none)" ] || { result FAIL "2 context" "no --context, no --cluster and no current-context"; exit 2; }
  SELECTED=$CURRENT HOW="IMPLICITLY SELECTED from current-context — pass --context to choose explicitly"
fi
if ! printf '%s\n' "$CONTEXTS" | grep -Fxq -- "$SELECTED"; then
  result FAIL "2 context" "context '$SELECTED' is not in kubeconfig${KUBECONFIG_ARG:+ $KUBECONFIG_ARG}"
  echo "          A context name is not proof that a cluster exists: create the cluster and its"
  echo "          kubeconfig entry first (providers/<provider>/README.md), then list: kubectl config get-contexts"
  exit 2
fi
CTX=$SELECTED   # every call below carries --context="$CTX"; current-context is never changed

echo "selected context: $CTX   ($HOW)"
echo "current-context:  $CURRENT$( [ "$CURRENT" = "$CTX" ] || echo '   (differs — not used)')"
echo "cluster metadata: ${META:-none (inventory only; capability requirements not evaluated)}"
[ -z "$META" ] || echo "environment:      $ENV_NAME (app namespace ${APP_NS:-?}), delivery owner $OWNER"
echo "kubeconfig:       ${KUBECONFIG_ARG:-${KUBECONFIG:-\$HOME/.kube/config (default)}}   (path only; never read or printed by this script)"
echo "timeout:          $TIMEOUT per request"
[ -n "$CONTEXT_ARG$META" ] || echo "WARNING:          context was implicitly selected; treat it as potentially production"
[ "$ENV_NAME" != production ] || echo "NOTE:             production cluster — every check is read-only; running it was your decision"
echo
result PASS "2 context" "$CTX exists in kubeconfig"

# ── 3. API server reachable ─────────────────────────────────
kc version
SERVER_VER=$(echo "$KC_OUT" | sed -n 's/^Server Version: //p' | head -n 1)
API_UP=false
if [ "$KC_CLASS" = ok ] && [ -n "$SERVER_VER" ]; then
  API_UP=true
  result PASS "3 API server reachable" "server $SERVER_VER"
elif [ "$KC_CLASS" = ok ]; then
  result FAIL "3 API server reachable" "kubectl version returned no server version"
else
  unverified "3 API server reachable"; result FAIL "3 API server reachable" "$UNV"
fi

if [ "$API_UP" != true ]; then
  # Nothing below can be verified; report each check once instead of timing out on each.
  result FAIL "4 nodes Ready" "not verified: API server unreachable"
  result FAIL "5 cluster DNS" "not verified: API server unreachable"
  for c in "6 version skew" "7 node details" "8 namespaces" "9 CNI DaemonSets" "10 StorageClasses" \
           "11 IngressClasses" "12 Gateway API" "13 Prometheus Operator CRDs" "14 controllers" \
           "15 API discovery" "16 RBAC (auth can-i)"; do
    result UNKNOWN "$c" "skipped: API server unreachable"
  done
  if [ -n "$META" ]; then
    for cap in $META_CAPABILITIES; do
      [ "$(meta_get "$META" "capabilities.$cap.expected")" = required ] && result FAIL "C $cap" "required, not verified: API server unreachable"
    done
  fi
else

# ── 4. nodes listed, at least one Ready ─────────────────────
kc get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.nodeInfo.kubeletVersion}{"\t"}{.status.nodeInfo.osImage}{"\t"}{.status.nodeInfo.architecture}{"\n"}{end}'
NODES_CLASS=$KC_CLASS NODES=$KC_OUT NODES_WHY=$KC_WHY
if [ "$KC_CLASS" = ok ]; then
  total=$(printf '%s\n' "$NODES" | awk 'NF' | wc -l | tr -d ' ')
  ready=$(printf '%s\n' "$NODES" | awk -F'\t' '$2 == "True"' | wc -l | tr -d ' ')
  if [ "$ready" -ge 1 ]; then
    result PASS "4 nodes Ready" "$ready/$total Ready"
  else
    result FAIL "4 nodes Ready" "$ready/$total Ready"
  fi
else
  unverified "4 nodes Ready"; result FAIL "4 nodes Ready" "$UNV"
fi

# ── 5. cluster DNS (k8s-app=kube-dns in kube-system) ────────
kc get deployments -n kube-system -l k8s-app=kube-dns \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.status.availableReplicas}{"\t"}{.spec.replicas}{"\n"}{end}'
if [ "$KC_CLASS" = ok ]; then
  dns=$(printf '%s\n' "$KC_OUT" | awk 'NF')
  avail=$(printf '%s\n' "$dns" | awk -F'\t' '$2 + 0 >= 1' | wc -l | tr -d ' ')
  if [ -z "$dns" ]; then
    result FAIL "5 cluster DNS" "absent: no Deployment labelled k8s-app=kube-dns in kube-system"
  elif [ "$avail" -ge 1 ]; then
    result PASS "5 cluster DNS" "$(printf '%s\n' "$dns" | awk -F'\t' '{printf "%s %s/%s available ", $1, ($2 == "" ? 0 : $2), $3}')"
  else
    result FAIL "5 cluster DNS" "no available replica: $(printf '%s\n' "$dns" | awk -F'\t' '{printf "%s %s/%s ", $1, ($2 == "" ? 0 : $2), $3}')"
  fi
else
  unverified "5 cluster DNS"; result FAIL "5 cluster DNS" "$UNV"
fi

# ── 6. client/server version skew ───────────────────────────
cmin=$(minor_of "${CLIENT_VER:-}") smin=$(minor_of "$SERVER_VER")
if [ -z "$cmin" ] || [ -z "$smin" ]; then
  result UNKNOWN "6 version skew" "could not parse versions (client '${CLIENT_VER:-?}', server '$SERVER_VER')"
else
  skew=$((cmin - smin)); [ "$skew" -lt 0 ] && skew=$((-skew))
  if [ "$skew" -le 1 ]; then
    result PASS "6 version skew" "client $CLIENT_VER, server $SERVER_VER (within ±1 minor)"
  else
    result WARN "6 version skew" "client $CLIENT_VER, server $SERVER_VER: $skew minors apart (kubectl supports ±1)"
  fi
fi

# ── 7. node details ─────────────────────────────────────────
if [ "$NODES_CLASS" = ok ]; then
  result PASS "7 node details" "name / Ready / kubelet / OS / arch:"
  printf '%s\n' "$NODES" | awk -F'\t' 'NF { printf "          %s  Ready=%s  %s  %s  %s\n", $1, $2, $3, $4, $5 }'
else
  KC_CLASS=$NODES_CLASS KC_WHY=$NODES_WHY
  unverified "7 node details"; result UNKNOWN "7 node details" "$UNV"
fi

# ── 8. namespaces ───────────────────────────────────────────
# With metadata: the app namespace (= Helm environment name) is the one that matters, and its
# live PSA `enforce` label is compared with <env>/cluster/environment.yaml.
# Otherwise: the namespaces this repository uses, as inventory. `production` and
# `monitoring` are not used by the repo; they make a naming mismatch visible.
ns_present="" ns_absent="" ns_unverified="" app_ns_state="" app_ns_psa=""
for ns in ${APP_NS:+$APP_NS} kube-system dev staging prod infra argocd observability production monitoring; do
  case " $ns_present $ns_absent $ns_unverified " in *" $ns "*|*" $ns("*) continue ;; esac
  kc get namespace "$ns" -o 'jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}'
  case "$KC_CLASS" in
    ok)       ns_present="$ns_present $ns" ;;
    notfound) ns_absent="$ns_absent $ns" ;;
    *)        ns_unverified="$ns_unverified $ns($KC_CLASS)"
              case "$KC_CLASS" in forbidden|unauthorized) DENIED+=("8 namespaces/$ns: $KC_CLASS — $KC_WHY") ;; esac ;;
  esac
  if [ "$ns" = "$APP_NS" ] && [ -z "$app_ns_state" ]; then app_ns_state=$KC_CLASS app_ns_psa=$KC_OUT; fi
done
if [ -n "$APP_NS" ]; then
  case "$app_ns_state" in
    ok)       if [ -z "$APP_PSA" ] || [ "$app_ns_psa" = "$APP_PSA" ]; then
                result PASS "8 namespaces" "app namespace '$APP_NS' present, PSA enforce=${app_ns_psa:-none}"
              else
                result WARN "8 namespaces" "app namespace '$APP_NS' enforces PSA '${app_ns_psa:-none}', expected '$APP_PSA' ($(meta_env_dir "$ENV_NAME")/cluster/environment.yaml)"
              fi ;;
    notfound) case "$OWNER" in
                argocd)   hint="Argo CD creates it on first sync (CreateNamespace=true); environments/<env>/kubernetes/namespace/namespaces.yaml pre-creates it with PSA" ;;
                helmfile) hint="create it with its PSA labels before the first sync (environments/$APP_NS/kubernetes/namespace/namespaces.yaml) — helm would create it unlabelled" ;;
                *)        hint="create it through the owning pipeline" ;;
              esac
              result WARN "8 namespaces" "app namespace '$APP_NS' absent — $hint" ;;
    *)        result UNKNOWN "8 namespaces" "app namespace '$APP_NS' could not be verified" ;;
  esac
elif [ -n "$ns_unverified" ]; then
  result UNKNOWN "8 namespaces" "some namespaces could not be verified"
else
  result PASS "8 namespaces" "inventory:"
fi
detail "present:${ns_present:- none}" "absent:${ns_absent:- none}" "could not verify:${ns_unverified:- none}"

# ── workload inventory (used by 9, 14 and the capability checks) ─
# <ns> <name> <available|ready> <desired> <label app.kubernetes.io/name> <label app>
kc get deployments -A \
  -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.availableReplicas}{"\t"}{.spec.replicas}{"\t"}{.metadata.labels.app\.kubernetes\.io/name}{"\t"}{.metadata.labels.app}{"\n"}{end}'
DEP_CLASS=$KC_CLASS DEP=$KC_OUT DEP_WHY=$KC_WHY
kc get daemonsets -A \
  -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.numberReady}{"\t"}{.status.desiredNumberScheduled}{"\t"}{.metadata.labels.app\.kubernetes\.io/name}{"\t"}{.metadata.labels.app}{"\n"}{end}'
DS_CLASS=$KC_CLASS DS=$KC_OUT DS_WHY=$KC_WHY

# workload_available <regex> → 0 found and available · 1 not found / not available · 2 unknown
# Matches name and both name labels, case-insensitively, across Deployments and DaemonSets.
WL_MATCH=""
workload_available() {
  WL_MATCH=$(printf '%s\n%s\n' "$DEP" "$DS" | awk -F'\t' -v re="$1" 'NF && (tolower($2) ~ re || tolower($5) ~ re || tolower($6) ~ re) { printf "%s/%s %s/%s\n", $1, $2, ($3 == "" ? 0 : $3), $4 }')
  if printf '%s\n%s\n' "$DEP" "$DS" | awk -F'\t' -v re="$1" 'NF && (tolower($2) ~ re || tolower($5) ~ re || tolower($6) ~ re) && $3 + 0 >= 1 { ok = 1 } END { exit !ok }'; then
    return 0
  fi
  [ "$DEP_CLASS" = ok ] && [ "$DS_CLASS" = ok ] && return 1
  return 2
}

# ── 9. CNI-related DaemonSets (presence only) ───────────────
if [ "$DS_CLASS" = ok ]; then
  cni=$(printf '%s\n' "$DS" | awk -F'\t' '$2 ~ /^(aws-node|calico-node|cilium|kube-flannel(-ds)?|weave-net|kube-proxy|kube-router|canal|antrea-agent)$/')
  if [ -z "$cni" ]; then
    result WARN "9 CNI DaemonSets" "none of the known names found — not evidence of a broken CNI (k3s embeds flannel; see providers/)"
  elif printf '%s\n' "$cni" | awk -F'\t' '$3 + 0 < $4 + 0 { bad = 1 } END { exit !bad }'; then
    result WARN "9 CNI DaemonSets" "found, some not fully ready (ready/desired):"
  else
    result PASS "9 CNI DaemonSets" "found (ready/desired):"
  fi
  [ -z "$cni" ] || printf '%s\n' "$cni" | awk -F'\t' '{ printf "          %s/%s %s/%s\n", $1, $2, ($3 == "" ? 0 : $3), $4 }'
else
  KC_CLASS=$DS_CLASS KC_WHY=$DS_WHY
  unverified "9 CNI DaemonSets"; result UNKNOWN "9 CNI DaemonSets" "$UNV"
fi

# ── 10. StorageClasses and the default ──────────────────────
kc get storageclasses \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.provisioner}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
SC_CLASS=$KC_CLASS SC=$(printf '%s\n' "$KC_OUT" | awk 'NF') SC_WHY=$KC_WHY
SC_DEFAULT=$(printf '%s\n' "$SC" | awk -F'\t' '$3 == "true"')
if [ "$SC_CLASS" = ok ]; then
  ndef=$(printf '%s\n' "$SC_DEFAULT" | awk 'NF' | wc -l | tr -d ' ')
  if [ -z "$SC" ]; then
    result WARN "10 StorageClasses" "absent: no StorageClass (dynamic PV provisioning unavailable)"
  elif [ "$ndef" -eq 1 ]; then
    result PASS "10 StorageClasses" "exactly one default:"
  elif [ "$ndef" -eq 0 ]; then
    result WARN "10 StorageClasses" "none marked default — PVCs without storageClassName stay Pending:"
  else
    result WARN "10 StorageClasses" "$ndef marked default — ambiguous:"
  fi
  [ -z "$SC" ] || printf '%s\n' "$SC" | awk -F'\t' '{ printf "          %s  provisioner=%s%s\n", $1, $2, ($3 == "true" ? "  (default)" : "") }'
elif [ "$SC_CLASS" = notserved ]; then
  result WARN "10 StorageClasses" "absent: storageclasses not served by API discovery"
else
  unverified "10 StorageClasses"; result UNKNOWN "10 StorageClasses" "$UNV"
fi

# ── 11. IngressClasses and the default ──────────────────────
kc get ingressclasses \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.spec.controller}{"\t"}{.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
IC_CLASS=$KC_CLASS IC=$(printf '%s\n' "$KC_OUT" | awk 'NF') IC_WHY=$KC_WHY
if [ "$IC_CLASS" = ok ]; then
  ndef=$(printf '%s\n' "$IC" | awk -F'\t' '$3 == "true"' | wc -l | tr -d ' ')
  if [ -z "$IC" ]; then
    result WARN "11 IngressClasses" "absent: no IngressClass (no ingress controller registered)"
  elif [ "$ndef" -gt 1 ]; then
    result WARN "11 IngressClasses" "$ndef marked default — ambiguous:"
  else
    result PASS "11 IngressClasses" "$( [ "$ndef" -eq 1 ] && echo "one default:" || echo "none default (apps must set ingressClassName):")"
  fi
  [ -z "$IC" ] || printf '%s\n' "$IC" | awk -F'\t' '{ printf "          %s  controller=%s%s\n", $1, $2, ($3 == "true" ? "  (default)" : "") }'
elif [ "$IC_CLASS" = notserved ]; then
  result WARN "11 IngressClasses" "absent: ingressclasses not served by API discovery"
else
  unverified "11 IngressClasses"; result UNKNOWN "11 IngressClasses" "$UNV"
fi

# ── API discovery (used by 12, 13, 15) ──────────────────────
# A partial discovery failure exits non-zero but still lists what it got; a group named in
# the error is "could not verify", any other missing group is confirmed absent.
kc api-resources -o name
DISC_CLASS=$KC_CLASS DISC=$KC_OUT DISC_WHY=$KC_WHY DISC_ERR=""
if [ "$KC_CLASS" != ok ] && [ -n "$KC_OUT" ]; then
  DISC_CLASS=partial DISC_ERR=$(cat "$TMP/err")
fi
served() {  # served <resource.group> → 0 served · 1 absent · 2 unknown
  case "$DISC_CLASS" in
    ok|partial) ;;
    *) return 2 ;;
  esac
  printf '%s\n' "$DISC" | grep -Fxq -- "$1" && return 0
  local group=${1#*.}
  [ "$DISC_CLASS" = partial ] && printf '%s\n' "$DISC_ERR" | grep -Fq -- "$group" && return 2
  return 1
}
disc_unverified() {
  KC_CLASS=$DISC_CLASS KC_WHY=$DISC_WHY
  unverified "$1"
}

# ── 12. Gateway API: CRDs, then GatewayClasses accepted by a controller ─
gw_present="" gw_absent="" gw_unknown="" GW_CLASSES="" GWC_CLASS=""
for r in gatewayclasses gateways httproutes grpcroutes referencegrants; do
  set +e; served "$r.gateway.networking.k8s.io"; s=$?; set -e
  case "$s" in 0) gw_present="$gw_present $r" ;; 1) gw_absent="$gw_absent $r" ;; *) gw_unknown="$gw_unknown $r" ;; esac
done
if [ "$DISC_CLASS" != ok ] && [ "$DISC_CLASS" != partial ]; then
  disc_unverified "12 Gateway API"; result UNKNOWN "12 Gateway API" "$UNV"
elif [ -n "$gw_unknown" ]; then
  result UNKNOWN "12 Gateway API" "could not verify (partial discovery):$gw_unknown"
elif [ -z "$gw_present" ]; then
  result WARN "12 Gateway API" "absent: gateway.networking.k8s.io not served by API discovery"
else
  kc get gatewayclasses -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.spec.controllerName}{"\t"}{.status.conditions[?(@.type=="Accepted")].status}{"\n"}{end}'
  GWC_CLASS=$KC_CLASS GW_CLASSES=$(printf '%s\n' "$KC_OUT" | awk 'NF')
  result PASS "12 Gateway API" "CRDs served:$gw_present${gw_absent:+ · absent:$gw_absent}"
  if [ "$GWC_CLASS" = ok ]; then
    if [ -n "$GW_CLASSES" ]; then
      printf '%s\n' "$GW_CLASSES" | awk -F'\t' '{ printf "          GatewayClass %s  controller=%s  Accepted=%s\n", $1, $2, ($3 == "" ? "unknown" : $3) }'
    else detail "no GatewayClass: CRDs without a controller route nothing"; fi
  else
    unverified "12 Gateway API/gatewayclasses"; detail "GatewayClasses: $UNV"
  fi
fi

# ── 13. Prometheus Operator CRDs (the API only, not the operator) ─
pm_lines="" pm_bad=false pm_unknown=false PR_CRD=""
for r in prometheusrules servicemonitors podmonitors; do
  kc get crd "$r.monitoring.coreos.com" -o 'jsonpath={.status.conditions[?(@.type=="Established")].status}'
  case "$KC_CLASS" in
    ok)       if [ "$KC_OUT" = True ]; then st=established; else st=not-established; pm_bad=true; fi ;;
    notfound) st=absent; pm_bad=true ;;
    *)        # cannot read CRDs: fall back to API discovery, which says served or not
              set +e; served "$r.monitoring.coreos.com"; s=$?; set -e
              case "$s" in
                0) st=served ;;
                1) st=absent; pm_bad=true ;;
                *) st=unverified; pm_unknown=true ;;
              esac
              case "$KC_CLASS" in forbidden|unauthorized) DENIED+=("13 crd/$r: $KC_CLASS — $KC_WHY") ;; esac ;;
  esac
  pm_lines="$pm_lines $r=$st"
  [ "$r" != prometheusrules ] || PR_CRD=$st
done
if [ "$pm_unknown" = true ]; then
  result UNKNOWN "13 Prometheus Operator CRDs" "could not verify:$pm_lines"
elif [ "$pm_bad" = true ]; then
  result WARN "13 Prometheus Operator CRDs" "absent or not established:$pm_lines"
else
  result PASS "13 Prometheus Operator CRDs" "$pm_lines (CRDs only — operator: see 14 / capability check)"
fi

# ── 14. controller workloads (discovered by name or name label) ─
CTL_RE='ingress-nginx|ingress-controller|traefik|kong|haproxy|contour|envoy-gateway|istiod|argocd-server|argocd-repo-server|argocd-applicationset|cert-manager|aws-load-balancer-controller|csi|local-path-provisioner|nfs-provisioner|external-dns|external-secrets|kyverno|prometheus-operator|kube-prometheus-stack-operator|metrics-server|karpenter|cluster-autoscaler'
if [ "$DEP_CLASS" = ok ] || [ "$DS_CLASS" = ok ]; then
  set +e; workload_available "$CTL_RE"; set -e
  if [ -z "$WL_MATCH" ]; then
    result WARN "14 controllers" "no known controller Deployment/DaemonSet discovered"
  elif printf '%s\n' "$WL_MATCH" | awk '{ split($2, r, "/"); if (r[1] + 0 < r[2] + 0) bad = 1 } END { exit !bad }'; then
    result WARN "14 controllers" "discovered, some not fully available (available/desired):"
  else
    result PASS "14 controllers" "discovered (available/desired):"
  fi
  [ -z "$WL_MATCH" ] || printf '%s\n' "$WL_MATCH" | sort | sed 's/^/          /'
  [ "$DEP_CLASS" = ok ] || { KC_CLASS=$DEP_CLASS KC_WHY=$DEP_WHY; unverified "14 controllers/deployments"; detail "Deployments: $UNV"; }
  [ "$DS_CLASS" = ok ]  || { KC_CLASS=$DS_CLASS KC_WHY=$DS_WHY; unverified "14 controllers/daemonsets"; detail "DaemonSets: $UNV"; }
  detail "(name match only; StatefulSets such as argocd-application-controller are not listed)"
else
  KC_CLASS=$DEP_CLASS KC_WHY=$DEP_WHY
  unverified "14 controllers"; result UNKNOWN "14 controllers" "$UNV"
fi

# ── 15. API discovery for the groups above ──────────────────
if [ "$DISC_CLASS" = ok ] || [ "$DISC_CLASS" = partial ]; then
  groups=$(printf '%s\n' "$DISC" | awk -F. 'NF > 1 { sub(/^[^.]*\./, ""); print }' | sort -u)
  g_lines=""
  for g in networking.k8s.io storage.k8s.io apiextensions.k8s.io gateway.networking.k8s.io \
           monitoring.coreos.com argoproj.io cert-manager.io elbv2.k8s.aws external-secrets.io \
           kyverno.io helm.cattle.io; do
    if printf '%s\n' "$groups" | grep -Fxq -- "$g"; then g_lines="$g_lines $g=served"
    elif [ "$DISC_CLASS" = partial ] && printf '%s\n' "$DISC_ERR" | grep -Fq -- "$g"; then g_lines="$g_lines $g=unverified"
    else g_lines="$g_lines $g=absent"; fi
  done
  if [ "$DISC_CLASS" = partial ]; then
    result WARN "15 API discovery" "partial: $DISC_WHY"
  else
    result PASS "15 API discovery" "complete"
  fi
  for l in $g_lines; do detail "$l"; done
else
  disc_unverified "15 API discovery"; result UNKNOWN "15 API discovery" "$UNV"
fi

# ── 16. RBAC of the caller (SelfSubjectAccessReview) ────────
# `auth can-i` exits 1 for "no", so the answer is read from stdout, not the exit code.
rbac_no="" rbac_err=""
while IFS='|' read -r label args; do
  # shellcheck disable=SC2086  # $args is a fixed word list defined just below
  kc auth can-i $args
  answer=$(printf '%s\n' "$KC_OUT" | head -n 1)
  if [ "$answer" = yes ]; then detail "yes  $label"
  elif [ "$answer" = no ]; then detail "no   $label"; rbac_no="$rbac_no; $label"
  else detail "?    $label ($KC_CLASS: $KC_WHY)"; rbac_err="$rbac_err; $label"
  fi
done <<'EOF'
get namespaces|get namespaces
list nodes|list nodes
list customresourcedefinitions|list customresourcedefinitions.apiextensions.k8s.io
list storageclasses|list storageclasses.storage.k8s.io
list ingressclasses|list ingressclasses.networking.k8s.io
list deployments -A|list deployments.apps --all-namespaces
list daemonsets -A|list daemonsets.apps --all-namespaces
EOF
if [ -n "$rbac_err" ]; then
  result UNKNOWN "16 RBAC (auth can-i)" "could not evaluate:${rbac_err#;}"
elif [ -n "$rbac_no" ]; then
  result WARN "16 RBAC (auth can-i)" "denied:${rbac_no#;} — the matching checks report UNKNOWN, never absent"
else
  result PASS "16 RBAC (auth can-i)" "all read permissions granted"
fi

# ── C. capabilities required by workloads (only with --cluster) ─
# Each capability is evaluated from the live cluster; metadata only says how much it matters.
#   requires: api        the API types exist (IngressClass / CRDs / default StorageClass)
#   requires: controller (default) the API exists AND a controller acting on it is running
# CAP_STATE: ok | absent | degraded | unknown, CAP_MSG: evidence.
eval_ingress() {
  if [ "$IC_CLASS" = notserved ] || { [ "$IC_CLASS" = ok ] && [ -z "$IC" ]; }; then
    CAP_STATE=absent CAP_MSG="no IngressClass"; return
  fi
  [ "$IC_CLASS" = ok ] || { CAP_STATE=unknown CAP_MSG="IngressClasses not readable ($IC_CLASS)"; return; }
  if [ "$1" = api ]; then CAP_STATE=ok CAP_MSG="IngressClass: $(printf '%s\n' "$IC" | awk -F'\t' '{printf "%s ", $1}')"; return; fi
  local name ctl re found="" unknown=""
  while IFS="$(printf '\t')" read -r name ctl _; do
    case "$ctl" in
      k8s.io/ingress-nginx)            re='ingress-nginx' ;;
      traefik.io/*)                    re='traefik' ;;
      ingress.k8s.aws/alb)             re='aws-load-balancer-controller' ;;
      *konghq.com/*)                   re='kong' ;;
      *haproxy*)                       re='haproxy' ;;
      *contour*)                       re='contour' ;;
      *)                               re=$(echo "${ctl##*/}" | tr '[:upper:]' '[:lower:]') ;;
    esac
    set +e; workload_available "$re"; s=$?; set -e
    case "$s" in
      0) found="$found ${name} → $(printf '%s\n' "$WL_MATCH" | head -n 1)" ;;
      2) unknown="$unknown $name" ;;
    esac
  done <<EOF
$IC
EOF
  if [ -n "$found" ]; then CAP_STATE=ok CAP_MSG="class + available controller:$found"
  elif [ -n "$unknown" ]; then CAP_STATE=unknown CAP_MSG="IngressClass present; controller workloads not readable"
  else CAP_STATE=degraded CAP_MSG="IngressClass present but no available controller workload found for it"
  fi
}
eval_gatewayAPI() {
  if [ "$DISC_CLASS" != ok ] && [ "$DISC_CLASS" != partial ]; then CAP_STATE=unknown CAP_MSG="API discovery failed"; return; fi
  case " $gw_present " in *" gatewayclasses "*) ;; *)
    if [ -n "$gw_unknown" ]; then CAP_STATE=unknown CAP_MSG="partial discovery"; else CAP_STATE=absent CAP_MSG="Gateway API CRDs not served"; fi
    return ;;
  esac
  if [ "$1" = api ]; then CAP_STATE=ok CAP_MSG="CRDs served:$gw_present"; return; fi
  [ "$GWC_CLASS" = ok ] || { CAP_STATE=unknown CAP_MSG="GatewayClasses not readable ($GWC_CLASS)"; return; }
  if printf '%s\n' "$GW_CLASSES" | awk -F'\t' '$3 == "True" { ok = 1 } END { exit !ok }'; then
    CAP_STATE=ok CAP_MSG="GatewayClass Accepted: $(printf '%s\n' "$GW_CLASSES" | awk -F'\t' '$3 == "True" {printf "%s(%s) ", $1, $2}')"
  else
    CAP_STATE=degraded CAP_MSG="CRDs served, but no GatewayClass is Accepted by a controller"
  fi
}
eval_prometheusOperator() {
  case "$PR_CRD" in
    established|served) ;;
    absent)             CAP_STATE=absent CAP_MSG="PrometheusRule CRD absent"; return ;;
    not-established)    CAP_STATE=degraded CAP_MSG="PrometheusRule CRD not Established"; return ;;
    *)                  CAP_STATE=unknown CAP_MSG="PrometheusRule CRD could not be verified"; return ;;
  esac
  if [ "$1" = api ]; then CAP_STATE=ok CAP_MSG="PrometheusRule CRD $PR_CRD"; return; fi
  set +e; workload_available 'prometheus-operator|kube-prometheus-stack-operator|prometheus.*-operator$'; s=$?; set -e
  case "$s" in
    0) CAP_STATE=ok CAP_MSG="CRD $PR_CRD + operator $(printf '%s\n' "$WL_MATCH" | head -n 1)" ;;
    1) CAP_STATE=degraded CAP_MSG="CRD $PR_CRD, but no available Prometheus Operator workload — rules would be stored and never evaluated" ;;
    *) CAP_STATE=unknown CAP_MSG="CRD $PR_CRD; operator workloads not readable" ;;
  esac
}
eval_persistentStorage() {
  if [ "$SC_CLASS" = notserved ] || { [ "$SC_CLASS" = ok ] && [ -z "$SC" ]; }; then
    CAP_STATE=absent CAP_MSG="no StorageClass"; return
  fi
  [ "$SC_CLASS" = ok ] || { CAP_STATE=unknown CAP_MSG="StorageClasses not readable ($SC_CLASS)"; return; }
  local n prov re
  n=$(printf '%s\n' "$SC_DEFAULT" | awk 'NF' | wc -l | tr -d ' ')
  [ "$n" -eq 1 ] || { CAP_STATE=degraded CAP_MSG="$n default StorageClasses (need exactly one)"; return; }
  prov=$(printf '%s\n' "$SC_DEFAULT" | awk -F'\t' '{print $2}')
  if [ "$1" = api ]; then CAP_STATE=ok CAP_MSG="default StorageClass, provisioner $prov"; return; fi
  case "$prov" in
    ebs.csi.aws.com|kubernetes.io/aws-ebs) re='ebs-csi' ;;
    efs.csi.aws.com)                       re='efs-csi' ;;
    rancher.io/local-path)                 re='local-path-provisioner' ;;
    driver.longhorn.io)                    re='longhorn' ;;
    *.csi.*|*csi*)                         re='csi' ;;
    docker.io/hostpath|k8s.io/minikube-hostpath)
      # Docker Desktop / minikube run the provisioner as a bare Pod in kube-system.
      kc get pods -n kube-system -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
      if [ "$KC_CLASS" != ok ]; then unverified "C persistentStorage"; CAP_STATE=unknown CAP_MSG="kube-system pods not readable"; return; fi
      if printf '%s\n' "$KC_OUT" | awk -F'\t' '$1 ~ /storage-provisioner|hostpath/ && $2 == "Running" { ok = 1 } END { exit !ok }'; then
        CAP_STATE=ok CAP_MSG="default StorageClass ($prov) + running provisioner pod"
      else
        CAP_STATE=degraded CAP_MSG="default StorageClass ($prov), no running provisioner pod in kube-system"
      fi
      return ;;
    *) CAP_STATE=unknown CAP_MSG="provisioner '$prov' has no known controller to look for — verify manually"; return ;;
  esac
  set +e; workload_available "$re"; s=$?; set -e
  case "$s" in
    0) CAP_STATE=ok CAP_MSG="default StorageClass ($prov) + controller $(printf '%s\n' "$WL_MATCH" | head -n 1)" ;;
    1) CAP_STATE=degraded CAP_MSG="default StorageClass ($prov), no available '$re' workload" ;;
    *) CAP_STATE=unknown CAP_MSG="default StorageClass ($prov); controller workloads not readable" ;;
  esac
}

if [ -n "$META" ]; then
  echo
  echo "== Capabilities required by workloads ($(basename "$META")) =="
  for cap in $META_CAPABILITIES; do
    expected=$(meta_get "$META" "capabilities.$cap.expected")
    requires=$(meta_get "$META" "capabilities.$cap.requires"); requires=${requires:-controller}
    recorded=$(meta_get "$META" "capabilities.$cap.verified")
    if [ "$expected" = not-used ]; then
      printf '%-10sC %-28s %s\n' '' "$cap" 'not-used — not evaluated'
      continue
    fi
    "eval_$cap" "$requires"
    label="C $cap ($expected, $requires)"
    case "$expected:$CAP_STATE" in
      *:ok)              result PASS "$label" "$CAP_MSG" ;;
      required:unknown)  result FAIL "$label" "required, could not verify: $CAP_MSG" ;;
      required:*)        result FAIL "$label" "required, $CAP_STATE: $CAP_MSG" ;;
      optional:unknown)  result UNKNOWN "$label" "$CAP_MSG" ;;
      *)                 result WARN "$label" "$CAP_STATE: $CAP_MSG" ;;
    esac
    case "$recorded:$CAP_STATE" in
      present:absent|present:degraded|absent:ok)
        detail "metadata records verified=$recorded ($(meta_get "$META" "capabilities.$cap.verifiedOn")) — stale; the live result above wins" ;;
    esac
  done
fi

fi  # API_UP

# ── summary ─────────────────────────────────────────────────
echo
echo "== Summary for context: $CTX${META:+ ($(basename "$META"))} =="
echo "PASS $PASS · WARN $WARN · UNKNOWN $UNKNOWN · FAIL $FAIL"
if [ "${#DENIED[@]}" -gt 0 ]; then
  echo "Not verified for lack of permission:"
  for d in "${DENIED[@]}"; do echo "  - $d"; done
else
  echo "Not verified for lack of permission: none"
fi
[ "$FAIL" -eq 0 ] && exit 0
exit 1
