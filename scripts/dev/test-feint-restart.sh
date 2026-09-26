#!/usr/bin/env bash
# feint.sh's start/restart path checked `running` exactly once, immediately
# after `feint start` returned. `feint start` returning — even printing its
# own "listening on ..." line — does not guarantee the status endpoint
# already answers: this raced on a GitHub-hosted runner and failed CI once
# (PR #168, "Feint Evidence (outscale)"), passing again on an unmodified
# re-run of the same commit (#169).
#
# A stub `feint` puts the delay under our control: `status` reports
# "running on ..." only OA_STUB_DELAY seconds after `start` was called.
# OA_STUB_CHATTY keeps printing after that line, as the real `status` does: a
# reader that stops early kills it on SIGPIPE, and pipefail then reads "down".
# FEINT_RESTART_TIMEOUT=0 reproduces the EXACT pre-fix behavior — a single
# immediate check, no retry — through the real code path, not a diff revert.
#
# Offline: no cloud, no account, no real feint process, no Incus.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

SB="$(mktemp -d)"; LOG="$SB/calls.log"; STATE="$SB/state"
# The pin itself: a stub reporting any other version makes install_feint
# download the real binary, and this test is offline.
PIN="$(sed -nE 's/^FEINT_VERSION="([^"]+)".*/\1/p' scripts/dev/feint.sh)"
trap 'rm -rf "$SB"' EXIT
[ -n "$PIN" ] || { echo "✗ no FEINT_VERSION=\"x.y.z\" line found in scripts/dev/feint.sh; the stub cannot report the pin" >&2; exit 1; }

# start: records when it was called. status: "running on ..." only once
# OA_STUB_DELAY seconds have elapsed since — or never, if OA_STUB_NEVER_READY.
cat >"$SB/feint" <<'STUB'
#!/usr/bin/env bash
printf 'feint:%s\n' "$*" >>"$OA_STUB_LOG"
case "$1" in
  version) printf 'v%s\n' "$OA_STUB_VERSION"; exit 0 ;;
  start) date +%s >"$OA_STUB_STATE"; exit 0 ;;
  stop)  rm -f "$OA_STUB_STATE"; exit 0 ;;
  status)
    if [ "${OA_STUB_NEVER_READY:-0}" = 1 ] || [ ! -f "$OA_STUB_STATE" ]; then
      echo "not running"; exit 0
    fi
    started="$(cat "$OA_STUB_STATE")"; now="$(date +%s)"
    if [ $((now - started)) -ge "${OA_STUB_DELAY:-0}" ]; then
      echo "running on 127.0.0.1:4599 (pid 1, since $(date -u +%FT%TZ))"
      if [ "${OA_STUB_CHATTY:-0}" = 1 ]; then
        sleep 1
        printf '  resources  0\n' || exit 141
      fi
    else
      echo "not running yet"
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$SB/feint"

run() { # <FEINT_RESTART_TIMEOUT> <OA_STUB_DELAY> [OA_STUB_NEVER_READY]
  : >"$LOG"; rm -f "$STATE"
  env -i PATH="$SB:$PATH" HOME="$SB" OA_STUB_VERSION="$PIN" \
      OA_STUB_LOG="$LOG" OA_STUB_STATE="$STATE" OA_STUB_DELAY="$2" OA_STUB_NEVER_READY="${3:-0}" \
      FEINT_RESTART_TIMEOUT="$1" FEINT_ENDPOINT="http://127.0.0.1:4599" \
      ./scripts/dev/feint.sh start </dev/null 2>&1
}
calls() { grep -c "^feint:$1" "$LOG"; }

echo "--- status is slow to catch up, well within the timeout: succeeds ---"
START="$(date +%s)"
OUT="$(run 5 2)"; RC=$?
ELAPSED=$(( $(date +%s) - START ))
[ "$RC" -eq 0 ] && ok "start succeeds once status catches up (rc=$RC)" || bad "start failed: $OUT"
[ "$ELAPSED" -ge 2 ] && ok "it actually kept checking (${ELAPSED}s elapsed, delay was 2s)" \
                     || bad "returned too fast (${ELAPSED}s) — is poll_running retrying at all?"
grep -q "^running on" <<<"$OUT" && ok "the final status line is printed" || bad "no status line: $OUT"

echo "--- FEINT_RESTART_TIMEOUT=0 reproduces the exact pre-fix bug: one check, no retry ---"
OUT="$(run 0 2)"; RC=$?
[ "$RC" -ne 0 ] && ok "fails immediately, same as before this fix (rc=$RC)" \
                || bad "rc=0 with zero retry budget — poll_running is not actually being exercised above"
grep -qi "did not come up" <<<"$OUT" && ok "and names what happened" || bad "$OUT"

echo "--- the emulator never becomes ready: fails within the timeout, not hung ---"
START="$(date +%s)"
OUT="$(run 2 999 1)"; RC=$?
ELAPSED=$(( $(date +%s) - START ))
[ "$RC" -ne 0 ] && ok "fails (rc=$RC)" || bad "rc=0 with an emulator that never came up"
[ "$ELAPSED" -le 4 ] && ok "bounded by the timeout, not hung (${ELAPSED}s)" || bad "took ${ELAPSED}s — no upper bound?"
grep -qi "did not come up" <<<"$OUT" && ok "names the failure" || bad "$OUT"
grep -qi "no log at\|Last lines of" <<<"$OUT" && ok "and points at the emulator's own log" || bad "$OUT"

echo "--- no XDG_RUNTIME_DIR (env -i): the log is read where feint writes it then ---"
mkdir -p "$SB/.local/state/feint/127.0.0.1_4599"
echo "oa-stub-log-line" >"$SB/.local/state/feint/127.0.0.1_4599/feint.log"
OUT="$(run 0 999 1)"
grep -q "oa-stub-log-line" <<<"$OUT" && ok "prints the log from ~/.local/state/feint" || bad "$OUT"

already_running() { # [OA_STUB_CHATTY]
  : >"$LOG"; date +%s >"$STATE"
  env -i PATH="$SB:$PATH" HOME="$SB" OA_STUB_VERSION="$PIN" OA_STUB_LOG="$LOG" OA_STUB_STATE="$STATE" \
      OA_STUB_DELAY=0 OA_STUB_CHATTY="${1:-0}" FEINT_RESTART_TIMEOUT=2 FEINT_ENDPOINT="http://127.0.0.1:4599" \
      ./scripts/dev/feint.sh start </dev/null 2>&1
}

echo "--- already running: no restart is attempted at all ---"
OUT="$(already_running)"; RC=$?
[ "$RC" -eq 0 ] && ok "start on an already-running emulator succeeds" || bad "$OUT"
[ "$(calls start)" = 0 ] && ok "…and 'feint start' was never called" || bad "feint start was called: $(grep '^feint:start' "$LOG")"

echo "--- already running, status keeps printing after its first line: still running ---"
OUT="$(already_running 1)"; RC=$?
[ "$RC" -eq 0 ] && ok "start succeeds (rc=$RC)" || bad "$OUT"
[ "$(calls start)" = 0 ] && ok "…without restarting an emulator that was up" \
  || bad "running() reported a live emulator as down, and 'feint start' was called"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
