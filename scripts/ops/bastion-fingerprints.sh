#!/usr/bin/env bash
# ==============================================================================
# bastion-fingerprints.sh — which person holds the key behind a login line (ANSSI PA-012 R2, HYG-M8)
#
# sshd logs "Accepted publickey for <account> ... SHA256:<fingerprint>". With bastion_admins the account is the person;
# for the shared account (bastion_ssh_keys) only the fingerprint tells keys apart. This prints the table
#   account <TAB> fingerprint <TAB> type <TAB> comment
# from the public keys in the state (`tofu output bastion_access_keys`), to keep next to the pulled logs
# (scripts/ops/bastion-logs-pull.sh) and to answer "whose key was that". The shared account is listed as
# shared:<provider>; a key held by several people there cannot be told apart, which is the reason to use bastion_admins.
#
# Usage: bastion-fingerprints.sh [tofu_dir]            (default infrastructure/opentofu/cluster)
#        bastion-fingerprints.sh -f keys.json          the output as a file (what the tests use)
#        bastion-fingerprints.sh ... --find SHA256:xx  only the row of that fingerprint; exit 1 when no key has it
# Needs: ssh-keygen, jq (and tofu unless -f).
# ==============================================================================
set -euo pipefail

FILE=""; DIR=""; FIND=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) FILE="${2:?-f needs a file}"; shift 2 ;;
    --find) FIND="${2:?--find needs a SHA256:... fingerprint}"; shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) DIR="$1"; shift ;;
  esac
done
for bin in ssh-keygen jq; do command -v "$bin" >/dev/null 2>&1 || { echo "✗ $bin is required" >&2; exit 2; }; done
if [ -n "$FILE" ]; then
  [ -f "$FILE" ] || { echo "✗ no such file: $FILE" >&2; exit 2; }
  JSON="$(cat "$FILE")"
else
  command -v tofu >/dev/null 2>&1 || { echo "✗ tofu is required (or pass -f keys.json)" >&2; exit 2; }
  # tofu's own error is kept: "cannot read the state" and "the output does not exist" are different problems with different cures
  # (lab 11 read the first as "apply the infra first", from a shell that simply lacked the backend settings).
  TOFU_ERR="$(mktemp)"; trap 'rm -f "$TOFU_ERR"' EXIT
  if JSON="$(tofu -chdir="${DIR:-infrastructure/opentofu/cluster}" output -json bastion_access_keys 2>"$TOFU_ERR")"; then
    [ -n "$JSON" ] && [ "$JSON" != null ] || { echo "✗ the bastion_access_keys output is empty - apply the infra first (an older state has no such output)" >&2; exit 2; }
  elif grep -qiE 'output.*not found|no outputs? (found|defined)|not (a )?(valid )?output' "$TOFU_ERR"; then
    echo "✗ the state has no bastion_access_keys output - apply the infra first" >&2; exit 2
  else
    echo "✗ tofu could not read the state, so nothing was learned about the keys. tofu said:" >&2
    tail -n 8 "$TOFU_ERR" | sed 's/^/    /' >&2
    echo "  Fix: run it where the backend is reachable (the S3 credentials and the TF_DATA_DIR of this cluster exported)," >&2
    echo "  or save 'tofu output -json bastion_access_keys > keys.json' where it is, and pass: $0 -f keys.json" >&2
    exit 2
  fi
fi

ROWS=0; FOUND=0
emit() { # <account> <public key line>
  local line="$2" info
  info="$(printf '%s\n' "$line" | ssh-keygen -lf - -E sha256 2>/dev/null)" || { [ -n "$FIND" ] || printf '%s\t%s\t%s\t%s\n' "$1" "UNREADABLE" "-" "-"; return; }
  # "256 SHA256:xxxx comment (ED25519)"
  local fp type comment
  fp="$(awk '{ print $2 }' <<<"$info")"; type="$(sed -E 's/.*\(([^)]*)\)$/\1/' <<<"$info")"
  comment="$(sed -E 's/^[^ ]+ [^ ]+ //; s/ \([^)]*\)$//' <<<"$info")"
  ROWS=$((ROWS + 1))
  if [ -n "$FIND" ]; then [ "$fp" = "$FIND" ] || return 0; FOUND=1; fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$fp" "$type" "$comment"
}
while IFS=$'\t' read -r account key; do
  [ -n "$key" ] || continue
  emit "$account" "$key"
done < <(jq -r '(.operators // {} | to_entries[] | .key as $n | .value[] | [$n, .] | @tsv),
                (.shared // {} | to_entries[] | .key as $p | .value[] | ["shared:" + $p, .] | @tsv)' <<<"$JSON")
[ "$ROWS" -gt 0 ] || echo "(no key in the state)" >&2
if [ -n "$FIND" ] && [ "$FOUND" = 0 ]; then echo "no key with fingerprint $FIND (a removed operator, or not a key of this cluster)" >&2; exit 1; fi
