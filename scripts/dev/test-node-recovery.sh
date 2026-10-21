#!/usr/bin/env bash
# scripts/ops/node-recovery.sh (state | recover | replace) in a fake repository: tofu, kubectl, openssl, the provider helper
# and rolling-replace.sh are stubs that log their argv, and real TCP listeners stand in for the Talos tunnels.
#
# What it pins: `state` separates "the machine runs but the node is silent" (recover) from "the machine is stopped, in error
# or gone" (replace) and from "the provider did not answer" (nothing decided); `recover` never reboots a machine that is not
# running, and never reboots anything when the tunnels, not the node, are down; `replace` refuses a Ready node and a machine
# the provider calls running unless told, passes --dead for ONE node to the roll (control plane: --cp-only), and never touches
# anything on --dry-run. No cloud, no cluster.
# Usage: test-node-recovery.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

W="$(mktemp -d)"
trap 'kill "${LISTEN_PID:-0}" 2>/dev/null; rm -rf "${W:?}"' EXIT
C="$W/infrastructure/opentofu/cluster"; ST="$W/st"
mkdir -p "$C/envs" "$W/scripts/lib" "$W/scripts/ops" "$W/bin" "$ST"
cp "$ROOT/scripts/lib/common.sh" "$W/scripts/lib/"
cp "${SUT:-$ROOT/scripts/ops/node-recovery.sh}" "$W/scripts/ops/node-recovery.sh"
printf 'cluster_name = "oa"\nenvironment = "lab"\n' >"$C/envs/management-ovh.tfvars"
: >"$C/talosconfig"; : >"$C/kubeconfig"
export CALLS="$W/calls.log" ST

cat >"$W/bin/tofu" <<'STUB'
#!/usr/bin/env bash
[ "$1" = output ] && echo '{"control_plane_private_ips":{"value":["10.0.0.10","10.0.0.11","10.0.0.12"]},"worker_private_ips":{"value":["10.0.0.20","10.0.0.21","10.0.0.22"]}}'
exit 0
STUB
cat >"$W/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
argv=" $* "
node="$(awk '{for(i=1;i<=NF;i++) if($i=="node") print $(i+1)}' <<<"$*" | head -1)"
case "$argv" in
  *" get node "*"InternalIP"*) case "$node" in
      oa-lab-worker-0) echo 10.0.0.20 ;; oa-lab-worker-1) echo 10.0.0.21 ;; oa-lab-cp-0) echo 10.0.0.10 ;; oa-lab-cp-1) echo 10.0.0.11 ;; *) exit 1 ;; esac ;;
  *" get node "*"Ready"*) cat "$ST/ready.$node" 2>/dev/null || echo True ;;
  *" get node "*) [ "$(cat "$ST/ready.$node" 2>/dev/null || echo True)" != absent ] ;;
  *" get pods -A "*) cat "$ST/pods.txt" 2>/dev/null ;;
esac
exit 0
STUB
cat >"$W/bin/openssl" <<'STUB'
#!/usr/bin/env bash
port="$(sed -E 's/.*-connect [^:]*:([0-9]+).*/\1/' <<<"$*")"
if grep -qx "$port" "$ST/silent" 2>/dev/null; then echo "connection reset by peer"; else echo "CONNECTION ESTABLISHED"; fi
STUB
cat >"$W/bin/node-provider" <<'STUB'
#!/usr/bin/env bash
echo "provider $*" >>"$CALLS"
case "$1" in
  state) s="$(cat "$ST/pstate")"; [ "$s" = noanswer ] && exit 2; printf '{"provider":"ovh","state":"%s"}\n' "$s" ;;
  hard-reboot) [ -f "$ST/reboot.fails" ] && exit 3
               [ -f "$ST/reboot.heals" ] && { : >"$ST/silent"; echo True >"$ST/ready.$(cat "$ST/target")"; }
               printf '{"state":"running","accepted":true}\n' ;;
esac
STUB
cat >"$W/scripts/ops/rolling-replace.sh" <<'STUB'
#!/usr/bin/env bash
echo "roll $*" >>"$CALLS"; [ -f "$ST/roll.fails" ] && exit 1
[ -f "$ST/roll.heals" ] && echo True >"$ST/ready.$(cat "$ST/target")"
exit 0
STUB
chmod +x "$W"/bin/* "$W/scripts/ops/rolling-replace.sh"

export TALOS_TUNNEL_OFFSET=10200
python3 -I - "$((50000 + TALOS_TUNNEL_OFFSET))" "$((50100 + TALOS_TUNNEL_OFFSET))" <<'PY' &
import select, socket, sys, time
socks = []
for base in map(int, sys.argv[1:]):
    for p in range(base, base + 3):
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", p)); s.listen(8); socks.append(s)
end = time.time() + 600
while time.time() < end:  # accept and drop, or the backlog fills and the next probe hangs
    for s in select.select(socks, [], [], 1)[0]:
        c, _ = s.accept(); c.close()
PY
LISTEN_PID=$!
sleep 0.5

export NODE_PROVIDER_CMD="$W/bin/node-provider"
export PATH="$W/bin:$PATH" RECOVER_TIMEOUT=3 POLL=1
reset() {
  : >"$CALLS"
  rm -f "${ST:?}"/ready.* "${ST:?}"/silent "${ST:?}"/pstate "${ST:?}"/reboot.* "${ST:?}"/roll.* "${ST:?}"/pods.txt "${ST:?}"/target
  echo running >"$ST/pstate"
}
nr() { (cd "$C" && bash ${NRX:-} "$W/scripts/ops/node-recovery.sh" "$@" 2>&1); }
W0=$((50100 + TALOS_TUNNEL_OFFSET))

echo "=== state: which command, if any ==="
reset; echo oa-lab-worker-0 >"$ST/target"
OUT="$(nr state ovh --node=oa-lab-worker-0)"
grep -q 'VERDICT=healthy' <<<"$OUT" && ok_ "a Ready node is healthy: nothing to do" || bad "a Ready node was not healthy: $OUT"

reset; echo False >"$ST/ready.oa-lab-worker-0"; echo "$W0" >"$ST/silent"
OUT="$(nr state ovh --node=oa-lab-worker-0)"
{ grep -q 'VERDICT=recover' <<<"$OUT" && grep -q 'task cluster-node-recover PROVIDER=ovh NODE=oa-lab-worker-0' <<<"$OUT" && grep -q 'infra #371' <<<"$OUT"; } \
  && ok_ "ACTIVE (running) but not Ready is the recover shape, and the command is named" || bad "running+NotReady: $OUT"
grep -q 'provider state ovh --name oa-lab-worker-0 --ip 10.0.0.20' "$CALLS" && ok_ "the provider is asked by instance name and private address" || bad "provider call: $(cat "$CALLS")"

for s in stopped error absent; do
  reset; echo False >"$ST/ready.oa-lab-worker-0"; echo "$s" >"$ST/pstate"
  OUT="$(nr state ovh --node=oa-lab-worker-0)"
  { grep -q 'VERDICT=replace' <<<"$OUT" && grep -q 'task cluster-replace-node PROVIDER=ovh NODE=oa-lab-worker-0' <<<"$OUT"; } \
    && ok_ "a machine that is ${s} is the replace shape" || bad "${s}: $OUT"
done
reset; echo Unknown >"$ST/ready.oa-lab-worker-0"; echo noanswer >"$ST/pstate"
OUT="$(nr state ovh --node=oa-lab-worker-0)"
grep -q 'VERDICT=unknown' <<<"$OUT" && ok_ "a provider that does not answer decides nothing" || bad "unknown: $OUT"
reset; echo False >"$ST/ready.oa-lab-cp-1"; echo stopped >"$ST/pstate"
OUT="$(nr state ovh --node=oa-lab-cp-1)"
grep -q 'dr-restore-plan' <<<"$OUT" && ok_ "a control plane's replace names the last resort (dr-restore-plan) when the quorum is gone" || bad "no dr-restore-plan hint for a control plane"
reset
OUT="$(nr state ovh --node=oa-lab-nope)"; rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'cannot tell the address' <<<"$OUT"; } && ok_ "a node that is nowhere is named, not guessed (use --ip)" || bad "unknown node: rc=$rc $OUT"

echo
echo "=== recover ==="
reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo "$W0" >"$ST/silent"; echo stopped >"$ST/pstate"
nr recover ovh --node=oa-lab-worker-0 --yes >/dev/null; rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q 'hard-reboot' "$CALLS"; } && ok_ "a machine the provider calls stopped is never hard-rebooted: replace it" || bad "rebooted a stopped machine (rc=$rc)"

reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"
for p in $((W0)) $((W0 + 1)) $((W0 + 2)) $((50000 + TALOS_TUNNEL_OFFSET)) $((50001 + TALOS_TUNNEL_OFFSET)) $((50002 + TALOS_TUNNEL_OFFSET)); do echo "$p" >>"$ST/silent"; done
OUT="$(nr recover ovh --node=oa-lab-worker-0 --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q 'hard-reboot' "$CALLS" && grep -qi 'tunnels' <<<"$OUT"; } \
  && ok_ "when no other node answers either, the tunnels are blamed and NOTHING is rebooted" || bad "rebooted with the tunnels down (rc=$rc): $OUT"

reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo "$W0" >"$ST/silent"; : >"$ST/reboot.heals"
OUT="$(nr recover ovh --node=oa-lab-worker-0 --yes)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(grep -c 'provider hard-reboot' "$CALLS")" = 1 ] && grep -q 'provider hard-reboot ovh --name oa-lab-worker-0 --ip 10.0.0.20' "$CALLS" && grep -q 'Ready again' <<<"$OUT"; } \
  && ok_ "a silent node whose machine runs gets ONE hard reboot, and the wait ends when it answers and is Ready" || bad "recover (rc=$rc): $OUT"

reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo "$W0" >"$ST/silent"
OUT="$(nr recover ovh --node=oa-lab-worker-0 --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'task cluster-replace-node' <<<"$OUT"; } \
  && ok_ "a hard reboot that does not bring the node back ends bounded, naming the replacement" || bad "recover that fails (rc=$rc): $OUT"

reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo "$W0" >"$ST/silent"; : >"$ST/reboot.fails"
nr recover ovh --node=oa-lab-worker-0 --yes >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok_ "a provider that refuses the hard reboot is an error, not a wait" || bad "a refused hard reboot passed"

reset; echo oa-lab-worker-0 >"$ST/target"
nr recover ovh --node=oa-lab-worker-0 --yes >/dev/null; rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q hard-reboot "$CALLS"; } && ok_ "a Ready node is not recovered" || bad "recovered a Ready node"

echo
echo "=== replace ==="
reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo "$W0" >"$ST/silent"
nr replace ovh --node=oa-lab-worker-0 --yes >/dev/null; rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q '^roll' "$CALLS"; } && ok_ "a machine the provider calls running is not replaced: recover comes first" || bad "replaced a running machine (rc=$rc)"

reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo stopped >"$ST/pstate"; : >"$ST/roll.heals"
OUT="$(nr replace ovh --node=oa-lab-worker-0 --yes)"; rc=$?
grep -q '^roll ovh --workers-only --role=management --dead --node=oa-lab-worker-0 --ip=10.0.0.20 --yes' "$CALLS" \
  && ok_ "a stopped worker: the roll gets --dead for ONE node (--workers-only, --node, --ip, --yes)" || bad "roll args: $(grep '^roll' "$CALLS")"
{ [ "$rc" -eq 0 ] && grep -q 'Replacement of oa-lab-worker-0 done' <<<"$OUT"; } && ok_ "...and the checks after it end the run" || bad "replace did not finish (rc=$rc): $OUT"

reset; echo oa-lab-cp-1 >"$ST/target"; echo False >"$ST/ready.oa-lab-cp-1"; echo absent >"$ST/pstate"; : >"$ST/roll.heals"
nr replace ovh --node=oa-lab-cp-1 --yes >/dev/null
grep -q '^roll ovh --cp-only .*--dead --node=oa-lab-cp-1 --ip=10.0.0.11' "$CALLS" && ok_ "a control plane gets --cp-only" || bad "cp roll args: $(grep '^roll' "$CALLS")"

reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo "$W0" >"$ST/silent"; : >"$ST/roll.heals"
nr replace ovh --node=oa-lab-worker-0 --yes --even-if-running >/dev/null
grep -q '^roll' "$CALLS" && ok_ "--even-if-running replaces a machine the provider still calls running (after recover failed)" || bad "--even-if-running did not reach the roll"

reset; echo oa-lab-worker-0 >"$ST/target"
nr replace ovh --node=oa-lab-worker-0 --yes >/dev/null; rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q '^roll' "$CALLS"; } && ok_ "a Ready node is never replaced by this command (task cluster-roll is the path)" || bad "replaced a Ready node"

reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo noanswer >"$ST/pstate"
nr replace ovh --node=oa-lab-worker-0 --yes >/dev/null; rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q '^roll' "$CALLS"; } && ok_ "a provider that does not answer does not establish a dead machine" || bad "replaced on an unanswered provider"

reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo stopped >"$ST/pstate"
nr replace ovh --node=oa-lab-worker-0 --dry-run >/dev/null; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^roll .*--dry-run' "$CALLS" && ! grep -q 'kubectl.*get pods' "$CALLS"; } && ok_ "--dry-run is passed to the roll, and no post-check pretends something happened" || bad "dry-run (rc=$rc): $(cat "$CALLS")"

reset; echo oa-lab-worker-0 >"$ST/target"; echo False >"$ST/ready.oa-lab-worker-0"; echo stopped >"$ST/pstate"; : >"$ST/roll.fails"
nr replace ovh --node=oa-lab-worker-0 --yes >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok_ "a roll that fails fails the command" || bad "a failed roll passed"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
