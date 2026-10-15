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
cp "$ROOT/scripts/lib/bastion-hostkey.sh" "$W/scripts/lib/"
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
def say(s):
    sys.stderr.write(s + "\n"); sys.stderr.flush()
# With STUB_HOSTKEY ("ssh-ed25519 AAAA..." = the key the server presents) the stub checks the host key like ssh does:
# a known host with another key is refused, an unknown one is refused under StrictHostKeyChecking=yes and recorded
# under accept-new. Without it the stub trusts everything, as before.
key = os.environ.get("STUB_HOSTKEY")
if key:
    opt = lambda n, d=None: next((x.split("=", 1)[1] for x in a if x.startswith(n + "=")), d)
    kh, shkc = opt("UserKnownHostsFile"), opt("StrictHostKeyChecking", "ask")
    host = [x for x in a if "@" in x][-1].split("@")[-1]
    known = {}
    if kh and os.path.exists(kh):
        for line in open(kh):
            f = line.split()
            if len(f) >= 3: known[f[0]] = " ".join(f[1:3])
    if host in known:
        if known[host] != key:
            say("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"); say("Host key verification failed."); sys.exit(255)
    elif shkc == "yes":
        say(f"No ED25519 host key is known for {host} and you have requested strict checking."); say("Host key verification failed."); sys.exit(255)
    elif kh:
        open(kh, "a").write(f"{host} {key}\n")
if "true" in a:
    sys.exit(0)
port = int(a[a.index("-L") + 1].split(":")[0])
signal.alarm(180)
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

echo "=== OA_BASTION_PIN_HOSTKEY: the bastion's key is kept and a different one is refused ==="
(cd "$W/cluster" && "$TUN" close . >/dev/null 2>&1); sleep 1
ssh-keygen -q -t ed25519 -N '' -f "$W/hk1"; ssh-keygen -q -t ed25519 -N '' -f "$W/hk2"
K1="$(cut -d' ' -f1,2 "$W/hk1.pub")"; K2="$(cut -d' ' -f1,2 "$W/hk2.pub")"
FP1="$(ssh-keygen -lf "$W/hk1.pub" | awk '{ print $2 }')"; FP2="$(ssh-keygen -lf "$W/hk2.pub" | awk '{ print $2 }')"
KH="$W/cluster/.talos-bastion-known-hosts"
open_pin() { K="$1"; shift; OUT="$(cd "$W/cluster" && env STUB_HOSTKEY="$K" "$@" env --default-signal=HUP "$TUN" open . 2>&1)"; RC=$?; }
close_all() { (cd "$W/cluster" && "$TUN" close . >/dev/null 2>&1); sleep 1; }

: >"$KH"; N2=$(wc -l <"$W/ident")
open_pin "$K1" OA_BASTION_PIN_HOSTKEY=1
{ [ "$RC" = 0 ] && [ "$(up)" = 4 ] && grep -q "^203.0.113.10 $K1\$" "$KH" && grep -q 'NOT verified out of band' <<<"$OUT" && grep -q "$FP1" <<<"$OUT"; } \
  && ok "pin=1, first contact: the key is kept in known_hosts, its fingerprint is printed with the warning, 4/4 up" \
  || bad "first pinned contact (rc ${RC}, up=$(up)): $OUT; kh: $(cat "$KH")"
{ asked "$N2" "$P0" "-o StrictHostKeyChecking=yes" "-o UserKnownHostsFile=.talos-bastion-known-hosts" && asked "$N2" "$PA" "-o StrictHostKeyChecking=yes"; } \
  && ok "…and the tunnels run with StrictHostKeyChecking=yes" || bad "tunnels not strict after pinning: $(asked "$N2" "$P0" "-o StrictHostKeyChecking=yes")"
close_all; BEFORE="$(cat "$KH")"
open_pin "$K1" OA_BASTION_PIN_HOSTKEY=1
{ [ "$RC" = 0 ] && [ "$(up)" = 4 ] && [ "$(cat "$KH")" = "$BEFORE" ] && ! grep -q 'NOT verified' <<<"$OUT"; } \
  && ok "a later run keeps the file as it is, accepts the same key, 4/4 up, no first-contact warning" || bad "repeat run (rc ${RC}, up=$(up)): $OUT"
close_all
open_pin "$K2" OA_BASTION_PIN_HOSTKEY=1
{ [ "$RC" = 1 ] && [ "$(up)" = 0 ] && grep -q 'NOT the one pinned' <<<"$OUT" && [ "$(cat "$KH")" = "$BEFORE" ]; } \
  && ok "the same address answering with ANOTHER key is refused: no tunnel, the pinned key untouched, the way out is named" \
  || bad "changed key was not refused (rc ${RC}, up=$(up)): $OUT"
grep -q 'OA_BASTION_FORGET=1' <<<"$OUT" && ok "…and the refusal says how to re-pin on purpose" || bad "no hint in the refusal"
open_pin "$K2" OA_BASTION_PIN_HOSTKEY=1 OA_BASTION_FORGET=1 OA_BASTION_HOSTKEY_FP="SHA256:notthekeyyouchecked"
{ [ "$RC" != 0 ] && [ "$(up)" = 0 ] && grep -q 'NOT pinned' <<<"$OUT" && ! grep -q "$K2" "$KH"; } \
  && ok "forgetting with a fingerprint that does not match the new key pins nothing" || bad "wrong fingerprint accepted (rc ${RC}, up=$(up)): $OUT; kh: $(cat "$KH")"
open_pin "$K2" OA_BASTION_PIN_HOSTKEY=1 OA_BASTION_FORGET=1 OA_BASTION_HOSTKEY_FP="$FP2"
{ [ "$RC" = 0 ] && [ "$(up)" = 4 ] && grep -q "^203.0.113.10 $K2\$" "$KH" && ! grep -q "$K1" "$KH" && grep -q 'matches the fingerprint given out of band' <<<"$OUT"; } \
  && ok "FORGET with the new key's fingerprint re-pins it (the old key is gone), 4/4 up" || bad "deliberate re-pin (rc ${RC}, up=$(up)): $OUT; kh: $(cat "$KH")"
close_all; : >"$KH"
open_pin "$K1" OA_BASTION_PIN_HOSTKEY=verify
{ [ "$RC" = 1 ] && [ "$(up)" = 0 ] && grep -q 'refusing a first contact nobody checked' <<<"$OUT" && [ ! -s "$KH" ]; } \
  && ok "verify, no fingerprint: a first contact is refused before any connection and nothing is written" || bad "verify without fingerprint (rc ${RC}, up=$(up)): $OUT"
open_pin "$K1" OA_BASTION_PIN_HOSTKEY=verify OA_BASTION_HOSTKEY_FP="$FP1"
{ [ "$RC" = 0 ] && [ "$(up)" = 4 ] && grep -q "^203.0.113.10 $K1\$" "$KH"; } && ok "verify with the right fingerprint pins and opens 4/4" || bad "verify with fingerprint (rc ${RC}, up=$(up)): $OUT"
close_all
open_pin "$K1" OA_BASTION_PIN_HOSTKEY=1 OA_BASTION_HOSTKEY_FP=notafingerprint
[ "$RC" != 0 ] && grep -q 'must look like SHA256' <<<"$OUT" && ok "a malformed OA_BASTION_HOSTKEY_FP is refused" || bad "malformed fingerprint accepted (rc ${RC}): $OUT"
# Without the opt-in, nothing of this exists: the file is emptied, the key is not checked, accept-new as always.
printf '203.0.113.10 %s\n' "$K1" >"$KH"; N3=$(wc -l <"$W/ident")
open_pin "$K2"
{ [ "$RC" = 0 ] && [ "$(up)" = 4 ] && ! grep -q "$K1" "$KH" && args_ok "$N3" "$W/key" "$P0=10.0.0.11:50000" >/dev/null; } \
  && ok "(control) without OA_BASTION_PIN_HOSTKEY a changed key is accepted and the file is emptied, as before" || bad "default behaviour changed (rc ${RC}, up=$(up)): $OUT"
close_all

N4=$(wc -l <"$W/ident")
OUT="$(SSH_USER=alice STUB_HOSTKEY= "$TUN" open "$W/cluster" 2>&1)"; RC=$?
{ [ "$RC" = 0 ] && asked "$N4" "$P0" "alice@203.0.113.10" && asked "$N4" "$PA" "alice@203.0.113.10"; } \
  && ok "SSH_USER=alice: every tunnel logs in as alice instead of the state's bastion_user" || bad "SSH_USER ignored (rc ${RC}): $(asked "$N4" "$P0" "alice@203.0.113.10") $OUT"
close_all

: >"$KH"; rm -f "$W/cluster/.talos-tunnels-direct.pids"; N5=$(wc -l <"$W/ident")
OUT="$(cd "$W/cluster" && STUB_HOSTKEY="$K1" OA_BASTION_PIN_HOSTKEY=1 env --default-signal=HUP "$TUN" open-direct --bastion 203.0.113.10 --user ops --cps 10.0.0.11,10.0.0.12 --workers 10.0.0.21 --key "$W/key" 2>&1)"; RC=$?
{ [ "$RC" = 0 ] && [ "$(up)" = 3 ] && grep -q "^203.0.113.10 $K1\$" "$KH" && asked "$N5" "$P0" "-o StrictHostKeyChecking=yes"; } \
  && ok "open-direct pins the same way (the single-apply path), strict once pinned" || bad "open-direct pinned (rc ${RC}, up=$(up)): $OUT"
close_all
OUT="$(cd "$W/cluster" && STUB_HOSTKEY="$K2" OA_BASTION_PIN_HOSTKEY=1 "$TUN" open-direct --bastion 203.0.113.10 --user ops --cps 10.0.0.11 --key "$W/key" 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && [ "$(up)" = 0 ] && grep -q 'NOT the one pinned' <<<"$OUT"; } && ok "open-direct refuses a changed key too" || bad "open-direct changed key (rc ${RC}, up=$(up)): $OUT"
rm -f "$KH"

# The Terraform side (SCC/F17): the local-exec of terraform_data.talos_tunnels hands its values over as environment
# variables. Its real command is cut out of cluster/main.tf and run against a stub script that records argv, with values a
# shell would split or execute if they were spliced into the command line.
MAIN="$ROOT/infrastructure/opentofu/cluster/main.tf"
HCL_CMD="$(awk '/^resource "terraform_data" "talos_tunnels"/{r=1} r && /command = <<-EOT/{c=1; next} c && /^[[:space:]]*EOT$/{exit} c' "$MAIN")"
STUBTUN="$W/stub-tunnels.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"$ARGV_OUT"\n' >"$STUBTUN"; chmod +x "$STUBTUN"
CMD="${HCL_CMD//\$\{path.module\}\/..\/..\/..\/scripts\/bootstrap\/talos-tunnels.sh/$STUBTUN}"
CMD="${CMD//\$\$\{/\$\{}"
tf_run() { # <workers csv> <user> <key>: the argv the script would receive, one per line
  rm -f "$W/argv.out" "$W/pwned"
  ARGV_OUT="$W/argv.out" OA_TUNNEL_BASTION=203.0.113.10 OA_TUNNEL_USER="$2" OA_TUNNEL_CPS=10.0.0.11,10.0.0.12 \
    OA_TUNNEL_WORKERS="$1" OA_TUNNEL_KEY="$3" bash -c "$CMD" >/dev/null 2>&1
  cat "$W/argv.out" 2>/dev/null
}
{ [ -n "$HCL_CMD" ] && grep -q 'OA_TUNNEL_KEY' <<<"$HCL_CMD" && [[ "$CMD" == *"$STUBTUN"* ]]; } \
  && ok "the talos_tunnels local-exec command is found in cluster/main.tf and points at the stub" \
  || bad "could not cut the local-exec command out of main.tf: ${HCL_CMD:-empty}"
GOT="$(tf_run 10.0.0.21 ops "/home/u/my keys/id ed25519")"
WANT="$(printf '%s\n' open-direct --bastion 203.0.113.10 --user ops --cps 10.0.0.11,10.0.0.12 --key "/home/u/my keys/id ed25519" --workers 10.0.0.21)"
[ "$GOT" = "$WANT" ] && ok "a key path with a space stays one argument; workers are passed as --workers" \
  || bad "argv differs: $(tr '\n' '|' <<<"$GOT")"
GOT="$(tf_run "" ops /k)"
{ [ -n "$GOT" ] && ! grep -q -- '--workers' <<<"$GOT"; } && ok "no workers: --workers is not passed" || bad "empty workers: $(tr '\n' '|' <<<"$GOT")"
GOT="$(tf_run "" 'x; touch '"$W"'/pwned' '$(touch '"$W"'/pwned)')"
{ [ ! -e "$W/pwned" ] && grep -qF 'x; touch' <<<"$GOT" && grep -qF '$(touch' <<<"$GOT"; } \
  && ok "a user name and a key path full of shell syntax are data: nothing ran, both arrived verbatim" \
  || bad "shell metacharacters were interpreted (pwned: $([ -e "$W/pwned" ] && echo yes || echo no)): $(tr '\n' '|' <<<"$GOT")"
# The environment block is not part of the command and a mock plan does not run it: without pathexpand() the default
# "~/.ssh/..." reaches the script unexpanded, since an env value is not tilde-expanded by the shell.
grep -Eq '^[[:space:]]*OA_TUNNEL_KEY[[:space:]]*=[[:space:]]*pathexpand\(var\.ssh_key_path\)[[:space:]]*$' "$ROOT/infrastructure/opentofu/cluster/main.tf" \
  && ok "OA_TUNNEL_KEY is pathexpand(var.ssh_key_path): the default ~/.ssh/... is expanded before the script sees it" \
  || bad "main.tf no longer expands the key path with pathexpand()"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
