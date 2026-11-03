#!/usr/bin/env bash
# The RWX gate of cordon_drain (apps #124): a node that still holds a Longhorn share-manager pod, or a pod
# mounting an RWX volume, must not be rebooted. Also the two ways the drain used to wait its whole timeout for
# nothing: a bare pod (infra #402) and a stall against a budget that allows nothing (infra #417). Offline: the
# functions are extracted from roll-gates.sh and run against a stub kubectl that answers from JSON files.
# SUT overrides the file under test (mutants).
set -uo pipefail

# A parent that ignores a signal hands the ignore down (nohup ignores HUP; a command started in the background by a non-interactive
# shell ignores INT), and bash can neither trap nor reset a signal that was ignored when it started: the trap checks and the real-signal
# tests below would go red for a reason that is not the product's. So this file runs again with INT, TERM and HUP at their default, as
# test-talos-tunnels.sh does for HUP. The ignored-signal behaviour is tested on purpose below, by a runner that ignores HUP itself.
if [ -z "${RWX_TEST_SIGDFL:-}" ]; then
  if env --default-signal=INT,TERM,HUP true 2>/dev/null; then RWX_TEST_SIGDFL=1 exec env --default-signal=INT,TERM,HUP bash "$0" ${@+"$@"}; fi
  case "$(trap -p INT TERM HUP)" in *"''"*) echo "note: INT, TERM or HUP is ignored by the parent and 'env --default-signal' is missing: the signal checks below may go red for that reason" >&2 ;; esac
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/lib/roll-gates.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$*" in
  *"get persistentvolumes "*)   [ -f "$STUB_PV" ] && cat "$STUB_PV" || exit 1 ;;
  *"get pods -l "*)
    # the pods of the node that carry the first label of the selector, as the apiserver answers a label selector
    argv="$*"; sel="${argv#*-l }"; sel="${sel%% *}"; k="${sel%%=*}"; v="${sel#*=}"; v="${v%%,*}"
    f="${STUB_SEQ:+$STUB_SEQ/last.json}"; f="${f:-$STUB_PODS}"
    jq -r --arg k "$k" --arg v "$v" '[.items[] | select(.metadata.labels[$k] == $v) | .metadata.name] | join(" ")' "$f" ;;
  *"get pods -A --field-selector"*"-o json"*)
    # STUB_SEQ (a directory) answers the n-th read with n.json, else last.json: the pods of a drain as it goes.
    if [ -n "${STUB_SEQ:-}" ]; then
      n=$(($(cat "$STUB_SEQ/n" 2>/dev/null || echo 0) + 1)); echo "$n" >"$STUB_SEQ/n"
      [ "$n" -ge "${STUB_DONE_AT:-99999}" ] && : >"$STUB_SEQ/done"
      # once the drain has ended, the node answers with after.json (empty): what a node that drained cleanly looks like
      f="$STUB_SEQ/$n.json"; [ -f "$f" ] || f="$STUB_SEQ/last.json"
      [ "$n" -gt "${STUB_DONE_AT:-99999}" ] && f="$STUB_SEQ/after.json"; cat "$f"
    else [ -f "$STUB_PODS" ] && cat "$STUB_PODS" || exit 1; fi ;;
  *"get pods "*) [ -f "$STUB_PODS" ] && cat "$STUB_PODS" || exit 1 ;;
  *"get pdb "*)  [ -f "$STUB_PDB" ] && cat "$STUB_PDB" || exit 1 ;;
  *drain*)
    # A drain that hangs 30 s as ONE process (exec) and says its pid: what a kubectl drain does under a budget that allows nothing.
    if [ -n "${STUB_DRAIN_PIDFILE:-}" ]; then echo $$ >"$STUB_DRAIN_PIDFILE"; exec /bin/sleep 30; fi
    # A drain that goes on until STUB_SEQ/done exists (or 5 s), and says when it ended by itself.
    if [ -n "${STUB_SEQ:-}" ]; then
      for _ in $(seq 100); do [ -f "$STUB_SEQ/done" ] && break; /bin/sleep 0.05; done
      : >"$STUB_SEQ/drain-ended"
    fi
    [ -n "${STUB_DRAIN_SLEEP:-}" ] && /bin/sleep "$STUB_DRAIN_SLEEP"
    exit "${STUB_DRAIN_RC:-0}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" STUB_PV="$TMP/pv.json" STUB_PODS="$TMP/pods.json" STUB_PDB="$TMP/pdb.json"

extract() { awk -v fns="$1" '
  BEGIN { n = split(fns, a, ","); for (i = 1; i <= n; i++) want[a[i]] = 1 }
  /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\).*/, "", name); inside = (name in want) }
  inside { print }
  inside && /^\}/ { inside = 0 }' "$SUT"; }
KCTL=(kubectl); ASSUME_YES=1; DRAIN_TIMEOUT=10s; RWX_CLEAR_TIMEOUT=2; RWX_POLL=1; SECONDS=0
info() { :; }; warn() { echo "warn: $*" >&2; }; die() { echo "DIE: $*" >&2; exit 97; }
# shellcheck disable=SC1090
eval "$(extract 'rwx_node_residue,wait_rwx_clear,pdb_hard,cordon_drain,drainable_pods,refuse_bare_pods,drain_watched,drain_interrupted,drain_untrap,drain_stall_blockers')"
# What cordon_drain does before and around the drain is other tests' business (test-rolling-replace.sh); they only leave a line
# in the log here, so that "before anything else" can be asserted.
cnpg_maintenance() { echo "STUB cnpg_maintenance" >>"$STUB_LOG"; }; wait_cnpg_whole() { :; }; wait_pdb_headroom() { :; }; worker_cpu_requests() { :; }
STOP_REQUESTED=0

PVS='{"items":[
 {"spec":{"csi":{"driver":"driver.longhorn.io"},"accessModes":["ReadWriteMany"],"claimRef":{"namespace":"app","name":"shared"}}},
 {"spec":{"csi":{"driver":"driver.longhorn.io"},"accessModes":["ReadWriteOnce"],"claimRef":{"namespace":"app","name":"solo"}}},
 {"spec":{"csi":{"driver":"other.csi"},"accessModes":["ReadWriteMany"],"claimRef":{"namespace":"app","name":"nfs-other"}}}]}'
pod() { # ns name phase [labels-json] [owner-kind] [claim] [extra-metadata-json] [controller: true|false]
  jq -n --arg ns "$1" --arg n "$2" --arg ph "$3" --argjson l "${4:-{\}}" --arg o "${5:-}" --arg c "${6:-}" --argjson x "${7:-{\}}" --argjson ctl "${8:-true}" '
   {metadata:({namespace:$ns,name:$n,labels:$l} + (if $o!="" then {ownerReferences:[({kind:$o} + (if $ctl then {controller:true} else {} end))]} else {} end) + $x),
    status:{phase:$ph}, spec:{volumes:(if $c!="" then [{persistentVolumeClaim:{claimName:$c}}] else [] end)}}'; }
mkpods() { jq -s '{items:.}'; }
run() { RC=0; OUT="$(rwx_node_residue n1 2>&1)" || RC=$?; }

printf '%s' "$PVS" >"$TMP/pv.json"

# 1 clean node
{ pod app web Running '{}' ReplicaSet solo; pod kube-system cilium Running '{}' DaemonSet; } | mkpods >"$TMP/pods.json"
run; [ $RC -eq 0 ] && [ -z "$OUT" ] && ok "RWO claim, DaemonSet and plain pods are not residue" || bad "clean node reported: $OUT"

# 2 share-manager
pod longhorn-system share-manager-pvc-1 Running '{"longhorn.io/component":"share-manager"}' | mkpods >"$TMP/pods.json"
run; grep -q 'longhorn-system/share-manager-pvc-1.*share-manager' <<<"$OUT" && ok "a share-manager pod is residue" || bad "share-manager missed: $OUT"

# 3 RWX client
pod app writer Running '{}' ReplicaSet shared | mkpods >"$TMP/pods.json"
run; grep -q 'app/writer.*RWX claim shared' <<<"$OUT" && ok "a pod mounting a Longhorn RWX claim is residue" || bad "RWX client missed: $OUT"

# 4 non-Longhorn RWX and finished pods
{ pod app nfsuser Running '{}' ReplicaSet nfs-other; pod app done Succeeded '{}' Job shared; } | mkpods >"$TMP/pods.json"
run; [ -z "$OUT" ] && ok "a non-Longhorn RWX claim and a Succeeded pod are not residue" || bad "false positive: $OUT"

# 4b a real node's pod list is far over the 128 KB limit of one argv entry (lab 13: jq "Argument list too long")
{ jq -n '{items:[range(900)|{metadata:{namespace:"app",name:"filler-\(.)",labels:{pad:("x"*300)}},status:{phase:"Running"},spec:{volumes:[]}}]}'; pod app writer Running '{}' ReplicaSet shared; } | jq -s '{items:(.[0].items + .[1:])}' >"$TMP/pods.json"
[ "$(wc -c <"$TMP/pods.json")" -gt 200000 ] || bad "test payload too small"
run; grep -q 'app/writer.*RWX claim shared' <<<"$OUT" && ok "a pod list over 200 KB is read (not an argv entry)" || bad "big pod list: rc=$RC $OUT"

# 5 an unanswered query dies, never reads as empty
rm -f "$TMP/pods.json"; run
[ $RC -eq 97 ] && grep -q 'refusing to reboot blind' <<<"$OUT" && ok "an unanswered pod query is fatal, not an empty list" || bad "rc=$RC out=$OUT"
printf '%s' "$PVS" >"$TMP/pv.json"; rm -f "$TMP/pv.json"; pod app a Running | mkpods >"$TMP/pods.json"; run
[ $RC -eq 97 ] && ok "an unanswered PV query is fatal" || bad "pv query: rc=$RC"
printf '%s' "$PVS" >"$TMP/pv.json"

# 6 wait: times out and lists, then clears
pod app writer Running '{}' ReplicaSet shared | mkpods >"$TMP/pods.json"
RC=0; OUT="$(wait_rwx_clear n1 2>&1)" || RC=$?
[ $RC -eq 1 ] && grep -q 'app/writer' <<<"$OUT" && ok "wait_rwx_clear times out and names the residue" || bad "wait: rc=$RC $OUT"
echo '{"items":[]}' >"$TMP/pods.json"
RC=0; wait_rwx_clear n1 >/dev/null 2>&1 || RC=$?
[ $RC -eq 0 ] && ok "wait_rwx_clear returns 0 on an empty node" || bad "empty wait rc=$RC"

# The drain's watch asks every DRAIN_TICK seconds whether kubectl ended; here the clock is a fake one, moved by `sleep` itself, so
# a stall of 120 s is judged in a few hundred milliseconds. (The watch of a real drain sleeps a fifth of a second per tick.)
DRAIN_TICK=1
sleep() { SECONDS=$((SECONDS + ${1%%.*})); command sleep 0.03; }
# 8 a bare pod (infra #402): kubectl drain refuses it at once ("cannot delete Pods that declare no controller"), yet the roll
# waited 900 s (lab 25). The pods of the node are read BEFORE the CNPG waits, the cordon and the drain, and the refusal names them.
drain_run() { : >"$TMP/log"; RC=0; OUT="$( ( set -euo pipefail; ok() { :; }; cordon_drain n1 ) 2>&1 )" || RC=$?; }
mirror='{"annotations":{"kubernetes.io/config.mirror":"abc"}}'
{ pod app web Running '{}' ReplicaSet; pod kube-system cilium Running '{}' DaemonSet; pod kube-system etcd-n1 Running '{}' "" "" "$mirror"
  pod app done Succeeded; pod app zlw-1 Running; pod app zlw-2 Pending; pod app owned Running '{}' Foo "" '{}' false; } | mkpods >"$TMP/pods.json"
ASSUME_YES=1; drain_run
{ [ $RC -eq 97 ] && grep -q 'app/zlw-1' <<<"$OUT" && grep -q 'app/zlw-2' <<<"$OUT" && grep -q 'app/owned' <<<"$OUT" \
  && ! grep -qE 'app/(web|done)|cilium|etcd-n1' <<<"$OUT"; } \
  && ok "unattended, bare pods (no controller) are refused and named; controlled, DaemonSet, mirror and finished pods are not" || bad "bare pods: rc=$RC $OUT"
{ ! grep -qE 'STUB cnpg_maintenance|cordon|drain n1' "$TMP/log"; } \
  && ok "…before the CNPG waits, the cordon and the drain: nothing was touched" || bad "the refusal came late: $(cat "$TMP/log")"
{ pod app web Running '{}' ReplicaSet; pod kube-system cilium Running '{}' DaemonSet; pod app done Succeeded; } | mkpods >"$TMP/pods.json"
drain_run
{ [ $RC -eq 0 ] && grep -q 'drain n1' "$TMP/log"; } && ok "no bare pod: the drain goes ahead as before" || bad "refused without a bare pod: rc=$RC $OUT"
{ pod app zlw-1 Running; } | mkpods >"$TMP/pods.json"; ASSUME_YES=0
RC=0; : >"$TMP/log"; OUT="$( ( set -euo pipefail; ok() { :; }; cordon_drain n1 ) 2>&1 <<<n )" || RC=$?
{ [ $RC -eq 97 ] && grep -q 'app/zlw-1' <<<"$OUT" && grep -q 'aborted by operator' <<<"$OUT" && ! grep -q 'cordon' "$TMP/log"; } \
  && ok "attended, the operator is asked first and \"n\" stops before the cordon" || bad "attended, n: rc=$RC $OUT"
RC=0; : >"$TMP/log"; OUT="$( ( set -euo pipefail; ok() { :; }; cordon_drain n1 ) 2>&1 <<<y )" || RC=$?
{ [ $RC -eq 97 ] || [ $RC -eq 0 ]; } && grep -q 'drain n1' "$TMP/log" \
  && ok "attended, \"y\" goes on to the drain, whose own answer decides (the old behaviour is kept)" || bad "attended, y: rc=$RC $OUT"
ASSUME_YES=1
rm -f "$TMP/pods.json"; drain_run
{ grep -q 'could not list the pods of n1' <<<"$OUT" && grep -q 'drain n1' "$TMP/log"; } \
  && ok "an unanswered pod list does not stop a drain kubectl can judge itself (it only warns); the drain still runs" || bad "unanswered list: rc=$RC $OUT"

# 9 a stall (infra #417): a worker with an attached RWX share-manager waited its whole 900 s and was then refused (lab 28, I3).
# The drain runs in the background and the pods of the node are watched: the drain is stopped when the same pods stay, none is
# terminating and a budget that allows 0 covers one of them. A clock that moves 1 s per tick, so the test does not wait.
DRAIN_STALL_AFTER=6; DRAIN_STALL_POLL=2; DRAIN_TIMEOUT=900s
im_l='{"longhorn.io/component":"instance-manager"}'; sm_l='{"longhorn.io/component":"share-manager"}'
pdb() { jq -n --arg ns "$1" --arg n "$2" --argjson l "$3" '{metadata:{namespace:$ns,name:$n},spec:{selector:{matchLabels:$l}},status:{disruptionsAllowed:0,expectedPods:1,currentHealthy:1}}'; }
seq_reset() { rm -rf "$TMP/seq"; mkdir -p "$TMP/seq"; export STUB_SEQ="$TMP/seq"; STUB_DONE_AT=99999; export STUB_DONE_AT; echo '{"items":[]}' >"$TMP/seq/after.json"; }
seq_off() { unset STUB_SEQ STUB_DONE_AT; }
{ pod longhorn-system instance-manager-n1 Running "$im_l" ReplicaSet; pod longhorn-system share-manager-pvc-1 Running "$sm_l" ReplicaSet; } | mkpods >"$TMP/seq_last.json"
pdb longhorn-system instance-manager-n1 "$im_l" | jq -s '{items:.}' >"$TMP/pdb.json"

seq_reset; cp "$TMP/seq_last.json" "$TMP/seq/last.json"; drain_run
{ [ $RC -eq 97 ] && grep -q 'makes no progress' <<<"$OUT" && grep -q 'longhorn-system/instance-manager-n1' <<<"$OUT" \
  && grep -q 'share-manager-pvc-1' <<<"$OUT" && grep -q 'uncordon n1' "$TMP/log" && [ ! -f "$TMP/seq/drain-ended" ]; } \
  && ok "the same pods, none terminating, a budget allowing 0 on one: stopped after 6 s, the budget and the share-manager named, node uncordoned, drain killed" \
  || bad "stall not detected: rc=$RC $OUT"
[ "$(cat "$TMP/seq/n" 2>/dev/null || echo 99)" -lt 15 ] && ok "…and it took a handful of reads (not a drain of 900 s)" || bad "reads: $(cat "$TMP/seq/n")"
# kubectl was killed, so it printed no reason, and a bare pod was refused before the drain: neither sentence may be said of a stall.
{ ! grep -q 'printed just above' <<<"$OUT" && ! grep -q 'A pod without a controller' <<<"$OUT" && grep -q 'stalled: no progress' <<<"$OUT"; } \
  && ok "…and the refusal says what was seen, without 'kubectl's reason is printed above' or the bare-pod cause (kubectl was killed, the bare pods were refused earlier)" || bad "stale words after a stall: $OUT"

# the same pods, but the budget covers none of them: a slow drain, not a refused one. Left to kubectl and its own timeout.
pdb longhorn-system other "{\"app\":\"other\"}" | jq -s '{items:.}' >"$TMP/pdb.json"
seq_reset; cp "$TMP/seq_last.json" "$TMP/seq/last.json"; STUB_DONE_AT=7; drain_run
{ [ $RC -eq 0 ] && [ -f "$TMP/seq/drain-ended" ]; } && ok "no budget covers a remaining pod: not a stall, the drain is left to finish" || bad "false stall without a covering budget: rc=$RC $OUT"

# a DaemonSet pod stays on every node for ever, and a budget may cover it: the drain does not wait on it.
{ pod longhorn-system instance-manager-n1 Running "$im_l" DaemonSet; pod app web Running '{}' ReplicaSet; } | mkpods >"$TMP/seq_ds.json"
pdb longhorn-system instance-manager-n1 "$im_l" | jq -s '{items:.}' >"$TMP/pdb.json"
seq_reset; cp "$TMP/seq_ds.json" "$TMP/seq/last.json"; STUB_DONE_AT=7; drain_run
{ [ $RC -eq 0 ] && [ -f "$TMP/seq/drain-ended" ]; } && ok "a DaemonSet pod behind a budget is not something the drain waits on: no stall" || bad "stalled on a DaemonSet pod: rc=$RC $OUT"

# a pod of the node is terminating (a long grace period): the drain is working, even with another pod behind a budget.
pdb longhorn-system instance-manager-n1 "$im_l" | jq -s '{items:.}' >"$TMP/pdb.json"
seq_reset; { pod longhorn-system instance-manager-n1 Running "$im_l" ReplicaSet; pod longhorn-system share-manager-pvc-1 Running "$sm_l" ReplicaSet "" '{"deletionTimestamp":"2026-11-02T10:00:00Z"}'; } | mkpods >"$TMP/seq/last.json"
STUB_DONE_AT=7; drain_run
{ [ $RC -eq 0 ] && [ -f "$TMP/seq/drain-ended" ]; } && ok "a pod that is terminating means the drain is working: no stall, even with another pod behind a budget" || bad "stopped a drain that was terminating a pod: rc=$RC $OUT"

# progress resets the clock: a pod leaves at the 4th read, so the 6 s of silence would only complete after the drain ended.
seq_reset; cp "$TMP/seq_last.json" "$TMP/seq/last.json"
for i in 1 2 3; do { pod longhorn-system instance-manager-n1 Running "$im_l" ReplicaSet; pod longhorn-system share-manager-pvc-1 Running "$sm_l" ReplicaSet; pod app web Running '{}' ReplicaSet; } | mkpods >"$TMP/seq/$i.json"; done
STUB_DONE_AT=5; drain_run
{ [ $RC -eq 0 ] && [ -f "$TMP/seq/drain-ended" ]; } && ok "a pod leaving the node restarts the 6 s: a drain that progresses is never stopped" || bad "stopped a drain that was progressing: rc=$RC $OUT"

# a stop asked BEFORE the drain started (a Ctrl+C during the CNPG or budget waits of the same node) is read between nodes, not by
# the drain: "the node in flight finishes". Only a signal that arrives while the drain runs ends it (below, with real signals).
seq_reset; cp "$TMP/seq_last.json" "$TMP/seq/last.json"; pdb longhorn-system other '{"app":"other"}' | jq -s '{items:.}' >"$TMP/pdb.json"
STOP_REQUESTED=1; STUB_DONE_AT=7; drain_run; STOP_REQUESTED=0
{ [ $RC -eq 0 ] && [ -f "$TMP/seq/drain-ended" ]; } && ok "a stop asked before the drain started does not end it: the node in flight finishes" || bad "stop flag ended a drain: rc=$RC $OUT"

# The caller's traps are put back whatever ended the drain: a trap left behind would answer the next Ctrl+C with a dead pid.
trap_after() { trap 'echo mine' INT; drain_watched n1 >/dev/null 2>&1; RC=$?; T="$(trap -p INT TERM HUP)"; trap - INT; }
seq_reset; cp "$TMP/seq_last.json" "$TMP/seq/last.json"; STUB_DONE_AT=7; trap_after
{ [ $RC -eq 0 ] && [ "$(grep -c . <<<"$T")" = 1 ] && grep -q 'echo mine' <<<"$T"; } \
  && ok "after a drain that ended by itself the caller's INT trap is back, and no TERM or HUP trap is left" || bad "traps after a clean drain: rc=$RC [$T]"
pdb longhorn-system instance-manager-n1 "$im_l" | jq -s '{items:.}' >"$TMP/pdb.json"
seq_reset; cp "$TMP/seq_last.json" "$TMP/seq/last.json"; trap_after
{ [ $RC -eq 1 ] && [ "$(grep -c . <<<"$T")" = 1 ] && grep -q 'echo mine' <<<"$T"; } \
  && ok "…and after a drain stopped for a stall" || bad "traps after a stalled drain: rc=$RC [$T]"

# A signal while the drain runs (review of 0.4.1 WP1, MAJOR). kubectl runs in the background, where a script's async commands ignore
# Ctrl+C, so it would outlive a script that dies of the interrupt (shrink-nodes.sh has no INT trap), evicting pods from a node the
# EXIT trap has already uncordoned. Real signals, real clock, a stub drain that hangs 30 s; the runner is a script of its own.
alive() { local s; s="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"; [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
sig_run() { # <signal> <group|pid> [caller trap]; SIG_PRELUDE: a line the runner runs first; SIG_FIRST: a signal sent before <signal>
  local sig="$1" target="$2" ct="${3:-}" pid i
  rm -f "$TMP/drain.pid" "$TMP/runner.out"; FIRST_ALIVE=""
  { echo 'set -uo pipefail'; extract 'drain_watched,drain_interrupted,drain_untrap'
    echo 'KCTL=(kubectl); DRAIN_TIMEOUT=30s; DRAIN_STALL_AFTER=120; DRAIN_TICK=0.1; warn() { :; }; STOP_REQUESTED=0'
    echo "trap 'echo EXIT-TRAP' EXIT"
    [ -z "${SIG_PRELUDE:-}" ] || echo "$SIG_PRELUDE"
    [ -z "$ct" ] || echo "trap '$ct' INT TERM"
    echo 'drain_watched n1; echo "returned $? why=$DRAIN_WHY stop=$STOP_REQUESTED"; trap -p INT TERM'
  } >"$TMP/runner.sh"
  set -m; STUB_DRAIN_PIDFILE="$TMP/drain.pid" bash "$TMP/runner.sh" >"$TMP/runner.out" 2>&1 & pid=$!; set +m
  for i in $(seq 100); do [ -s "$TMP/drain.pid" ] && break; command sleep 0.05; done
  if [ -n "${SIG_FIRST:-}" ]; then   # a signal the runner ignores: it and its drain must both still be there a moment later
    kill -"$SIG_FIRST" "$pid" 2>/dev/null; command sleep 0.4
    ! alive "$pid" || ! alive "$(cat "$TMP/drain.pid" 2>/dev/null || echo 0)" || FIRST_ALIVE=yes
  fi
  if [ "$target" = group ]; then kill -"$sig" -- "-$pid" 2>/dev/null; else kill -"$sig" "$pid" 2>/dev/null; fi
  RC=0; wait "$pid" 2>/dev/null || RC=$?
  OUT="$(cat "$TMP/runner.out")"; DPID="$(cat "$TMP/drain.pid" 2>/dev/null || echo 0)"
}
sig_run INT group
{ [ "$DPID" != 0 ] && [ $RC -eq 130 ] && grep -q '^EXIT-TRAP$' <<<"$OUT" && ! alive "$DPID"; } \
  && ok "Ctrl+C on a script with no INT trap (cluster-shrink): the script dies, its EXIT trap runs, and the drain is dead with it" \
  || bad "Ctrl+C: rc=$RC drain pid $DPID alive=$(alive "$DPID" && echo yes || echo no) $OUT"
alive "$DPID" && kill -9 "$DPID" 2>/dev/null
sig_run TERM pid 'STOP_REQUESTED=1; echo CALLER-RAN'
{ [ "$DPID" != 0 ] && [ $RC -eq 0 ] && ! alive "$DPID" && [ "$(grep -c '^CALLER-RAN$' <<<"$OUT")" = 1 ] && grep -q 'returned [1-9][0-9]* why=interrupted by SIGTERM stop=1' <<<"$OUT" \
  && grep -q "^trap -- .*CALLER-RAN.* SIGTERM" <<<"$OUT" && grep -q '^EXIT-TRAP$' <<<"$OUT"; } \
  && ok "SIGTERM on a script with its own trap (cluster-roll): the drain is killed, the caller's trap runs once (stop requested), the drain reports failure and the traps are back" \
  || bad "SIGTERM: rc=$RC drain pid $DPID alive=$(alive "$DPID" && echo yes || echo no) $OUT"
alive "$DPID" && kill -9 "$DPID" 2>/dev/null
sig_run HUP pid
{ [ "$DPID" != 0 ] && [ $RC -eq 129 ] && grep -q '^EXIT-TRAP$' <<<"$OUT" && ! alive "$DPID"; } \
  && ok "SIGHUP (the terminal closed) on a script with no trap: the drain is killed, the script dies of HUP, its EXIT trap runs" \
  || bad "SIGHUP: rc=$RC drain pid $DPID alive=$(alive "$DPID" && echo yes || echo no) $OUT"
alive "$DPID" && kill -9 "$DPID" 2>/dev/null
# A signal the caller ignores stays ignored, as for a foreground drain (nohup: HUP). The drain does not take it over, and the others
# are still watched: TERM sent after it kills the drain and the script all the same.
SIG_PRELUDE="trap '' HUP" SIG_FIRST=HUP sig_run TERM pid
{ [ -n "$FIRST_ALIVE" ] && [ "$DPID" != 0 ] && [ $RC -eq 143 ] && ! alive "$DPID" && grep -q '^EXIT-TRAP$' <<<"$OUT"; } \
  && ok "a signal the caller ignores (HUP, as under nohup) stays ignored: script and drain live on; TERM, not ignored, still kills the drain" \
  || bad "ignored HUP: first-signal survivors=${FIRST_ALIVE:-none} rc=$RC drain pid $DPID alive=$(alive "$DPID" && echo yes || echo no) $OUT"
alive "$DPID" && kill -9 "$DPID" 2>/dev/null

# kubectl's own answer is unchanged: a refusal at once is a refusal, with the timeout named, and DRAIN_STALL_AFTER=0 is the old foreground drain.
seq_off; { pod app web Running '{}' ReplicaSet; } | mkpods >"$TMP/pods.json"; export STUB_DRAIN_RC=1; drain_run
{ [ $RC -eq 97 ] && grep -q 'could not be drained (timeout 900s)' <<<"$OUT" && grep -q 'uncordon n1' "$TMP/log"; } \
  && ok "a drain that fails by itself still ends in the old refusal, with the node uncordoned" || bad "plain failure: rc=$RC $OUT"
{ grep -q "kubectl's own reason is printed just above" <<<"$OUT" && grep -q 'A pod without a controller' <<<"$OUT"; } \
  && ok "…with the old words (kubectl printed its reason; the bare-pod cause is still listed)" || bad "plain failure lost its words: $OUT"
export STUB_DRAIN_RC=0 STUB_DRAIN_SLEEP=0.4; DRAIN_STALL_AFTER=0; { pod app web Running '{}' ReplicaSet; } | mkpods >"$TMP/pods.json"; drain_run
{ [ $RC -eq 0 ] && grep -q 'drain n1' "$TMP/log" && ! grep -q 'get pdb' "$TMP/log" && [ "$(grep -c 'get pods -A' "$TMP/log")" = 2 ]; } \
  && ok "DRAIN_STALL_AFTER=0 switches the watch off: the plain drain, no reading of the pods or the budgets while it runs" || bad "watch not off: rc=$RC reads=$(grep -c 'get pods -A' "$TMP/log") $OUT"
DRAIN_STALL_AFTER=6; drain_run
[ "$(grep -c 'get pods -A' "$TMP/log")" -gt 2 ] && ok "…while the watch on does read them (the check above can tell the two apart)" || bad "the watch did not read: $(grep -c 'get pods -A' "$TMP/log")"
unset STUB_DRAIN_SLEEP
DRAIN_STALL_AFTER=120; unset -f sleep; unset STUB_DRAIN_RC

# 7 wiring: cordon_drain calls the gate AFTER the drain, uncordons on failure, and the doc names the issue
body="$(extract cordon_drain)"
awk '/drain_watched "\$node"/ {d=NR} /wait_rwx_clear "\$node"/ {w=NR} END {exit !(d && w && d < w)}' <<<"$body" \
  && ok "cordon_drain waits for RWX residue after the drain" || bad "cordon_drain does not call wait_rwx_clear after the drain"
awk '/wait_rwx_clear/ {f=1} f && /uncordon/ {u=1} END {exit !u}' <<<"$body" \
  && ok "a node that keeps RWX residue is uncordoned before the refusal" || bad "no uncordon on the RWX refusal"
grep -q 'apps #124' "$SUT" && ok "the gate names apps #124" || bad "no reference to apps #124"
for s in rolling-replace shrink-nodes; do
  grep -q 'cordon_drain' "$ROOT/scripts/ops/$s.sh" && ok "$s drains through cordon_drain (so through the gate)" || bad "$s does not use cordon_drain"
done

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
