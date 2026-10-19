#!/usr/bin/env bash
# scripts/ops/etcd-snapshot-cron.sh with two runs at once. The one that loses the flock must exit quietly: it may not close the
# tunnels the winner is using, nor say "complete" (lab 11: the EXIT trap was armed before the lock). Stub task/tofu/talosctl/aws/gpg and a
# stub tunnel helper; nothing connects anywhere. SUT overrides the script (mutants).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/etcd-snapshot-cron.sh}"
TMP="$(mktemp -d)"
WINNER_PID=""
cleanup() { [ -z "$WINNER_PID" ] || kill "$WINNER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
command -v flock >/dev/null || { echo "~ flock is not installed: skipped"; exit 0; }

# The script derives its root from its own path: a copy in a tree that has the stub tunnel helper.
mkdir -p "$TMP/tree/scripts/ops" "$TMP/tree/scripts/bootstrap" "$TMP/bin" "$TMP/home"
cp "$SUT" "$TMP/tree/scripts/ops/etcd-snapshot-cron.sh"
# The script puts /usr/local/bin and others BEFORE the PATH it was given (cron has none), where a real `task` may live: the env
# file it sources is read after that, so the stubs are put first there.
printf 'export PATH="%s/bin:$PATH"\n' "$TMP" >"$TMP/tree/.env.sh"; chmod 600 "$TMP/tree/.env.sh"
cat >"$TMP/tree/scripts/bootstrap/talos-tunnels.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$TUNNEL_LOG"
STUB
chmod +x "$TMP/tree/scripts/bootstrap/talos-tunnels.sh"
for t in tofu talosctl aws gpg; do printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/$t"; chmod +x "$TMP/bin/$t"; done
# `task etcd-snapshot` holds the lock until released: it marks that it started, then waits for the release file.
cat >"$TMP/bin/task" <<'STUB'
#!/usr/bin/env bash
: >"$HOLDING"
for _ in $(seq 1 100); do [ -e "$RELEASE" ] && exit "${TASK_RC:-0}"; sleep 0.1; done
exit 9
STUB
chmod +x "$TMP/bin/task"
export TUNNEL_LOG="$TMP/tunnels.log" HOLDING="$TMP/holding" RELEASE="$TMP/release" HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
CRON="$TMP/tree/scripts/ops/etcd-snapshot-cron.sh"

echo "=== two runs at once ==="
bash "$CRON" ovh "$TMP/key" >"$TMP/winner.out" 2>&1 &
WINNER_PID=$!
for _ in $(seq 1 100); do [ -e "$HOLDING" ] && break; sleep 0.1; done
[ -e "$HOLDING" ] || { bad "the first run never reached the snapshot step: $(cat "$TMP/winner.out")"; printf '%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }

LOSER_OUT="$(bash "$CRON" ovh "$TMP/key" 2>&1)"; LOSER_RC=$?
[ "$LOSER_RC" = 0 ] && grep -q 'a run is already in progress' <<<"$LOSER_OUT" && ok "the second run sees the lock and exits 0 with a message" || bad "loser: rc=$LOSER_RC $LOSER_OUT"
! grep -q 'complete' <<<"$LOSER_OUT" && ok "the run that lost the lock does not claim the snapshot is complete" || bad "the loser printed 'complete': $LOSER_OUT"
[ ! -s "$TUNNEL_LOG" ] && ok "the run that lost the lock did not close the winner's tunnels" || bad "the loser closed the tunnels: $(cat "$TUNNEL_LOG")"

: >"$RELEASE"; wait "$WINNER_PID"; WRC=$?; WINNER_PID=""
[ "$WRC" = 0 ] && grep -q 'complete' "$TMP/winner.out" && ok "the winner finishes and says complete" || bad "winner: rc=$WRC $(cat "$TMP/winner.out")"
[ "$(wc -l <"$TUNNEL_LOG")" = 1 ] && grep -q '^close' "$TUNNEL_LOG" && ok "the winner closes its tunnels once, at the end" || bad "tunnel log: $(cat "$TUNNEL_LOG" 2>&1)"

echo "=== a failing run still reports and cleans up ==="
rm -f "$HOLDING" "$TUNNEL_LOG"; : >"$RELEASE"
OUT="$(TASK_RC=3 bash "$CRON" ovh "$TMP/key" 2>&1)"; RC=$?
[ "$RC" = 3 ] && grep -q 'failed (code 3)' <<<"$OUT" && [ "$(wc -l <"$TUNNEL_LOG")" = 1 ] && ok "a failed snapshot exits with its code, says so and closes the tunnels it opened" || bad "failing run: rc=$RC $OUT $(cat "$TUNNEL_LOG" 2>&1)"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
