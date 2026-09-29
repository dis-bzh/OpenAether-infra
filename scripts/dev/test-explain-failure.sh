#!/usr/bin/env bash
# ==============================================================================
# explain-failure.sh exists because nothing told the operator a resource was
# TAINTED, and re-running destroyed a load balancer the provider was still
# building; then a plan died on "404 not Found" for an object the provider had
# deleted behind OpenTofu's back, naming neither the ghost nor `tofu state rm`.
# These assertions keep both messages alive — and, as much, keep them QUIET on
# every failure that is neither.
#
# Offline: a stub `tofu` on PATH serves a crafted state, and the transcript is
# written by hand in the shape OpenTofu really produces. No cloud, no backend.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
stub() { printf '#!/usr/bin/env bash\n[ "$1" = state ] && cat %q\nexit 0\n' "$SB/state.json" >"$SB/tofu"; chmod +x "$SB/tofu"; }
run()  { PATH="$SB:$PATH" ./scripts/internal/explain-failure.sh "$SB" 2>&1; }
# A diagnostic in the shape OpenTofu writes into a FILE: boxed, and still
# ANSI-coloured even when redirected — measured on OpenTofu 1.12.5, and the
# reason the explainer strips escapes instead of anchoring on column 1.
box() { # <error summary> [address...]
  local a; printf '\033[31m╷\033[0m\n\033[31m│\033[0m \033[1m\033[31mError: \033[0m\033[1m%s\033[0m\n\033[31m│\033[0m \n' "$1"
  shift; for a in "$@"; do printf '\033[31m│\033[0m   with %s,\n' "$a"; done
  printf '\033[31m╵\033[0m\n'
}
LOG="$SB/.tofu-run.log"
GHOST='module.scw[0].scaleway_lb_ip.k8s[0]'
NF='scaleway-sdk-go: waiting for lb failed: scaleway-sdk-go: http error 404 Not Found: lbs not Found'

echo "--- a tainted resource must be named, with its untaint command ---"
cat >"$SB/state.json" <<'JSON'
{"resources":[
 {"module":"module.ovh[0]","type":"openstack_lb_loadbalancer_v2","name":"k8s",
  "instances":[{"index_key":0,"status":"tainted","attributes":{}}]},
 {"module":"module.ovh[0]","type":"openstack_compute_instance_v2","name":"worker",
  "instances":[{"index_key":1,"attributes":{}}]}
]}
JSON
stub; OUT="$(run)"
grep -q 'module.ovh\[0\].openstack_lb_loadbalancer_v2.k8s\[0\]' <<<"$OUT" \
  && ok "the tainted address is printed in full" || bad "the tainted address is missing from the output"
grep -q "tofu untaint 'module.ovh\[0\].openstack_lb_loadbalancer_v2.k8s\[0\]'" <<<"$OUT" \
  && ok "and the exact untaint command with it" || bad "no untaint command was offered"
grep -qi 'DESTROYED AND REBUILT' <<<"$OUT" \
  && ok "it says what re-running would actually do" || bad "it does not explain the cost of re-running"
grep -q 'openstack_compute_instance_v2' <<<"$OUT" \
  && bad "it named a healthy resource — the signal is diluted" \
  || ok "healthy resources are not mentioned"

echo "--- silent when nothing is tainted (it runs on every failed apply) ---"
cat >"$SB/state.json" <<'JSON'
{"resources":[{"module":"module.ovh[0]","type":"openstack_compute_instance_v2","name":"worker",
 "instances":[{"index_key":0,"attributes":{}}]}]}
JSON
stub; OUT="$(run)"
[ -z "$OUT" ] && ok "prints nothing at all" || bad "printed on a clean state: '${OUT:0:60}'"

echo "--- never breaks the caller, whatever it meets ---"
printf '#!/usr/bin/env bash\nexit 1\n' >"$SB/tofu"; chmod +x "$SB/tofu"
run >/dev/null 2>&1; [ $? -eq 0 ] && ok "a tofu that fails still exits 0" || bad "it propagated a failure"
printf '#!/usr/bin/env bash\necho "not json"\n' >"$SB/tofu"; chmod +x "$SB/tofu"
run >/dev/null 2>&1; [ $? -eq 0 ] && ok "unparseable state still exits 0" || bad "it propagated a failure"
PATH="$SB:$PATH" ./scripts/internal/explain-failure.sh /nonexistent-dir >/dev/null 2>&1
[ $? -eq 0 ] && ok "a missing directory still exits 0" || bad "it propagated a failure"

echo "--- an object the provider says is gone must be named, with its state rm ---"
cat >"$SB/state.json" <<'JSON'
{"resources":[
 {"module":"module.scw[0]","mode":"managed","type":"scaleway_lb_ip","name":"k8s",
  "instances":[{"index_key":0,"attributes":{}}]},
 {"module":"module.scw[0]","mode":"managed","type":"scaleway_instance_server","name":"worker",
  "instances":[{"index_key":0,"attributes":{}}]},
 {"module":"module.scw[0]","mode":"data","type":"scaleway_lb_ips","name":"existing",
  "instances":[{"index_key":0,"attributes":{}}]}
]}
JSON
stub; box "$NF" "$GHOST" >"$LOG"; OUT="$(run)"
grep -qF "$GHOST" <<<"$OUT" \
  && ok "the address the provider 404'd on is printed" || bad "the ghost address is missing from the output"
grep -qF "tofu state rm '$GHOST'" <<<"$OUT" \
  && ok "and the exact state rm command with it" || bad "no state rm command was offered"
grep -q 'scaleway_instance_server' <<<"$OUT" \
  && bad "it named a healthy resource — that state rm would strand a live server" \
  || ok "resources the provider said nothing about are left alone"
grep -qi 'orphan' <<<"$OUT" \
  && ok "it says what state rm costs if the object is in fact alive" \
  || bad "it hands out state rm with no warning about forgetting a live object"

# OpenTofu colours WITHIN a diagnostic line — measured: it underlines the failing
# expression mid-line — so an escape can land inside the address itself.
box "$NF" "$(printf '\033[1mmodule.scw[0]\033[0m.scaleway_lb_ip.k8s[0]')" >"$LOG"
OUT="$(run)"
grep -qF "tofu state rm '$GHOST'" <<<"$OUT" \
  && ok "an escape sequence inside the address does not hide it" \
  || bad "a coloured address went unrecognised — the transcript is coloured on disk"

echo "--- the diagnosis is scoped to ONE diagnostic, not to the whole transcript ---"
{ box "$NF" "$GHOST"
  box 'Quota exceeded: too many instances' 'module.scw[0].scaleway_instance_server.worker[0]'; } >"$LOG"
OUT="$(run)"
grep -qF "tofu state rm '$GHOST'" <<<"$OUT" \
  && ok "the 404'd address is still offered when another error follows it" \
  || bad "a second diagnostic hid the first"
grep -q 'scaleway_instance_server' <<<"$OUT" \
  && bad "an address quoted by the QUOTA error was reported as gone" \
  || ok "an address quoted by an unrelated error is not called a ghost"

echo "--- an address is named only when state and provider agree on it ---"
box "$NF" 'module.scw[0].scaleway_lb.k8s[0]' >"$LOG"; OUT="$(run)"
[ -z "$OUT" ] && ok "a 404 on something the state does not hold says nothing" \
  || bad "it advised state rm for an address absent from the state: '${OUT:0:60}'"
box "$NF" 'data.scaleway_lb_ips.existing[0]' 'module.scw[0].data.scaleway_lb_ips.existing[0]' >"$LOG"
OUT="$(run)"
[ -z "$OUT" ] && ok "a 404 on a DATA source says nothing — it is re-read, not stored" \
  || bad "it offered state rm for a data source: '${OUT:0:60}'"

echo "--- silent on every failure that is neither shape, and on success ---"
box 'Quota exceeded: too many instances' "$GHOST" >"$LOG"; OUT="$(run)"
[ -z "$OUT" ] && ok "a quota failure naming a live resource prints nothing" \
  || bad "false alarm on an ordinary failure: '${OUT:0:60}'"
printf 'Apply complete! Resources: 2 added, 0 changed, 0 destroyed.\n' >"$LOG"; OUT="$(run)"
[ -z "$OUT" ] && ok "a transcript of a run that WORKED prints nothing" \
  || bad "the healthy path raised a diagnosis: '${OUT:0:60}'"
rm -f "$LOG"; OUT="$(run)"
[ -z "$OUT" ] && ok "with no transcript at all it guesses nothing" \
  || bad "it diagnosed a ghost with no evidence: '${OUT:0:60}'"

echo "--- both shapes at once, and neither breaks the caller ---"
cat >"$SB/state.json" <<'JSON'
{"resources":[
 {"module":"module.scw[0]","mode":"managed","type":"scaleway_lb_ip","name":"k8s",
  "instances":[{"index_key":0,"attributes":{}}]},
 {"module":"module.scw[0]","mode":"managed","type":"scaleway_instance_server","name":"cp",
  "instances":[{"index_key":0,"status":"tainted","attributes":{}}]}
]}
JSON
stub; box "$NF" "$GHOST" >"$LOG"; OUT="$(run)"
grep -qF "tofu state rm '$GHOST'" <<<"$OUT" \
  && grep -qF "tofu untaint 'module.scw[0].scaleway_instance_server.cp[0]'" <<<"$OUT" \
  && ok "a run that is both tainted AND ghosted gets both diagnoses" \
  || bad "one of the two diagnoses was lost when both applied"
run >/dev/null 2>&1; [ $? -eq 0 ] && ok "a transcript on disk still exits 0" || bad "it propagated a failure"
head -c 4096 /dev/urandom >"$LOG"; run >/dev/null 2>&1
[ $? -eq 0 ] && ok "an unreadable transcript still exits 0" || bad "it propagated a failure"
rm -f "$LOG"

echo "--- the transcript is wired, and cannot be committed ---"
# The explainer is blind without the tee, and the tee is worthless if pipefail
# does not keep the failure — so a task that defers to it must have all three.
# Every provider-touching command in such a task must be teed — not just one of
# them: the diagnosis is only ever as good as the command that was recorded.
UNWIRED="$(awk '
  function check() { if (t != "" && x && !(pf && rmv && untee == 0)) print t }
  /^  [a-zA-Z0-9_-]+:$/ { check(); t=$1; sub(/:$/,"",t); x=pf=rmv=untee=0; next }
  /\\$/ { hold = hold $0; next }          # a command continued on the next line
  # A command inside a quoted string is prose, not a command. Without this the
  # guard reddened the moment a task echoed `tofu apply <file>` as advice.
  { l = hold $0; hold = ""; c = l; gsub(/"[^"]*"/, "", c) }
  l ~ /^[[:space:]]*#/          { next }
  l ~ /defer:.*explain-failure\.sh/ { x=1 }   # only a task that DEFERS needs one
  c ~ /tofu[[:space:]]+(plan|apply)/ { if (l !~ /tee -a \.tofu-run\.log/) untee++ }
  l ~ /set -o pipefail/         { pf=1 }
  l ~ /rm -f \.tofu-run\.log/   { rmv=1 }
  END { check() }
' Taskfile.yml)"
[ -z "$UNWIRED" ] && ok "every task that explains a failure also tees, drops and pipefails its transcript" \
  || bad "these tasks call the explainer with no usable transcript: $(tr '\n' ' ' <<<"$UNWIRED")"
git check-ignore -q infrastructure/opentofu/cluster/.tofu-run.log \
  && ok "the transcript is gitignored — it quotes real addresses" \
  || bad "the transcript is COMMITTABLE, and it holds real addresses and ids"


echo "--- a for_each key is a STRING, and tofu refuses it unquoted ---"
# Not one of the fixtures above used a string key, and the address the explainer
# built for one — worker_data[w0-d0] — is a command `tofu untaint` rejects with
# "Index value required". Five instances in this project's own state are keyed
# that way. VERIFIED on OpenTofu 1.12.5.
cat >"$SB/state.json" <<'JSON'
{"resources":[
 {"module":"module.scw[0]","type":"scaleway_block_volume","name":"worker_data",
  "instances":[{"index_key":"w0-d0","status":"tainted","attributes":{}}]}
]}
JSON
stub; OUT="$(run)"
grep -q 'worker_data\["w0-d0"\]' <<<"$OUT" \
  && ok "a string for_each key is quoted, the way OpenTofu prints it" \
  || bad "the string key is unquoted — the untaint command it prints is refused by tofu"
grep -q 'worker_data\[w0-d0\]' <<<"$OUT" \
  && bad "the unquoted form is still emitted" \
  || ok "the unquoted form is gone"


# --- the wiring itself -------------------------------------------------------
# Everything above only inspects tasks that ALREADY defer to the explainer, so
# deleting the wiring made the script invisible and left this suite green: 107
# lines could be fully orphaned without one assertion moving. Named tasks are
# asserted positively.
WIRED="$(awk '
  /^  [a-zA-Z0-9_-]+:$/          { t=$1; sub(/:$/,"",t) }
  t != "" && /defer:.*explain-failure\.sh/ { print t }
' Taskfile.yml | sort -u)"
for T in infra-apply infra-plan; do
  grep -qx "$T" <<<"$WIRED" \
    && ok "$T defers to the explainer" \
    || bad "$T no longer defers to the explainer — a failure there explains nothing"
done


echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
