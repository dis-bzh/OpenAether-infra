#!/usr/bin/env bash
# scripts/bootstrap/talos-tunnels.sh, run for real in a fake repository with a stub ssh and tofu (#65): what each
# tunnel's ssh says is kept per port and appended, `ensure` and a short `open` quote it. The stub ssh is one process
# that listens like the real one. SUT overrides the script, which is how mutants run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/bootstrap/talos-tunnels.sh}"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
for t in nc jq python3; do command -v "$t" >/dev/null || { echo "✗ $t is required"; exit 1; }; done

W="$(mktemp -d)"
TUN="$W/scripts/bootstrap/talos-tunnels.sh"
# Does not trust the pidfile or `close`: a regression in what they can find is what this must survive. The stub
# also ends itself after 3 minutes, for a harness that was killed before it got here.
cleanup() {
  (cd "$W/cluster" && "$TUN" close . >/dev/null 2>&1)
  local p; for p in $(awk '{ print $1 }' "$W/ident" 2>/dev/null); do
    [[ "$(ps -o args= -p "$p" 2>/dev/null)" == *"$W/bin/ssh-stub.py"* ]] && kill "$p" 2>/dev/null
  done
  rm -rf "$W"
}
trap cleanup EXIT
mkdir -p "$W/scripts/bootstrap" "$W/scripts/lib" "$W/bin" "$W/cluster" "$W/blind"
cp "$SUT" "$TUN"
# Only what the script sources. A port named in $BLIND is refused once: a listener nothing answers behind.
cat >"$W/scripts/lib/common.sh" <<'STUB'
oa_tunnel_offset() { printf '%s' "${TALOS_TUNNEL_OFFSET:-0}"; }
oa_talos_endpoint_ok() { [ -e "$BLIND/$2" ] && { rm -f "$BLIND/$2"; return 1; }; nc -z "$1" "$2" 2>/dev/null; }
STUB
cat >"$W/bin/tofu" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "output -json" ] || exit 1
echo '{"bastion_ip":{"value":"203.0.113.10"},"bastion_user":{"value":"ops"},"k8s_lb_ip":{"value":"10.0.0.50"},
 "control_plane_private_ips":{"value":["10.0.0.11","10.0.0.12"]},"worker_private_ips":{"value":["10.0.0.21"]}}'
STUB
# argv[0] is "ssh", as the real one's: close's sweep finds a tunnel by its command line.
printf '#!/usr/bin/env bash\nexec -a ssh python3 "$(dirname "$0")/ssh-stub.py" "$@"\n' >"$W/bin/ssh"
cat >"$W/bin/ssh-stub.py" <<'STUB'
# The readiness probe (`… true`) succeeds. A tunnel (-N -L port:host:50000) prints what ssh prints (the "Authenticated"
# line only at LogLevel=VERBOSE, as ssh does), listens, and on TERM prints its closing lines and exits. A port that
# is taken fails like ExitOnForwardFailure; STUB_FAIL_PORT is refused like a rejected key.
import os, signal, socket, sys
a = sys.argv[1:]
if "true" in a:
    sys.exit(0)
port = int(a[a.index("-L") + 1].split(":")[0])
signal.alarm(180)
def say(s):
    sys.stderr.write(s + "\n"); sys.stderr.flush()
if str(port) == os.environ.get("STUB_FAIL_PORT"):
    say("ops@203.0.113.10: Permission denied (publickey)."); sys.exit(255)
if "LogLevel=VERBOSE" in a:
    say(f"Authenticated to stub (pid {os.getpid()})")
open(os.environ["IDENT"], "a").write(f"{os.getpid()} {port}\n")
def stop(*_):
    say("Transferred: sent 0, received 0 bytes, in 1.0 seconds"); say("Bytes per second: sent 0.0, received 0.0"); os._exit(0)
signal.signal(signal.SIGTERM, stop)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", port))
except OSError:
    say(f"bind [127.0.0.1]:{port}: Address already in use"); say("Could not request local forwarding."); sys.exit(255)
s.listen(8)
while True:
    s.accept()[0].close()
STUB
chmod +x "$W"/bin/ssh "$W"/bin/tofu; : >"$W/key"
export PATH="$W/bin:$PATH" SSH_KEY="$W/key" IDENT="$W/ident" BLIND="$W/blind" BASTION_WAIT=5
# Clear of the 50000-50199 default block, per-process (a second run cannot collide with this one), and moved on past
# any port something else holds.
busy() { nc -z 127.0.0.1 "$1" 2>/dev/null; }
OFF=$(( 1000 + ($$ % 40) * 200 ))
while busy $((50000 + OFF)) || busy $((50001 + OFF)) || busy $((50100 + OFF)) || busy $((6443 + OFF)); do OFF=$((OFF + 200)); done
export TALOS_TUNNEL_OFFSET=$OFF
P0=$((50000 + TALOS_TUNNEL_OFFSET)); P1=$((P0 + 1)); PW=$((50100 + TALOS_TUNNEL_OFFSET)); PA=$((6443 + TALOS_TUNNEL_OFFSET))
LOGS=("$P0" "$P1" "$PW" "$PA")
up() { local n=0 p; for p in "${LOGS[@]}"; do nc -z 127.0.0.1 "$p" 2>/dev/null && n=$((n + 1)); done; echo "$n"; }
log() { echo "$W/cluster/.talos-tunnel-$1.log"; }
pid_of() { awk -v p="$1" '$2 == p { x = $1 } END { print x }' "$W/ident"; }
# <pattern> in every control plane, worker and API log?
in_all_logs() { local p; for p in "${LOGS[@]}"; do grep -q -- "$1" "$(log "$p")" 2>/dev/null || return 1; done; }

(cd "$W/cluster" && "$TUN" open . >"$W/open.out" 2>&1)
{ [ "$(up)" = 4 ] && grep -q '4/4 tunnels up' "$W/open.out" && in_all_logs 'Authenticated to stub' \
  && [ "$(sort "$W/cluster/.talos-tunnels.pids")" = "$(awk '{ print $1 }' "$W/ident" | sort)" ]; } \
  && ok "open: 4/4 up; each port keeps its ssh's VERBOSE transcript, and every pid is in the pidfile" \
  || bad "open (up=$(up)): $(tail -3 "$W/open.out"); logs: $(ls -a "$W/cluster")"

# P0 gets TERM, P1 dies without a word (KILL), PW stays up but nothing answers behind it.
kill -TERM "$(pid_of "$P0")"; kill -KILL "$(pid_of "$P1")"; touch "$W/blind/$PW"; sleep 1
ENS="$(cd "$W/cluster" && "$TUN" ensure . 2>&1)"; RC=$?
{ [ "$RC" = 0 ] && grep -qE ":${P0}  ssh EXITED; .*ends: .*Transferred: sent 0" <<<"$ENS" \
  && grep -qE ":${P1}  ssh EXITED; " <<<"$ENS" && ! grep -qE ":${P1} .*Transferred" <<<"$ENS" \
  && grep -qE ":${PW}  ssh running, the node behind it is not answering; " <<<"$ENS"; } \
  && ok "ensure quotes how each dead tunnel's log ends (a TERM's closing lines, a KILL's none) and tells a live ssh from a dead one" \
  || bad "ensure (rc ${RC}): ${ENS}"

# ensure rebuilt through `open`: a new generation, appended after the old one's last lines.
GEN=1; for p in "${LOGS[@]}"; do
  [ "$(grep -c ' spawn :' "$(log "$p")" 2>/dev/null)" = 2 ] && [ "$(grep -c 'Authenticated' "$(log "$p")" 2>/dev/null)" = 2 ] || GEN=0
done
{ [ "$GEN" = 1 ] && [ "$(up)" = 4 ] \
  && awk '/Transferred:/ { t = NR } / spawn :/ { s = NR } END { exit !(t && s > t) }' "$(log "$P0")"; } \
  && ok "…then rebuilds: the log is appended to, so the dead tunnel's lines are still there, before the new generation's" \
  || bad "after ensure: up=$(up) generations ok=${GEN}; $(cat "$(log "$P0")" 2>/dev/null)"

# Two opens at once on the same block: whichever ssh wins a port, nobody's transcript may be cut or overwritten.
N0=$(wc -l <"$W/ident")
(cd "$W/cluster" && { "$TUN" open . >"$W/c1.out" 2>&1 & "$TUN" open . >"$W/c2.out" 2>&1 & wait; })
TORN=0; for p in "${LOGS[@]}"; do
  [ "$(tr -cd '\000' <"$(log "$p")" 2>/dev/null | wc -c)" = 0 ] || TORN=1
  for pid in $(tail -n +$((N0 + 1)) "$W/ident" | awk -v p="$p" '$2 == p { print $1 }'); do
    grep -q "(pid $pid)" "$(log "$p")" 2>/dev/null || TORN=1
  done
done
{ [ "$(up)" = 4 ] && [ "$TORN" = 0 ]; } \
  && ok "two simultaneous opens: all 4 listening, every ssh's transcript is in its log, none torn" \
  || bad "concurrent opens: up=$(up) torn=${TORN}; $(cat "$(log "$P0")" 2>/dev/null)"

OUT="$(cd "$W/cluster" && STUB_FAIL_PORT="$P1" "$TUN" open . 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && grep -q '3/4 tunnels up' <<<"$OUT" && grep -qE ":${P1}  .*Permission denied" <<<"$OUT" \
  && ! grep -qE ":(${P0}|${PW}|${PA})  " <<<"$OUT"; } \
  && ok "open that finds 3/4: exits 1 and quotes the failed port's log, only that one's" \
  || bad "short open (rc ${RC}): ${OUT}"

(cd "$W/cluster" && "$TUN" close . >/dev/null 2>&1); sleep 1
{ [ "$(up)" = 0 ] && in_all_logs 'Authenticated to stub'; } \
  && ok "close stops the tunnels and leaves their transcripts" || bad "close left $(up) listener(s); logs: $(ls -a "$W/cluster")"

(cd "$W/cluster" && "$TUN" open-direct --bastion 203.0.113.10 --user ops --cps 10.0.0.11,10.0.0.12 --workers 10.0.0.21 \
  --key "$W/key" >"$W/direct.out" 2>&1)
{ [ "$(up)" = 3 ] && [ "$(wc -l <"$W/cluster/.talos-tunnels-direct.pids")" = 3 ] \
  && grep -q 'Authenticated to stub' "$W/cluster/.talos-tunnel-direct-$P0.log" \
  && grep -q 'Authenticated to stub' "$W/cluster/.talos-tunnel-direct-$PW.log"; } \
  && ok "open-direct goes through the same spawn: 3 up, its own pidfile and transcripts" \
  || bad "open-direct (up=$(up)): $(tail -3 "$W/direct.out"); $(ls -a "$W/cluster")"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
