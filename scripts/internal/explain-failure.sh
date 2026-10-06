#!/usr/bin/env bash
# ==============================================================================
# Say what a FAILED run left behind, and what re-running would cost.
#
# WHY. Two shapes that named neither their cause nor their fix:
#   TAINTED — a create that times out is marked tainted, so the obvious reaction
#   (re-run) DESTROYS what the provider was nearly finished building. An hour
#   went into that loop, and nothing on screen ever said the word "tainted".
#   GONE — a load balancer the provider deleted behind OpenTofu's back left its
#   ip in state; every plan then died on "http error 404 Not Found", naming
#   neither the ghost nor `tofu state rm`. Forty minutes, three paid runs.
#
#   LOCKED — a run killed hard (SIGKILL, a crashed runner, a closed laptop) never
#   releases its state lock, and every later plan and apply stops on it. The
#   transcript names the holder; nothing said that a dead holder is the usual
#   reason, nor what releases the lock. Seen 2026-10-03 on a live cluster.
#
# State cannot tell the second shape by itself — it records what OpenTofu
# BELIEVES. Only the provider's own words say otherwise, and they survive in the
# transcript the Taskfile tees ($LOG): no transcript, no such diagnosis, never a
# guess. An address is named only when both sources agree — the provider said
# "not found" about it AND the state still holds it.
#
# Run from a Taskfile `defer:` guarded on {{.EXIT_CODE}}, so it costs nothing
# when the run succeeded. Never fails the caller: it is a diagnosis, and a
# diagnosis that breaks the build is worse than no diagnosis.
#
# Usage: explain-failure.sh <tofu_dir>
# ==============================================================================
set -uo pipefail
cd "${1:-.}" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0
LOG=.tofu-run.log

# The lock needs the transcript only, so it comes before anything that reads state.
# The LAST lock error in the file: the transcript is appended to across runs.
LOCK=""
[ -f "$LOG" ] && LOCK="$(sed -E 's/\x1b\[[0-9;]*m//g; s/^[│[:space:]]+//' "$LOG" 2>/dev/null | awk '
  /Error acquiring the state lock/ { blk = ""; f = 1; next }
  f && /^(ID|Operation|Who|Created):/ { blk = blk $0 "\n" }
  f && /OpenTofu acquires a state lock/ { last = blk; f = 0 }
  END { printf "%s", last }')"
if [ -n "$LOCK" ]; then
  LOCKID="$(awk '/^ID:/ { print $2; exit }' <<<"$LOCK")"
  printf '\n\033[33m─── the state is locked ───\033[0m\n' >&2
  printf 'A run holds the state lock:\n\n' >&2
  sed 's/^/    /' <<<"$LOCK" >&2
  cat >&2 <<TXT

  A run killed hard (SIGKILL, a crashed runner, a closed laptop) never releases
  its lock, and every later plan and apply stops here. First make sure that run
  is really gone: it is live while its process (on the host named in Who) or its
  CI job still runs, and releasing a lock a live apply holds lets two writers
  corrupt the state. If it is gone, release exactly that lock, from $(pwd) with
  the S3 credentials of .env.sh exported:

    TF_DATA_DIR=${TF_DATA_DIR:-.terraform} tofu force-unlock -force ${LOCKID:-<ID>}

TXT
fi

# The bastion carries the Talos tunnels: an apply that modifies, replaces or stops it kills them mid-run, and every
# config apply after that dials a closed local port (OVH replaced it, Outscale modified it in place, 2026-10-06).
# Transcript only: both lines must be there, a refused port alone is not this.
if [ -f "$LOG" ]; then
  CLEAN="$(sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null)"
  if grep -Eq '\.bastion: (Modifying|Destroying|Creating)\.\.\.' <<<"$CLEAN" &&
     grep -Eq 'dial tcp 127\.0\.0\.1:[0-9]+: connect: connection refused' <<<"$CLEAN"; then
    printf '\n\033[33m─── the bastion changed under the tunnels ───\033[0m\n' >&2
    cat >&2 <<'TXT'
This apply modified, replaced or stopped the bastion, and the Talos tunnels run through it: they died with the
old one, so the config applies after it dialled a closed local port. The bastion change LANDED. Re-run the same
command: the tunnels are rebuilt at its start and the plan no longer touches the bastion; the config applies that
failed are created again and send the same configuration, which changes nothing on a node. If it fails the same
way, run `task tunnels-up PROVIDER=<p>` and read what it says.

TXT
  fi
fi

STATE="$(timeout 90 tofu state pull 2>/dev/null)" || exit 0
[ -n "$STATE" ] || exit 0

# One "<status><TAB><address>" per instance, addressed the way OpenTofu prints
# it — a data source carries a "data." segment (measured). Data rows are kept
# and marked, not dropped: `mode == "data"` is absent from some states, and a
# missing field must not silently empty the list.
ROWS="$(jq -r '
  .resources[]? as $r | $r.instances[]? |
  (if $r.mode == "data" then "data" else (.status // "ok") end) + "\t" +
  ($r.module // "" | if . == "" then "" else . + "." end) +
  (if $r.mode == "data" then "data." else "" end) + $r.type + "." + $r.name +
  (if .index_key == null then ""
   elif (.index_key|type) == "string" then "[\"" + .index_key + "\"]"
   else "[" + (.index_key|tostring) + "]" end)
' <<<"$STATE" 2>/dev/null)"
TAINTED="$(awk -F'\t' '$1 == "tainted" { print $2 }' <<<"$ROWS")"

# Diagnostics are boxed and coloured even when redirected to a file (measured on
# OpenTofu 1.12.5), so match inside the line rather than anchoring it. Scoped to
# ONE box: an address quoted by some other error is not a ghost.
# Data sources are excluded: they are re-read on every plan, so `state rm` is
# never their fix, however loudly the provider 404s about one.
GONE=""
[ -f "$LOG" ] && GONE="$(awk -v addrs="$(awk -F'\t' '$1 != "data" { print $2 }' <<<"$ROWS")" '
  function flush(  n, a, i) {
    if (tolower(box) ~ /404|not[ _]?found/) {
      n = split(addrs, a, "\n")
      for (i = 1; i <= n; i++) if (a[i] != "" && index(box, a[i])) print a[i]
    }
    box = ""
  }
  { l = $0; gsub(/\033\[[0-9;]*m/, "", l) }
  index(l, "Error:") { flush(); box = l; next }
  index(l, "╵")      { flush(); next }
  box != ""          { box = box "\n" l }
  END { flush() }
' "$LOG" 2>/dev/null | sort -u)"

[ -n "$TAINTED$GONE" ] || exit 0
hdr()  { printf '\n\033[33m─── %s ───\033[0m\n' "$1" >&2; }
list() { sed 's/^/    /' >&2; }
cmds() { while IFS= read -r a; do [ -n "$a" ] && printf "    tofu %s '%s'\n" "$1" "$a" >&2; done; }

if [ -n "$TAINTED" ]; then
  hdr 'what the failure left behind'
  printf 'OpenTofu marked %s resource(s) TAINTED:\n\n' "$(wc -l <<<"$TAINTED")" >&2
  list <<<"$TAINTED"
  cat >&2 <<'TXT'

  A tainted resource is DESTROYED AND REBUILT on the next apply. If it timed out
  while the provider was still creating it — the usual case for a load balancer —
  re-running throws away the one that was nearly ready and pays the wait again.

  Ask the provider what state it is really in FIRST. If the provider says the
  resource is fine, keep it instead of rebuilding:

TXT
  cmds untaint <<<"$TAINTED"
  printf '\n  Then re-run. If the provider says it is genuinely stuck, leave it tainted.\n' >&2
  printf '  A managed load balancer stuck mid-creation cannot be deleted by anyone but\n' >&2
  printf '  the provider, and it pins the network behind it — see .claude/skills/teardown.\n\n' >&2
fi

if [ -n "$GONE" ]; then
  hdr 'the provider says it is already gone'
  printf 'The run failed with a "not found" about object(s) still held in state:\n\n' >&2
  list <<<"$GONE"
  cat >&2 <<'TXT'

  Retrying cannot fix that: every plan re-reads the same dead id. Confirm with
  the provider that the object is REALLY gone — `state rm` only makes OpenTofu
  forget it, and if it does still exist you have just made an orphan nobody
  will ever destroy. Once confirmed, drop it and re-run:

TXT
  cmds 'state rm' <<<"$GONE"
  printf '\n' >&2
fi
exit 0
