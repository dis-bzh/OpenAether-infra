#!/usr/bin/env bash
# scripts/bootstrap/talos-tunnels.sh, run for real in a fake repository with a stub ssh and tofu (#65): what each
# tunnel's ssh is asked to do (target, user, key, keepalive, nohup), what it says is kept per port and appended, and
# `ensure`, `open` and `open-direct` quote it. The stub ssh is one process that listens like the real one and records its
# argv. SUT overrides the script, which is how mutants run.
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
# is taken fails like ExitOnForwardFailure; the ports in STUB_FAIL_PORT (space-separated) are refused like a rejected
# key. Its whole argv goes to $IDENT after its pid and port: what it was asked to do is what the tests read.
import os, signal, socket, sys
a = sys.argv[1:]
if "true" in a:
    sys.exit(0)
port = int(a[a.index("-L") + 1].split(":")[0])
signal.alarm(180)
def say(s):
    sys.stderr.write(s + "\n"); sys.stderr.flush()
if str(port) in os.environ.get("STUB_FAIL_PORT", "").split():
    say("ops@203.0.113.10: Permission denied (publickey)."); sys.exit(255)
if "LogLevel=VERBOSE" in a:
    say(f"Authenticated to stub (pid {os.getpid()})")
open(os.environ["IDENT"], "a").write(f"{os.getpid()} {port} {' '.join(a)}\n")
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
chmod +x "$W"/bin/ssh "$W"/bin/tofu; : >"$W/key"; : >"$W/key2"
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
# The script under `env --default-signal=HUP`: a caller's own nohup (this harness run from one) must not hide a missing one.
tun() { env --default-signal=HUP "$TUN" "$@"; }
# Every ssh recorded after ident line $1 for port $2 has each remaining fragment among its argv words; says what is missing.
asked() {
  local from=$1 p=$2 f line n=0; shift 2
  while read -r line; do
    n=$((n + 1))
    for f in "$@"; do [[ " $line " == *" $f "* ]] || { echo "    :$p lacks '$f' in: ${line#* }"; return 1; }; done
  done < <(awk -v p="$p" -v from="$from" 'NR > from && $2 == p' "$W/ident")
  [ "$n" -gt 0 ] || { echo "    :$p was never spawned"; return 1; }
}
# <first ident line> <key> <port=host:port>...: each ssh since then is asked for that node, that key and the shared options.
args_ok() {
  local from=$1 key=$2 pt p; shift 2
  for pt in "$@"; do
    p=${pt%%=*}
    asked "$from" "$p" "-i $key" "-L $p:${pt#*=}" -N "-o ExitOnForwardFailure=yes" "-o ServerAliveInterval=15" \
      "-o ServerAliveCountMax=20" "-o TCPKeepAlive=yes" "-o StrictHostKeyChecking=accept-new" \
      "-o UserKnownHostsFile=.talos-bastion-known-hosts" "-o LogLevel=VERBOSE" "ops@203.0.113.10" || return 1
  done
}
# At least $1 stub ssh are alive and every one ignores SIGHUP (bit 1 of SigIgn): that is nohup.
hup_ignored() {
  local pid n=0 bad=0
  for pid in $(awk '{ print $1 }' "$W/ident"); do
    [ -r "/proc/$pid/cmdline" ] && [[ "$(tr '\0' ' ' <"/proc/$pid/cmdline")" == *"$W/bin/ssh-stub.py"* ]] || continue
    n=$((n + 1)); [ $(( 0x$(awk '/^SigIgn/ { print $2 }' "/proc/$pid/status") & 1 )) = 1 ] || bad=$((bad + 1))
  done
  [ "$n" -ge "$1" ] && [ "$bad" = 0 ]
}

(cd "$W/cluster" && tun open . >"$W/open.out" 2>&1)
{ [ "$(up)" = 4 ] && grep -q '4/4 tunnels up' "$W/open.out" && in_all_logs 'Authenticated to stub' \
  && head -n1 "$(log "$P0")" | grep -qE "^[0-9]{4}(-[0-9]{2}){2} ([0-9]{2}:){2}[0-9]{2} spawn :${P0}$" \
  && [ "$(sort "$W/cluster/.talos-tunnels.pids")" = "$(awk '{ print $1 }' "$W/ident" | sort)" ]; } \
  && ok "open: 4/4 up; each port keeps its ssh's VERBOSE transcript after a dated marker, and every pid is in the pidfile" \
  || bad "open (up=$(up)): $(tail -3 "$W/open.out"); logs: $(ls -a "$W/cluster")"

WHY="$(args_ok 0 "$W/key" "$P0=10.0.0.11:50000" "$P1=10.0.0.12:50000" "$PW=10.0.0.21:50000" "$PA=10.0.0.50:6443")"
{ [ -z "$WHY" ] && hup_ignored 4; } \
  && ok "open: each ssh is asked for its node (the API one for the VIP on :6443), as ops, with the key, keepalive 15 s x 20, -N, its own known_hosts, and ignores HUP" \
  || bad "an ssh was asked for the wrong thing: ${WHY:-HUP not ignored on every live ssh (no nohup)}"

# P0 gets TERM, P1 dies without a word (KILL), PW stays up but nothing answers behind it, and its log is gone (tunnels
# an older script left running).
kill -TERM "$(pid_of "$P0")"; kill -KILL "$(pid_of "$P1")"; touch "$W/blind/$PW"; rm -f "$(log "$PW")"; sleep 1
touch -d '2001-02-03 04:05:06' "$(log "$P0")" # the date quoted is the log's own
ENS="$(cd "$W/cluster" && tun ensure . 2>"$W/ensure.err")"; RC=$?; ERR="$(<"$W/ensure.err")"
DATE='[0-9]{4}(-[0-9]{2}){2} ([0-9]{2}:){2}[0-9]{2}'
{ [ "$RC" = 0 ] \
  && grep -qE ":${P0}  ssh EXITED; log, last written 2001-02-03 04:05:06, ends: Authenticated to stub[^|]*\|Transferred: sent 0[^|]*\|Bytes per second: [^|]*$" <<<"$ERR" \
  && grep -qE ":${P1}  ssh EXITED; log, last written ${DATE}, ends: ${DATE} spawn :${P1}\|Authenticated to stub[^|]*$" <<<"$ERR" \
  && grep -qE ":${PW}  ssh still running, nothing answered through it; no transcript at .*/\.talos-tunnel-${PW}\.log$" <<<"$ERR" \
  && ! grep -qE "ssh EXITED|ssh still running" <<<"$ENS"; } \
  && ok "ensure, on stderr, quotes the last 3 lines and date of each dead tunnel's log (a TERM's closing lines, a KILL's none, a missing log) and tells a live ssh from a dead one" \
  || bad "ensure (rc ${RC}): stdout: ${ENS}; stderr: ${ERR}"

# ensure rebuilt through `open`: a new generation, appended after the old one's last lines (PW's log began again).
GEN=1; for p in "${LOGS[@]}"; do
  want=2; [ "$p" = "$PW" ] && want=1
  [ "$(grep -c ' spawn :' "$(log "$p")" 2>/dev/null)" = "$want" ] && [ "$(grep -c 'Authenticated' "$(log "$p")" 2>/dev/null)" = "$want" ] || GEN=0
done
{ [ "$GEN" = 1 ] && [ "$(up)" = 4 ] \
  && awk '/Transferred:/ { t = NR } / spawn :/ { s = NR } END { exit !(t && s > t) }' "$(log "$P0")"; } \
  && ok "…then rebuilds: the log is appended to, so the dead tunnel's lines are still there, before the new generation's" \
  || bad "after ensure: up=$(up) generations ok=${GEN}; $(cat "$(log "$P0")" 2>/dev/null)"

# Two opens at once on the same block: whichever ssh wins a port, nobody's transcript may be cut or overwritten.
N0=$(wc -l <"$W/ident")
(cd "$W/cluster" && { tun open . >"$W/c1.out" 2>&1 & tun open . >"$W/c2.out" 2>&1 & wait; })
TORN=0; for p in "${LOGS[@]}"; do
  [ "$(tr -cd '\000' <"$(log "$p")" 2>/dev/null | wc -c)" = 0 ] || TORN=1
  for pid in $(tail -n +$((N0 + 1)) "$W/ident" | awk -v p="$p" '$2 == p { print $1 }'); do
    grep -q "(pid $pid)" "$(log "$p")" 2>/dev/null || TORN=1
  done
done
{ [ "$(up)" = 4 ] && [ "$TORN" = 0 ]; } \
  && ok "two simultaneous opens: all 4 listening, every ssh's transcript is in its log, none torn" \
  || bad "concurrent opens: up=$(up) torn=${TORN}; $(cat "$(log "$P0")" 2>/dev/null)"

OUT="$(cd "$W/cluster" && STUB_FAIL_PORT="$P1 $PA" tun open . 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && grep -q '2/4 tunnels up' <<<"$OUT" && grep -qE ":${P1}  .*Permission denied" <<<"$OUT" \
  && grep -qE ":${PA}  .*Permission denied" <<<"$OUT" && ! grep -qE ":(${P0}|${PW})  " <<<"$OUT"; } \
  && ok "open that finds 2/4: exits 1 and quotes the log of each failed port (the API one too), only those" \
  || bad "short open (rc ${RC}): ${OUT}"

(cd "$W/cluster" && "$TUN" close . >/dev/null 2>&1); sleep 1
{ [ "$(up)" = 0 ] && in_all_logs 'Authenticated to stub'; } \
  && ok "close stops the tunnels and leaves their transcripts" || bad "close left $(up) listener(s); logs: $(ls -a "$W/cluster")"

# A different key from the state path's: --key must win.
direct() { (cd "$W/cluster" && tun open-direct --bastion 203.0.113.10 --user ops --cps 10.0.0.11,10.0.0.12 --workers 10.0.0.21 \
  --key "$W/key2" 2>&1); }
OUT="$(STUB_FAIL_PORT="$P1 $PW" direct)"; RC=$?
{ [ "$RC" = 1 ] && grep -q '1/3 tunnels up' <<<"$OUT" && grep -qE ":${P1}  .*Permission denied" <<<"$OUT" \
  && grep -qE ":${PW}  .*Permission denied" <<<"$OUT" && ! grep -qE ":${P0}  " <<<"$OUT"; } \
  && ok "open-direct that finds 1/3: exits 1 and quotes the log of each failed port, only those" \
  || bad "short open-direct (rc ${RC}): ${OUT}"

(cd "$W/cluster" && "$TUN" close . >/dev/null 2>&1); sleep 1
N1=$(wc -l <"$W/ident")
direct >"$W/direct.out"
WHY="$(args_ok "$N1" "$W/key2" "$P0=10.0.0.11:50000" "$P1=10.0.0.12:50000" "$PW=10.0.0.21:50000")"
{ [ "$(up)" = 3 ] && [ -z "$WHY" ] && hup_ignored 3 && [ "$(wc -l <"$W/cluster/.talos-tunnels-direct.pids")" = 3 ] \
  && grep -q 'Authenticated to stub' "$W/cluster/.talos-tunnel-direct-$P0.log" \
  && grep -q 'Authenticated to stub' "$W/cluster/.talos-tunnel-direct-$PW.log"; } \
  && ok "open-direct goes through the same spawn: 3 up asked for the right nodes and --key, its own pidfile and transcripts" \
  || bad "open-direct (up=$(up)): ${WHY:-$(tail -3 "$W/direct.out")}; $(ls -a "$W/cluster")"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
