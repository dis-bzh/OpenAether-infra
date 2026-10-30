#!/usr/bin/env bash
# The kube-apiserver gate between control-plane reboots of a roll (#42), against a STUB kubectl.
#
# etcd 3/3 and a Ready node did not say that the node just rebooted serves API requests, and the load balancer's TCP
# check keeps a not-ready apiserver in rotation for up to 75 s. The roll now waits for the kube-apiserver static pod
# of the control plane it just rebooted (Ready, and /readyz answering, a few polls in a row) and refuses to take the
# next one down before every apiserver serves. Offline: the stub answers from files and a counter, so a flapping
# apiserver (Ready between two restarts) is a case like any other.
#
# Usage: test-roll-apiserver-gate.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
PASS=0; FAIL=0
ok_()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# The pod's Ready answers come one per call from $STUB_DIR/pod.seq (the last line repeats); a line "ERR text" is a
# failed query. /readyz answers rc $STUB_DIR/readyz.rc. `get pods -o json` prints $STUB_DIR/pods.json.
cat >"$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
case "$*" in
  *"get pod kube-apiserver-"*)
    n="$(cat "$d/pod.n" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$d/pod.n"
    total="$(wc -l <"$d/pod.seq")"; [ "$((n + 1))" -gt "$total" ] && line="$(tail -1 "$d/pod.seq")" || line="$(sed -n "$((n + 1))p" "$d/pod.seq")"
    case "$line" in ERR*) printf '%s\n' "${line#ERR }" >&2; exit 1 ;; *) printf '%s' "$line"; exit 0 ;; esac ;;
  *"--raw=/readyz"*) exit "$(cat "$d/readyz.rc" 2>/dev/null || echo 0)" ;;
  *"get pods -o json"*) cat "$d/pods.json"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_DIR/kubectl"
export PATH="$STUB_DIR:$PATH"

extract() { # <fn name>...
  awk -v fns="$1" '
    BEGIN { n = split(fns, a, ","); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\).*/, "", name); inside = (name in want) }
    inside { print }
    inside && /^\}/ { inside = 0 }
  ' "$ROOT/scripts/lib/roll-gates.sh"
}
# shellcheck disable=SC2034  # read by the extracted functions
KCTL=(kubectl)
info() { :; }
ok() { :; }
# shellcheck disable=SC2034
POLL=0.05
eval "$(extract 'apiserver_pod_state,wait_apiserver_ready,wait_apiservers_all_ready')"

seq_() { printf '%b' "$1" >"$STUB_DIR/pod.seq"; echo 0 >"$STUB_DIR/pod.n"; }
gate() { API_TIMEOUT=2 API_STABLE_POLLS="${2:-3}" wait_apiserver_ready "$1" >/dev/null 2>&1; }

echo "=== wait_apiserver_ready: the apiserver of THIS control plane serves, polls in a row ==="
echo 0 >"$STUB_DIR/readyz.rc"
seq_ 'True\n'
gate cp1 && ok_ "a Ready apiserver that answers /readyz passes" || bad "a Ready apiserver was refused"

seq_ 'False\n'
gate cp1 && bad "an apiserver that is not Ready passed — etcd 3/3 would have let the roll go on" || ok_ "an apiserver that is not Ready is refused"

seq_ 'ERR Error from server (NotFound): pods "kube-apiserver-cp1" not found\n'
gate cp1 && bad "a missing apiserver pod passed" || ok_ "a missing apiserver pod is refused"

seq_ 'ERR The connection to the server was refused\n'
gate cp1 && bad "an API error read as a Ready apiserver" || ok_ "an API error is not a Ready apiserver"

seq_ 'True\n'; echo 1 >"$STUB_DIR/readyz.rc"
gate cp1 && bad "a Ready pod with /readyz failing passed" || ok_ "a Ready pod whose /readyz fails is refused"
echo 0 >"$STUB_DIR/readyz.rc"

# Ready between two restarts: True, False, then steady. Three in a row are needed, so the first True does not count.
seq_ 'True\nFalse\nTrue\nTrue\nTrue\n'
if API_TIMEOUT=3 API_STABLE_POLLS=3 wait_apiserver_ready cp1 >/dev/null 2>&1 && [ "$(cat "$STUB_DIR/pod.n")" -ge 5 ]; then
  ok_ "a Ready poll between two restarts does not count: it took $(cat "$STUB_DIR/pod.n") polls"
else
  bad "a flapping apiserver passed on its first Ready poll (polls: $(cat "$STUB_DIR/pod.n"))"
fi

echo
echo "=== wait_apiservers_all_ready: every control plane serves before one is taken down ==="
pods() { # <ready count of 3> [extra non-apiserver pod]
  local i items=""
  for i in 0 1 2; do
    local st=False; [ "$i" -lt "$1" ] && st=True
    items="${items}{\"metadata\":{\"name\":\"kube-apiserver-cp$i\"},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"$st\"}]}},"
  done
  items="${items}{\"metadata\":{\"name\":\"coredns-x\"},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"
  printf '{"items":[%s]}\n' "$items" >"$STUB_DIR/pods.json"
}
pods 3
API_TIMEOUT=2 wait_apiservers_all_ready 3 >/dev/null 2>&1 && ok_ "three Ready apiservers of three pass (a Ready coredns is not one)" || bad "three of three refused"
pods 2
API_TIMEOUT=2 wait_apiservers_all_ready 3 >/dev/null 2>&1 && bad "two Ready apiservers of three passed" || ok_ "two Ready apiservers of three are refused"
echo 'not json' >"$STUB_DIR/pods.json"
API_TIMEOUT=2 wait_apiservers_all_ready 3 >/dev/null 2>&1 && bad "an unreadable answer passed" || ok_ "an unreadable answer is refused"

echo
echo "=== the roll calls the gates where they matter ==="
RR="$ROOT/scripts/ops/rolling-replace.sh"
a="$(grep -n 'wait_etcd_healthy "${#CP_IPS\[@\]}" || die "etcd did not return' "$RR" | cut -d: -f1)"
b="$(grep -n 'wait_apiserver_ready "\$node_name"' "$RR" | cut -d: -f1)"
c="$(grep -n 'uncordon "\$node_name"' "$RR" | tail -1 | cut -d: -f1)"
{ [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; } \
  && ok_ "a control plane is checked for a serving apiserver after etcd is whole and before it returns to rotation" \
  || bad "wait_apiserver_ready is not between the etcd gate and the uncordon (etcd:$a api:$b uncordon:$c)"
grep -q 'wait_apiservers_all_ready "\$api_want"' "$RR" && grep -q 'api_want=\$(( \${#CP_IPS\[@\]} - DEAD ))' "$RR" \
  && ok_ "every apiserver must serve before the next control plane is taken down" \
  || bad "no all-apiservers gate before a control plane"
d="$(grep -n 'wait_apiservers_all_ready' "$RR" | head -1 | cut -d: -f1)"
e="$(grep -n 'replace_node cp "\$j"' "$RR" | cut -d: -f1)"
{ [ -n "$d" ] && [ -n "$e" ] && [ "$d" -lt "$e" ]; } && ok_ "...and before replace_node cp" || bad "the all-apiservers gate comes after replace_node cp"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
