#!/usr/bin/env bash
# ==============================================================================
# adopt-bootstrap.sh records a bootstrap the state forgot, and otherwise does
# nothing (#67).
#
# A bootstrap that succeeded on the node but was never written to state makes the
# next phase 2 re-send the RPC at a live etcd. The guard asks the control planes
# whether etcd already has members and, only on a positive answer, imports the
# resource. Every other answer must leave today's behaviour untouched, so most
# cases here assert "no import".
#
# The real script runs in a throwaway copy of the repository layout. tofu and
# talosctl are one logging stub (RFC 5737 addresses) that answers from fixture
# files; what it prints for `etcd members` is an assumption about Talos, not a
# measurement. A stdin that never reaches EOF is handed to the script, so a probe
# that forgets `</dev/null` shows (talosctl reads stdin).
#
# Offline, no credentials, no cluster.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

SCRIPT=scripts/bootstrap/adopt-bootstrap.sh
[ -f "$SCRIPT" ] || { echo "✗ $SCRIPT does not exist — nothing was checked" >&2; exit 1; }
BASH_BIN="$(command -v bash)"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"; FX="$W/fx"
mkdir -p "$C/envs" "$W/scripts"/{bootstrap,lib} "$W/bin" "$FX"
cp "$SCRIPT" "$W/scripts/bootstrap/"
cp scripts/lib/common.sh "$W/scripts/lib/"
A="$W/scripts/bootstrap/adopt-bootstrap.sh"

CP0=192.0.2.11 CP1=192.0.2.12 CP2=192.0.2.13
BOOT='module.talos.talos_machine_bootstrap.this[0]'
ROW="$CP0  4f1d2c  node-1  https://$CP0:2380  https://$CP0:2379  false"
HEADER='NODE  ID  HOSTNAME  PEER URLS  CLIENT URLS  LEARNER'

# One stub behind both binaries. It logs "<name> <args>", then answers from $FX:
# state (+ state.rc), cps.json, talosconfig, members.<ip> (+ .rc), sleep, and
# $IMPORT_RC. Anything else is logged as UNEXPECTED and fails, so a new call is seen.
cat >"$W/stub" <<EOF
#!/usr/bin/env bash
n="\$(basename "\$0")"
echo "\$n \$*" >>"$W/calls.log"
rc() { [ -f "$FX/\$1.rc" ] && cat "$FX/\$1.rc" || echo 0; }
case "\$n \$1 \$2 \$3" in
  "tofu state list "*) cat "$FX/state" 2>/dev/null; exit "\$(rc state)" ;;
  "tofu output -json control_plane_private_ips") cat "$FX/cps.json" 2>/dev/null; exit "\$(rc cps)" ;;
  "tofu output -raw talosconfig") cat "$FX/talosconfig" 2>/dev/null || exit 1 ;;
  "tofu import "*) exit "\${IMPORT_RC:-0}" ;;
  "talosctl -e "*)
    ip=""; prev=""
    for a; do [ "\$prev" = -n ] && ip="\$a"; prev="\$a"; done
    # What talosctl would have authenticated with, and what it was given as stdin.
    echo "\$TALOSCONFIG" >"$W/tc.path"; head -1 "\$TALOSCONFIG" >>"$W/tc.seen" 2>/dev/null
    [ /dev/stdin -ef /dev/null ] || echo "\$ip" >>"$W/stdin.leak"
    [ -f "$FX/sleep" ] && exec sleep "\$(cat "$FX/sleep")"
    cat "$FX/members.\$ip" 2>/dev/null; [ -f "$FX/members.\$ip.rc" ] && exit "\$(cat "$FX/members.\$ip.rc")"
    echo "rpc error: code = Unavailable desc = dial tcp $CP0:2380: connection refused" >&2; exit 1 ;;
  *) echo "UNEXPECTED \$n \$*" >>"$W/calls.log"; exit 99 ;;
esac
EOF
chmod +x "$W/stub"
ln -s "$W/stub" "$W/bin/tofu"; ln -s "$W/stub" "$W/bin/talosctl"
# `timeout` logs its arguments, then is the real one: the bound is what the script asks for.
cat >"$W/bin/timeout" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/timeout.log"
exec "$(command -v timeout)" "\$@"
EOF
chmod +x "$W/bin/timeout"

# A fresh fixture per case: the state forgot the bootstrap, three CPs, nobody answers.
reset() {
  rm -rf "$FX"; mkdir -p "$FX"; rm -f "$W"/{calls.log,tc.path,tc.seen,stdin.leak,timeout.log}; : >"$W/calls.log"
  printf '%s\n' module.talos.talos_machine_secrets.this[0] \
    'module.talos.talos_machine_configuration_apply.control_plane[0]' >"$FX/state"
  echo "[\"$CP0\",\"$CP1\",\"$CP2\"]" >"$FX/cps.json"
  printf 'context: fixture\nroles: os:admin\n' >"$FX/talosconfig"
  E=(); : >"$W/out"; : >"$W/err"
}
members() { printf '%s\n' "$2" >"$FX/members.$1"; echo "${3:-0}" >"$FX/members.$1.rc"; }
E=()
run() { # rc of the script, as ovh/workload; stdout in $W/out, stderr in $W/err
  # </dev/zero: never EOF, never blocks, and not /dev/null.
  ( cd "$C" && env -i PATH="$W/bin:$PATH" HOME="$W" "${E[@]}" "$BASH_BIN" "$A" ovh workload ) \
    </dev/zero >"$W/out" 2>"$W/err"
}
calls() { grep -c "$1" "$W/calls.log"; }
IMPORT="tofu import -input=false -var-file=envs/ovh-workload.tfvars -var talos_bootstrap=true -var skip_health_check=true $BOOT $CP0"
tail_of() { { tail -n 3 "$W/out"; tail -n 3 "$W/err"; } | tr '\n' ' '; }
untouched() { # the cases where nothing may change — no import, and no exit code
  [ "$(calls '^tofu import')" = 0 ] && ! grep -q UNEXPECTED "$W/calls.log"
}
# Both words are looked up in what the script prints, wherever it prints them.
said() { cat "$W/out" "$W/err" | grep -qi -- "$1"; }


echo "--- the bootstrap is already in state: the normal re-run is left alone ---"
reset; printf '%s\n' "$BOOT" 'module.talos.talos_machine_secrets.this[0]' >"$FX/state"
members $CP0 "$HEADER
$ROW"
run; rc=$?
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && [ ! -s "$W/err" ] \
  && ok "exit 0 and silent" || bad "rc $rc, said: $(tail_of)"
[ "$(calls '^talosctl')" = 0 ] && untouched \
  && ok "no node is asked and nothing is imported" \
  || bad "calls: $(tr '\n' '|' <"$W/calls.log")"


echo "--- not in state, and no control plane has an etcd: today's behaviour ---"
reset
run; rc=$?
[ "$rc" = 0 ] && untouched && ok "exit 0, no import" || bad "rc $rc, calls: $(tr '\n' '|' <"$W/calls.log")"
# Port and node differ per CP, and the node is the CP's own address: the tunnel
# carries the TLS to it, the node name is what apid validates.
want=$(printf '%s\n' "talosctl -e 127.0.0.1:50000 -n $CP0 etcd members" \
  "talosctl -e 127.0.0.1:50001 -n $CP1 etcd members" "talosctl -e 127.0.0.1:50002 -n $CP2 etcd members")
[ "$(grep '^talosctl' "$W/calls.log")" = "$want" ] \
  && ok "each CP is asked once through its own tunnel, in order" \
  || bad "asked: $(grep '^talosctl' "$W/calls.log" | tr '\n' '|')"
said 'bootstrapping as usual' && ok "it says it is bootstrapping as usual" || bad "no such line: $(tail_of)"
[ ! -s "$W/stdin.leak" ] && ok "talosctl never reads the caller's stdin" \
  || bad "stdin was not /dev/null for: $(tr '\n' ' ' <"$W/stdin.leak")"
[ "$(grep -cE '^-k [0-9]+ 15 talosctl ' "$W/timeout.log")" = 3 ] \
  && ok "each probe is bounded to 15s unless ADOPT_PROBE_TIMEOUT says otherwise" \
  || bad "timeout was called with: $(tr '\n' '|' <"$W/timeout.log")"


echo "--- the first control plane has etcd members: it is imported ---"
reset; members $CP0 "$HEADER
$ROW"
run; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "rc $rc: $(tail_of)"
[ "$(calls '^tofu import')" = 1 ] && [ "$(grep '^tofu import' "$W/calls.log")" = "$IMPORT" ] \
  && ok "exactly one import, of the bootstrap address, under this role's tfvars with talos_bootstrap=true, health check skipped" \
  || bad "imports: $(grep '^tofu import' "$W/calls.log" | tr '\n' '|')"
[ "$(calls '^talosctl')" = 1 ] && ok "it stops asking at the first positive" \
  || bad "talosctl was called $(calls '^talosctl') times"
said AlreadyExists && said '1 member' && ok "it names AlreadyExists and the member count" \
  || bad "output: $(tail_of)"
# The state is written before phase 2's approval prompt: the undo must be on screen.
grep -qF "tofu state rm '$BOOT'" "$W/out" && said 'before phase 2' && said 'not undo' \
  && ok "it says the state is written before the approval, that declining does not undo it, and prints the undo" \
  || bad "no undo in: $(tail_of)"
untouched_unexpected=$(grep -c UNEXPECTED "$W/calls.log"); [ "$untouched_unexpected" = 0 ] \
  && ok "no call outside the contract" || bad "unexpected calls: $(grep UNEXPECTED "$W/calls.log")"


echo "--- only the SECOND control plane answers: still imported ---"
# A fresh-disk CP-0 might accept a Bootstrap (not observed), so any CP's member counts.
reset; members $CP1 "$HEADER
$ROW"
run; rc=$?
[ "$rc" = 0 ] && [ "$(grep '^tofu import' "$W/calls.log")" = "$IMPORT" ] && [ "$(calls '^talosctl')" = 2 ] \
  && ok "CP-0 refused, CP-1 answered: one import, two nodes asked" \
  || bad "rc $rc; imports: $(grep '^tofu import' "$W/calls.log" | tr '\n' '|'); asked $(calls '^talosctl')"


echo "--- a positive answer whose import fails is an error, with the command ---"
reset; members $CP0 "$HEADER
$ROW"; E=(IMPORT_RC=1)
run; rc=$?
[ "$rc" != 0 ] && grep -qF "tofu import -input=false -var-file=envs/ovh-workload.tfvars -var talos_bootstrap=true -var skip_health_check=true '$BOOT' $CP0" "$W/err" \
  && ok "exit $rc, and stderr carries the manual command verbatim" \
  || bad "rc $rc, stderr: $(tr '\n' ' ' <"$W/err")"
said 'state rm' && bad "it prints an undo for a state it did not write" || ok "no undo is offered: the state is unchanged"


echo "--- the exit code decides, not the text ---"
reset; members $CP0 "$HEADER" 0; members $CP1 "$HEADER" 0; members $CP2 "$HEADER" 0
run; rc=$?
[ "$rc" = 0 ] && untouched && [ "$(calls '^talosctl')" = 3 ] \
  && ok "exit 0 with a header and no member row: nobody is adopted" || bad "rc $rc: $(tail_of)"
reset; members $CP0 "$ROW" 1; members $CP1 "$ROW" 1; members $CP2 "$ROW" 1
run; rc=$?
[ "$rc" = 0 ] && untouched && ok "a member row with a non-zero exit: nobody is adopted" \
  || bad "rc $rc: $(tail_of)"
# Not a list, or a list with no usable address: nothing is asked, and it says why.
for list in 'unexpected: not json' '[null,""]' '[]'; do
  reset; members $CP0 "$ROW" 0; echo "$list" >"$FX/cps.json"
  run; rc=$?
  [ "$rc" = 0 ] && untouched && [ "$(calls '^talosctl')" = 0 ] && said 'no control plane in the outputs' \
    && ok "a CP list of ${list}: exit 0, nothing asked" || bad "rc $rc for ${list}: $(tail_of)"
done


echo "--- unsure means do nothing ---"
reset; echo 1 >"$FX/state.rc"; members $CP0 "$ROW"
run; rc=$?
[ "$rc" = 0 ] && [ "$(calls '^talosctl')" = 0 ] && untouched \
  && ok "tofu state list fails: exit 0, no node is asked" || bad "rc $rc: $(tail_of)"
said 'plan' && ok "and it says the plan will explain" || bad "no pointer to the plan: $(tail_of)"
reset; rm "$FX/talosconfig"; members $CP0 "$ROW"
run; rc=$?
[ "$rc" = 0 ] && [ "$(calls '^talosctl')" = 0 ] && untouched && ok "no talosconfig in the outputs: exit 0, nothing asked" \
  || bad "rc $rc: $(tail_of)"
# A PATH holding only what the script needs, minus one of the three it checks for.
# Each is named: without the check the others' symptoms differ, and so does the message.
for gone in talosctl jq timeout; do
  rm -rf "$W/min"; mkdir -p "$W/min"; ln -s "$W/stub" "$W/min/tofu"; ln -s "$W/stub" "$W/min/talosctl"
  for t in bash basename jq mktemp timeout grep rm cat dirname; do ln -sf "$(command -v "$t")" "$W/min/$t"; done
  rm "$W/min/$gone"
  reset; members $CP0 "$ROW"
  ( cd "$C" && env -i PATH="$W/min" HOME="$W" "$BASH_BIN" "$A" ovh workload ) </dev/zero >"$W/out" 2>"$W/err"; rc=$?
  [ "$rc" = 0 ] && untouched && [ "$(calls '^talosctl')" = 0 ] && said "$gone is not installed" \
    && ok "$gone is not installed: exit 0, no import, and it says so" || bad "rc $rc without $gone: $(tail_of)"
done


echo "--- a node that hangs costs at most the probe timeout ---"
reset; echo 5 >"$FX/sleep"; members $CP0 "$ROW"; E=(ADOPT_PROBE_TIMEOUT=1)
start=$SECONDS; run; rc=$?; took=$((SECONDS - start))
# Three hung probes at 1s each; unbounded they would take 15s.
[ "$rc" = 0 ] && untouched && [ "$took" -lt 8 ] \
  && ok "three probes that never answer: exit 0 after ${took}s, no import" \
  || bad "rc $rc after ${took}s: $(tail_of)"
[ "$(grep -cE '^-k [0-9]+ 1 talosctl ' "$W/timeout.log")" = 3 ] \
  && ok "ADOPT_PROBE_TIMEOUT is what bounds each probe" || bad "timeout was called with: $(tr '\n' '|' <"$W/timeout.log")"


echo "--- the tunnel block follows TALOS_TUNNEL_OFFSET ---"
reset; E=(TALOS_TUNNEL_OFFSET=200)
run; rc=$?
[ "$rc" = 0 ] && grep -qx "talosctl -e 127.0.0.1:50200 -n $CP0 etcd members" "$W/calls.log" \
  && grep -qx "talosctl -e 127.0.0.1:50202 -n $CP2 etcd members" "$W/calls.log" \
  && ok "an offset of 200 probes ports 50200 to 50202" || bad "rc $rc: $(grep '^talosctl' "$W/calls.log" | tr '\n' '|')"
reset; E=(TALOS_TUNNEL_OFFSET=7)
run; rc=$?
[ "$rc" != 0 ] && [ "$(calls '^talosctl')" = 0 ] && ok "an offset that is not a multiple of 200 is refused" \
  || bad "rc $rc, asked $(calls '^talosctl')"


echo "--- the talosconfig is this cluster's, not the checkout's ---"
reset; members $CP0 "$ROW"; printf 'context: another-cluster\n' >"$C/talosconfig"
run; rc=$?
[ "$(head -1 "$W/tc.seen" 2>/dev/null)" = "context: fixture" ] \
  && ok "talosctl authenticated with the output of tofu, not with ./talosconfig" \
  || bad "talosctl saw: $(cat "$W/tc.seen" 2>/dev/null)"
[ -n "$(cat "$W/tc.path" 2>/dev/null)" ] && [ ! -e "$(cat "$W/tc.path")" ] \
  && ok "the file holding it is gone afterwards" || bad "left behind: $(cat "$W/tc.path" 2>/dev/null)"
rm -f "$C/talosconfig"


echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
