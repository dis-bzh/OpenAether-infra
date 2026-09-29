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
# Like feint, the stub keeps one emulator per --addr, refuses a second start or
# a proxy on one, and falls back to 127.0.0.1:4599 without --addr: a call that
# forgets it hits the wrong emulator.
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
# feint.sh finds its repository from its own path, and the record lane writes a
# backend override into that cluster root: run a copy rooted in the sandbox.
FEINT="$SB/repo/scripts/dev/feint.sh"
mkdir -p "$SB/repo/scripts/dev" "$SB/repo/infrastructure/opentofu/cluster/envs" "$SB/repo/infrastructure/opentofu-feint"
cp scripts/dev/feint.sh "$FEINT"
cp infrastructure/opentofu/cluster/envs/feint-*.tfvars.example "$SB/repo/infrastructure/opentofu/cluster/envs/"

# start: records when it was called. status: "running on ..." only once
# OA_STUB_DELAY seconds have elapsed since — or never, if OA_STUB_NEVER_READY.
cat >"$SB/feint" <<'STUB'
#!/usr/bin/env bash
printf 'feint:%s\n' "$*" >>"$OA_STUB_LOG"
addr=127.0.0.1:4599; prev=""
for a in "$@"; do [ "$prev" = --addr ] && addr="$a"; prev="$a"; done
st="$OA_STUB_STATE/$addr"
case "$1" in
  version) printf 'v%s\n' "$OA_STUB_VERSION"; exit 0 ;;
  start) [ ! -f "$st" ] || { echo "feint: already running on $addr; stop it first"; exit 1; }
         date +%s >"$st"; exit 0 ;;
  stop)  rm -f "$st"; exit 0 ;;
  proxy) [ ! -f "$st" ] || { echo "feint: listen tcp $addr: bind: address already in use"; exit 1; }
         exec sleep 10 ;;
  status)
    if [ "${OA_STUB_NEVER_READY:-0}" = 1 ] || [ ! -f "$st" ]; then
      echo "not running"; exit 0
    fi
    started="$(cat "$st")"; now="$(date +%s)"
    if [ $((now - started)) -ge "${OA_STUB_DELAY:-0}" ]; then
      echo "running on $addr (pid 1, since $(date -u +%FT%TZ))"
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
# A stub tofu ends an apply lane right after its reset_emulator: nothing is planned.
cat >"$SB/tofu" <<'STUB'
#!/usr/bin/env bash
printf 'tofu:%s\n' "$*" >>"$OA_STUB_LOG"; exit 1
STUB
chmod +x "$SB/feint" "$SB/tofu"

fresh() { : >"$LOG"; rm -rf "$STATE"; mkdir "$STATE"; }
# An emulator already up on <addr>, started long enough ago to answer status.
seed_up() { echo 1 >"$STATE/$1"; }

run() { # <FEINT_RESTART_TIMEOUT> <OA_STUB_DELAY> [OA_STUB_NEVER_READY]
  fresh
  env -i PATH="$SB:$PATH" HOME="$SB" OA_STUB_VERSION="$PIN" \
      OA_STUB_LOG="$LOG" OA_STUB_STATE="$STATE" OA_STUB_DELAY="$2" OA_STUB_NEVER_READY="${3:-0}" \
      FEINT_RESTART_TIMEOUT="$1" FEINT_ENDPOINT="http://127.0.0.1:4599" \
      "$FEINT" start </dev/null 2>&1
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
  fresh; seed_up 127.0.0.1:4599
  env -i PATH="$SB:$PATH" HOME="$SB" OA_STUB_VERSION="$PIN" OA_STUB_LOG="$LOG" OA_STUB_STATE="$STATE" \
      OA_STUB_DELAY=0 OA_STUB_CHATTY="${1:-0}" FEINT_RESTART_TIMEOUT=2 FEINT_ENDPOINT="http://127.0.0.1:4599" \
      "$FEINT" start </dev/null 2>&1
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

echo "--- another endpoint, with an emulator on 4599: every lifecycle call acts on the endpoint ---"
ALT=127.0.0.1:4699
on_alt() { # <feint.sh args...>
  env -i PATH="$SB:$PATH" HOME="$SB" TMPDIR="$SB" OA_STUB_VERSION="$PIN" OA_STUB_LOG="$LOG" \
      OA_STUB_STATE="$STATE" OA_STUB_DELAY=0 FEINT_RESTART_TIMEOUT=2 FEINT_ENDPOINT="http://$ALT" \
      "$FEINT" "$@" </dev/null 2>&1
}
stray() { grep -E '^feint:(start|stop|status)' "$LOG" | grep -vF -- "--addr $ALT"; }
fresh
OUT="$(on_alt start)"; RC=$?
[ "$RC" -eq 0 ] && ok "start on $ALT succeeds (rc=$RC)" || bad "start on $ALT failed: $OUT"
[ -z "$(stray)" ] && ok "…with every call aimed at $ALT" || bad "calls not aimed at $ALT: $(stray)"
fresh; seed_up 127.0.0.1:4599
OUT="$(on_alt status)"
[ "$OUT" = "not running" ] && ok "status on $ALT does not report the one on 4599" \
                           || bad "status on $ALT answered: $OUT"
seed_up "$ALT"; on_alt stop >/dev/null
[ ! -f "$STATE/$ALT" ] && [ -f "$STATE/127.0.0.1:4599" ] && ok "stop on $ALT stops it and leaves 4599 up" \
                                                         || bad "after stop, up: $(ls "$STATE")"
fresh; seed_up 127.0.0.1:4599; seed_up "$ALT"
OUT="$(on_alt apply scaleway)"
grep -q '^tofu:init' "$LOG" && ok "an apply lane on $ALT gets past its reset" || bad "reset on $ALT failed: $OUT"
# seed_up wrote 1; only a stub start writes the time.
[ -f "$STATE/$ALT" ] && [ "$(cat "$STATE/$ALT")" != 1 ] && ok "…which restarted the one on $ALT" \
                                                       || bad "the reset did not restart the emulator on $ALT"
[ "$(cat "$STATE/127.0.0.1:4599" 2>/dev/null)" = 1 ] && ok "…without stopping or restarting the one on 4599" \
                                                     || bad "the reset stopped or restarted the emulator on 4599"
[ -z "$(stray)" ] && ok "…with every call aimed at $ALT" || bad "calls not aimed at $ALT: $(stray)"

echo "--- a record lane on $ALT, with 4600 taken: its proxy follows the endpoint ---"
fresh; seed_up "$ALT"; seed_up 127.0.0.1:4600
OUT="$(on_alt record outscale)"
grep -q '^feint:proxy .*--addr 127.0.0.1:4700' "$LOG" && grep -q '^tofu:init' "$LOG" \
  && ok "its proxy listens on 4700, and the lane goes on" || bad "proxy: $(grep '^feint:proxy' "$LOG"); $OUT"
fresh; seed_up "$ALT"; seed_up 127.0.0.1:4700
OUT="$(on_alt record outscale)"
! grep -q '^tofu:' "$LOG" && grep -q 'proxy did not start' <<<"$OUT" \
  && ok "…and with 4700 taken, it stops before tofu runs" || bad "a dead proxy went unnoticed: $OUT"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
