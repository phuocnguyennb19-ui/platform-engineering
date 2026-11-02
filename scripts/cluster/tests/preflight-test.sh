#!/usr/bin/env bash
# Tests for scripts/preflight.sh against a stub kubectl — no cluster, no network.
# The stub (written to a temp dir, prepended to PATH) answers by scenario:
#   STUB_MODE=ok         healthy cluster: ingress-nginx, PrometheusRule CRD + operator, default SC
#   STUB_MODE=notfound   CoreDNS, IngressClass, CRDs and StorageClass API absent
#   STUB_MODE=forbidden  every read Forbidden except discovery and version
#   STUB_MODE=conn       API server refuses connections
#   STUB_NO_OPERATOR=1   with ok: CRDs present, no Prometheus Operator workload
#   STUB_PSA=<level>     PSA enforce label on namespace `dev` (default restricted)
#
#   bash scripts/cluster/tests/preflight-test.sh        # make k8s-env-test
set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PREFLIGHT="$HERE/../preflight.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/preflight-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
args=" $* "
mode=${STUB_MODE:-ok}
forbid() { echo "Error from server (Forbidden): $1 is forbidden: User \"tester\" cannot list resource \"$1\"" >&2; exit 1; }
conn()   { echo "The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?" >&2; exit 1; }
nf()     { echo "Error from server (NotFound): $1 not found" >&2; exit 1; }
case "$args" in
  *" config get-contexts "*)   printf 'docker-desktop\nk3s-dev\neks-dev-alias\n'; exit 0 ;;
  *" config current-context "*) echo k3s-dev; exit 0 ;;
  *" version --client "*)      echo "Client Version: v1.32.2"; exit 0 ;;
  *" version "*)               echo "Client Version: v1.32.2"; [ "$mode" = conn ] && conn; echo "Server Version: v1.32.4"; exit 0 ;;
esac
[ "$mode" = conn ] && conn
case "$args" in
  *" auth can-i "*) if [ "$mode" = forbidden ]; then echo no; exit 1; fi; echo yes; exit 0 ;;
  *" api-resources "*)
    printf 'pods\nnodes\ningressclasses.networking.k8s.io\nstorageclasses.storage.k8s.io\n'
    [ "$mode" = ok ] && printf 'prometheusrules.monitoring.coreos.com\nservicemonitors.monitoring.coreos.com\npodmonitors.monitoring.coreos.com\n'
    exit 0 ;;
esac
[ "$mode" = forbidden ] && forbid thing
case "$args" in
  *" get nodes "*) printf 'node-a\tTrue\tv1.32.4\tDocker Desktop\tarm64\n' ;;
  *" get deployments -n kube-system -l k8s-app=kube-dns "*)
    [ "$mode" = notfound ] && { echo "No resources found in kube-system namespace." >&2; exit 0; }
    printf 'coredns\t2\t2\n' ;;
  *" get namespace "*)
    ns=$(echo "$args" | sed 's/.* get namespace \([^ ]*\).*/\1/')
    case "$ns" in kube-system) printf '' ;; dev) printf '%s' "${STUB_PSA:-restricted}" ;; *) nf "namespaces \"$ns\"" ;; esac ;;
  *" get deployments -A "*)
    printf 'kube-system\tcoredns\t2\t2\t\tcoredns\n'
    if [ "$mode" = ok ]; then
      printf 'ingress-nginx\tingress-nginx-controller\t1\t1\tingress-nginx\t\n'
      [ -n "${STUB_NO_OPERATOR:-}" ] || printf 'observability\tkps-operator\t1\t1\t\tkube-prometheus-stack-operator\n'
    fi ;;
  *" get daemonsets -A "*) printf 'kube-system\tkube-proxy\t1\t1\t\tkube-proxy\n' ;;
  *" get storageclasses "*)
    [ "$mode" = notfound ] && { echo 'error: the server doesn'"'"'t have a resource type "storageclasses"' >&2; exit 1; }
    printf 'hostpath\tdocker.io/hostpath\ttrue\n' ;;
  *" get ingressclasses "*) [ "$mode" = notfound ] && exit 0; printf 'nginx\tk8s.io/ingress-nginx\t\n' ;;
  *" get crd "*) [ "$mode" = ok ] && { printf True; exit 0; }; nf 'customresourcedefinitions "x"' ;;
  *" get pods -n kube-system "*) printf 'storage-provisioner\tRunning\ncoredns-1\tRunning\n' ;;
  *) echo "stub: unexpected: $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$T/bin/kubectl"

fails=0 n=0
run() {  # run <name> <expected-exit> [env=val...] -- [preflight args...]
  local name=$1 want=$2; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "$#" -eq 0 ] || shift
  : > "$T/log"
  set +e
  env -u KUBE_CONTEXT -u PREFLIGHT_CLUSTER STUB_LOG="$T/log" PATH="$T/bin:$PATH" ${envs[@]+"${envs[@]}"} \
    bash "$PREFLIGHT" "$@" > "$T/out" 2>&1
  GOT=$?
  set -e
  n=$((n + 1))
  if [ "$GOT" -eq "$want" ]; then echo "ok    $name (exit $GOT)"
  else echo "FAIL  $name: exit $GOT, want $want"; sed 's/^/      | /' "$T/out"; fails=$((fails + 1)); fi
}
expect() {  # expect <description> <grep -E pattern>
  n=$((n + 1))
  if grep -Eq -- "$2" "$T/out"; then echo "ok      └ $1"
  else echo "FAIL    └ $1 (no match for: $2)"; sed 's/^/      | /' "$T/out"; fails=$((fails + 1)); fi
}
refute() {  # refute <description> <grep -E pattern>
  n=$((n + 1))
  if grep -Eq -- "$2" "$T/out"; then echo "FAIL    └ $1"; grep -E -- "$2" "$T/out" | sed 's/^/      | /'; fails=$((fails + 1))
  else echo "ok      └ $1"; fi
}

run "healthy docker-desktop dev cluster from metadata" 0 STUB_MODE=ok -- --cluster docker-desktop-dev
expect "context taken from metadata"            'selected context: docker-desktop +\(from cluster metadata docker-desktop-dev.yaml\)'
expect "ingress: class + running controller"    '^\[PASS\] +C ingress \(optional, controller\) +class \+ available controller'
expect "prometheusOperator CRD + operator pass" '^\[PASS\] +C prometheusOperator \(optional, controller\)'
expect "storage: default SC + provisioner pod"  '^\[PASS\] +C persistentStorage'
expect "gatewayAPI not-used is not evaluated"   'C gatewayAPI +not-used'
expect "app namespace present, PSA matches"     "^\[PASS\] +8 namespaces +app namespace 'dev' present, PSA enforce=restricted"
cp "$T/log" "$T/log.ok"

run "CRD present, operator missing (requires controller)" 1 STUB_MODE=ok STUB_NO_OPERATOR=1 -- --cluster "$HERE/fixtures/required-operator.yaml" --context eks-dev-alias
expect "CRD alone does not pass the capability" '^\[FAIL\] +C prometheusOperator \(required, controller\) +required, degraded: .*no available Prometheus Operator'
expect "placeholder context accepted with --context" 'selected context: eks-dev-alias'
expect "app namespace PSA matches dev/cluster/environment.yaml" "^\[PASS\] +8 namespaces +app namespace 'dev' present, PSA enforce=restricted"

run "app namespace PSA differs from the environment" 1 STUB_MODE=ok STUB_NO_OPERATOR=1 STUB_PSA=baseline -- --cluster "$HERE/fixtures/required-operator.yaml" --context eks-dev-alias
expect "PSA mismatch is a WARN"                 "^\[WARN\] +8 namespaces +app namespace 'dev' enforces PSA 'baseline', expected 'restricted'"

run "required capabilities absent" 1 STUB_MODE=notfound -- --cluster eks-dev --context eks-dev-alias
expect "DNS absent is FAIL"                     '^\[FAIL\] +5 cluster DNS +absent'
expect "required ingress absent is FAIL"        '^\[FAIL\] +C ingress .*required, absent'
expect "optional storage absent is WARN"        '^\[WARN\] +C persistentStorage .*absent'

run "everything forbidden" 1 STUB_MODE=forbidden -- --cluster eks-dev --context eks-dev-alias
expect "required check unverifiable is FAIL"    '^\[FAIL\] +4 nodes Ready +could not verify \(forbidden\)'
expect "optional check unverifiable is UNKNOWN" '^\[UNKNOWN\] 10 StorageClasses +could not verify \(forbidden\)'
expect "required capability unverifiable FAIL"  '^\[FAIL\] +C ingress .*required, could not verify'
expect "denials listed in the summary"          '^  - 4 nodes Ready: forbidden'
refute "forbidden is never reported absent"     '^\[[A-Z]+\] +(4|5|7|9|10|11|14) [^ ]+.*absent'
refute "no capability reported absent"          '^\[[A-Z]+\] +C (ingress|persistentStorage).*absent'

run "API server unreachable" 1 STUB_MODE=conn -- --cluster eks-dev --context eks-dev-alias
expect "classified unreachable"                 '^\[FAIL\] +3 API server reachable +could not verify \(unreachable\)'
expect "required capability not verified"       '^\[FAIL\] +C ingress +required, not verified'

run "implicit context is flagged" 0 STUB_MODE=ok --
expect "warning printed"                        'IMPLICITLY SELECTED'
expect "inventory only without metadata"        'cluster metadata: none'

run "explicit kubeconfig is passed, not exported" 0 STUB_MODE=ok -- --context docker-desktop --kubeconfig "$PREFLIGHT"
n=$((n + 1))
if grep -v -- "--kubeconfig=$PREFLIGHT" "$T/log" | grep -q .; then echo "FAIL    └ a kubectl call lacked --kubeconfig"; fails=$((fails + 1))
else echo "ok      └ every kubectl call carries --kubeconfig"; fi

run "metadata context mismatch"     2 STUB_MODE=ok -- --cluster docker-desktop-dev --context k3s-dev
run "placeholder without --context" 2 STUB_MODE=ok -- --cluster eks-dev
run "unknown cluster metadata"      2 STUB_MODE=ok -- --cluster nope
run "context not in kubeconfig"     2 STUB_MODE=ok -- --context prod-eks
run "unknown argument"              2 -- --bogus
run "bad timeout"                   2 PREFLIGHT_TIMEOUT=abc --
run "kubectl missing"               2 PATH=/usr/bin:/bin -- --context docker-desktop

# Every call after context selection is pinned; only read verbs are ever used.
n=$((n + 1))
pinned=$(grep -v -e '^--request-timeout=10s version --client$' -e 'config get-contexts' -e 'config current-context' "$T/log.ok" \
  | grep -v -- '--context=docker-desktop' || true)
if [ -z "$pinned" ]; then echo "ok    every cluster call carries --context and --request-timeout"
else echo "FAIL  unpinned calls:"; echo "$pinned" | sed 's/^/      | /'; fails=$((fails + 1)); fi
n=$((n + 1))
verbs=$(sed -E 's/--[a-z-]+=[^ ]+ //g' "$T/log.ok" | awk '{print $1}' | sort -u | tr '\n' ' ')
case " $verbs" in
  *" apply "*|*" create "*|*" delete "*|*" patch "*|*" edit "*|*" replace "*|*" scale "*|*" label "*|*" annotate "*|*" cordon "*|*" drain "*|*" exec "*|*" run "*)
    echo "FAIL  mutating verb used: $verbs"; fails=$((fails + 1)) ;;
  *) echo "ok    kubectl verbs used: $verbs" ;;
esac
n=$((n + 1))
if grep -nE 'kubectl[^|]*\b(apply|create|delete|patch|edit|replace|scale|label|annotate|cordon|drain|use-context|set-context|set-cluster|set-credentials)\b|get secrets?\b|config view' \
     "$HERE/../preflight.sh" "$HERE/../lib/metadata.sh"; then
  echo "FAIL  static: a mutating or credential-reading kubectl command appears in the script"; fails=$((fails + 1))
else echo "ok    static: no mutating or credential-reading kubectl command in the scripts"; fi

echo
if [ "$fails" -eq 0 ]; then echo "[OK] preflight: $n assertions passed"; exit 0; fi
echo "[FAIL] preflight: $fails of $n assertions failed"; exit 1
