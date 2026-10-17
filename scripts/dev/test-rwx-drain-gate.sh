#!/usr/bin/env bash
# The RWX gate of cordon_drain (apps #124): a node that still holds a Longhorn share-manager pod, or a pod
# mounting an RWX volume, must not be rebooted. Offline: the functions are extracted from roll-gates.sh and
# run against a stub kubectl that answers from JSON files. SUT overrides the file under test (mutants).
set -uo pipefail

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
  *"get pods "*) [ -f "$STUB_PODS" ] && cat "$STUB_PODS" || exit 1 ;;
  *drain*)       exit "${STUB_DRAIN_RC:-0}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" STUB_PV="$TMP/pv.json" STUB_PODS="$TMP/pods.json"

extract() { awk -v fns="$1" '
  BEGIN { n = split(fns, a, ","); for (i = 1; i <= n; i++) want[a[i]] = 1 }
  /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\).*/, "", name); inside = (name in want) }
  inside { print }
  inside && /^\}/ { inside = 0 }' "$SUT"; }
KCTL=(kubectl); ASSUME_YES=1; DRAIN_TIMEOUT=10s; RWX_CLEAR_TIMEOUT=2; RWX_POLL=1; SECONDS=0
info() { :; }; warn() { echo "warn: $*" >&2; }; die() { echo "DIE: $*" >&2; exit 97; }
# shellcheck disable=SC1090
eval "$(extract 'rwx_node_residue,wait_rwx_clear')"

PVS='{"items":[
 {"spec":{"csi":{"driver":"driver.longhorn.io"},"accessModes":["ReadWriteMany"],"claimRef":{"namespace":"app","name":"shared"}}},
 {"spec":{"csi":{"driver":"driver.longhorn.io"},"accessModes":["ReadWriteOnce"],"claimRef":{"namespace":"app","name":"solo"}}},
 {"spec":{"csi":{"driver":"other.csi"},"accessModes":["ReadWriteMany"],"claimRef":{"namespace":"app","name":"nfs-other"}}}]}'
pod() { # ns name phase [labels-json] [owner-kind] [claim]
  jq -n --arg ns "$1" --arg n "$2" --arg ph "$3" --argjson l "${4:-{\}}" --arg o "${5:-}" --arg c "${6:-}" '
   {metadata:({namespace:$ns,name:$n,labels:$l} + (if $o!="" then {ownerReferences:[{kind:$o}]} else {} end)),
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

# 7 wiring: cordon_drain calls the gate AFTER the drain, uncordons on failure, and the doc names the issue
body="$(extract cordon_drain)"
awk '/drain "\$node"/ {d=NR} /wait_rwx_clear "\$node"/ {w=NR} END {exit !(d && w && d < w)}' <<<"$body" \
  && ok "cordon_drain waits for RWX residue after the drain" || bad "cordon_drain does not call wait_rwx_clear after the drain"
awk '/wait_rwx_clear/ {f=1} f && /uncordon/ {u=1} END {exit !u}' <<<"$body" \
  && ok "a node that keeps RWX residue is uncordoned before the refusal" || bad "no uncordon on the RWX refusal"
grep -q 'apps #124' "$SUT" && ok "the gate names apps #124" || bad "no reference to apps #124"
for s in rolling-replace shrink-nodes; do
  grep -q 'cordon_drain' "$ROOT/scripts/ops/$s.sh" && ok "$s drains through cordon_drain (so through the gate)" || bad "$s does not use cordon_drain"
done

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
