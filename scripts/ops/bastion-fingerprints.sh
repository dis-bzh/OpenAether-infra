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
  JSON="$(tofu -chdir="${DIR:-infrastructure/opentofu/cluster}" output -json bastion_access_keys 2>/dev/null || echo null)"
fi
[ -n "$JSON" ] && [ "$JSON" != null ] || { echo "✗ no bastion_access_keys output - apply the infra first" >&2; exit 2; }

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
