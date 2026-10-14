#!/usr/bin/env bash
# ==============================================================================
# bastion-logs-pull.sh — copy the bastion's evidence off the VM (ANSSI PA-012 R9/R14, deferred export)
#
# The bastion is rebuilt from cloud-init, so what it recorded dies with it. Run this from the operator's
# machine, over the same SSH path as everything else (inbound only: the bastion's egress stays closed):
#
#   journal   ssh, sudo and kernel (nft drop) entries since the last pull, journalctl -o export, resumed from a cursor
#   audit     /var/log/audit as a tar.gz (the files are capped small by the baseline)
#
# Needs the bastion_baseline (the user in adm and systemd-journal, auditd, a persistent journal). Without
# OA_LOGS_PASSPHRASE the files are written in clear (mode 0600) with a warning; with it they are encrypted like
# the access artifacts (gpg symmetric AES-256). Uploading to a bucket is NOT done here: copy the files with the
# provider's S3 tooling, or keep them on an encrypted disk. Read-only on the bastion.
#
# Usage:  bastion-logs-pull.sh <bastion_ip> <bastion_user> <ssh_key> [outdir]      (default outdir: bastion-logs)
#         The host key must already be trusted (known_hosts): this does not accept an unknown one.
# ==============================================================================
set -euo pipefail

IP="${1:?Usage: $0 <bastion_ip> <bastion_user> <ssh_key> [outdir]}"
USER_="${2:?}"
KEY="${3:?}"
OUT="${4:-bastion-logs}"

[ -f "$KEY" ] || { echo "✗ no such key file: $KEY" >&2; exit 2; }
if [ -n "${OA_LOGS_PASSPHRASE:-}" ]; then
  command -v gpg >/dev/null 2>&1 || { echo "✗ OA_LOGS_PASSPHRASE is set and gpg is not installed" >&2; exit 2; }
else
  echo "⚠ OA_LOGS_PASSPHRASE is not set: the logs are written in clear (0600). They hold usernames, source addresses and key fingerprints." >&2
fi

umask 077
mkdir -p "$OUT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CURSOR_FILE="$OUT/.journal-cursor"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "${USER_}@${IP}")

# Passphrase through fd 3, never argv; an isolated GnuPG home keeps ~/.gnupg untouched.
store() { # <name> — stdin to $OUT/<name>, encrypted when a passphrase is set
  if [ -n "${OA_LOGS_PASSPHRASE:-}" ]; then
    GPGTMP="$(mktemp -d)"; GNUPGHOME="$GPGTMP" gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 \
      --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 --symmetric --cipher-algo AES256 \
      -o "$OUT/$1.gpg" 3< <(printf '%s' "$OLP")
  else
    cat >"$OUT/$1"
  fi
}
OLP="${OA_LOGS_PASSPHRASE:-}"

AFTER=""
[ -s "$CURSOR_FILE" ] && AFTER="--after-cursor=$(cat "$CURSOR_FILE")"
# The logins (ssh.service), the privilege use (sudo) and the kernel ring (where the nft-drop-in/out lines land).
# `+` is journalctl's OR between match groups; matches on different fields without it would be ANDed.
RAW="$(mktemp)"; trap 'rm -f "$RAW"; [ -z "${GPGTMP:-}" ] || rm -rf "$GPGTMP"' EXIT
"${SSH[@]}" "journalctl --no-pager -o export $AFTER _SYSTEMD_UNIT=ssh.service + SYSLOG_IDENTIFIER=sudo + _TRANSPORT=kernel" >"$RAW"
if [ -s "$RAW" ]; then
  # The last entry's cursor is the next watermark. export format carries it as a __CURSOR= line.
  NEXT="$(grep -a '^__CURSOR=' "$RAW" | tail -1 | cut -d= -f2-)"
  store "journal-$STAMP.export" <"$RAW"
  [ -z "$NEXT" ] || printf '%s' "$NEXT" >"$CURSOR_FILE"
  echo "✓ journal: $(grep -ac '^__CURSOR=' "$RAW") entr(ies) -> $OUT/journal-$STAMP.export${OA_LOGS_PASSPHRASE:+.gpg}"
else
  echo "~ journal: nothing new since the last pull"
fi

"${SSH[@]}" "tar -C /var/log/audit -czf - ." >"$RAW"
if [ -s "$RAW" ]; then
  store "audit-$STAMP.tar.gz" <"$RAW"
  echo "✓ audit: -> $OUT/audit-$STAMP.tar.gz${OA_LOGS_PASSPHRASE:+.gpg}"
else
  echo "✗ audit: the bastion returned nothing (is auditd installed, is the user in adm?)" >&2
  exit 1
fi
