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
# Needs the bastion_baseline: it puts the user in adm and systemd-journal and makes the journal persistent (with or
# without audit_logging, no package needed); auditd, hence the audit tarball, only with bastion_baseline.audit_logging=true.
# Closed egress forces audit_logging=false (variables.tf): such a bastion exports the journal only, and says that the audit
# part was skipped (exit 0). A bastion where the user cannot read the journal (no baseline, or built before the groups moved
# out of audit_logging) is refused with the reason. Without OA_LOGS_PASSPHRASE the files are written in clear (mode 0600) with a warning; with it they are encrypted like
# the access artifacts (gpg symmetric AES-256). Read-only on the bastion.
#
# OA_LOGS_UPLOAD=1 also puts the encrypted files in the artifacts bucket of BOTH object stores (the primary and the
# replica of `tofu output backup_targets`, under backups/bastion-logs/, SSE on top), the way etcd-snapshot.sh does it.
# It refuses to upload anything in clear. The watermark lives there too: the journal cursor is copied to
# backups/bastion-logs/.journal-cursor after a pull has been stored in both, and read back when this directory has none,
# so a pull from another machine resumes where the last one stopped. Per-store markers ($OUT/.uploaded.primary and
# .replica) make a failed upload retry the same files next time instead of skipping or duplicating them.
#   OA_TOFU_DIR              where `tofu output backup_targets` is read (default infrastructure/opentofu/cluster;
#                            needs TF_VAR_encryption_passphrase)
#   OA_BACKUP_TARGETS_JSON   a file holding that output, instead of asking tofu
# Read one back: gpg -d journal-<ts>.export.gpg | systemd-journal-remote -o restored.journal -   then   journalctl --file restored.journal
#                 gpg -d audit-<ts>.tar.gz.gpg | tar -xzf -   then   ausearch -if audit.log
#
# Usage:  bastion-logs-pull.sh <bastion_ip> <bastion_user> <ssh_key> [outdir]      (default outdir: bastion-logs)
#         The host key must already be trusted: the pinned file BASTION_KNOWN_HOSTS (default .talos-bastion-known-hosts,
#         kept by talos-tunnels.sh with OA_BASTION_PIN_HOSTKEY) is used strictly when it holds this bastion, otherwise
#         ssh's own known_hosts. An unknown key is refused, never accepted here.
# ==============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/bastion-hostkey.sh"

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

UPLOAD="${OA_LOGS_UPLOAD:-}"
if [ "$UPLOAD" = 1 ]; then
  # Before the first connection: nothing that would end in a clear-text upload, or a missing tool, may start.
  [ -n "${OA_LOGS_PASSPHRASE:-}" ] || { echo "✗ OA_LOGS_UPLOAD=1 needs OA_LOGS_PASSPHRASE: the logs are never uploaded in clear" >&2; exit 2; }
  for bin in aws jq; do command -v "$bin" >/dev/null 2>&1 || { echo "✗ $bin is required for OA_LOGS_UPLOAD=1" >&2; exit 2; }; done
  if [ -n "${OA_BACKUP_TARGETS_JSON:-}" ]; then
    [ -f "$OA_BACKUP_TARGETS_JSON" ] || { echo "✗ no such file: $OA_BACKUP_TARGETS_JSON" >&2; exit 2; }
    BT="$(cat "$OA_BACKUP_TARGETS_JSON")"
  else
    command -v tofu >/dev/null 2>&1 || { echo "✗ tofu is required for OA_LOGS_UPLOAD=1 (or give OA_BACKUP_TARGETS_JSON)" >&2; exit 2; }
    # tofu's own error is kept: "apply the infra first" is wrong when the infra is applied and this shell just cannot read the backend (#352).
    TOFU_ERR="$(mktemp)"
    BT="$(tofu -chdir="${OA_TOFU_DIR:-infrastructure/opentofu/cluster}" output -json backup_targets 2>"$TOFU_ERR")" || BT=null
  fi
  if ! { [ -n "$BT" ] && [ "$BT" != null ]; }; then
    if [ -n "${TOFU_ERR:-}" ] && [ -s "$TOFU_ERR" ]; then
      echo "✗ tofu could not read the backup_targets output (the infra may well be applied):" >&2
      head -n 5 "$TOFU_ERR" | sed 's/^/    /' >&2
      echo "  Run this from the shell that applied the infra (TF_DATA_DIR and the backend credentials exported), or set OA_TOFU_DIR, or OA_BACKUP_TARGETS_JSON to a saved copy of the output." >&2
    else
      echo "✗ the backup_targets output is empty: apply the infra first, or set OA_TOFU_DIR / OA_BACKUP_TARGETS_JSON" >&2
    fi
    rm -f "${TOFU_ERR:-}"; exit 2
  fi
  rm -f "${TOFU_ERR:-}"
  oa_aws_compat
  PROVIDER="$(jq -r '.provider' <<<"$BT")"
  S3_BUCKET=("$(jq -r '.artifact_bucket_primary' <<<"$BT")" "$(jq -r '.artifact_bucket_replica' <<<"$BT")")
  S3_EP=("$(jq -r '.primary_endpoint' <<<"$BT")" "$(jq -r '.replica_endpoint' <<<"$BT")")
  S3_REGION=("$(jq -r '.primary_region' <<<"$BT")" "$(jq -r '.replica_region' <<<"$BT")")
  S3_AK=("$(s3_cred "$PROVIDER" primary ak)" "$(s3_cred "$PROVIDER" backup ak "${S3_EP[1]}")")
  S3_SK=("$(s3_cred "$PROVIDER" primary sk)" "$(s3_cred "$PROVIDER" backup sk "${S3_EP[1]}")")
fi

umask 077
mkdir -p "$OUT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CURSOR_FILE="$OUT/.journal-cursor"
# A pinned known_hosts that holds this bastion is used strictly; otherwise ssh's own file, where BatchMode refuses an unknown key.
KH="${BASTION_KNOWN_HOSTS:-.talos-bastion-known-hosts}"
KH_OPT=()
oa_bastion_kh_known "$KH" "$IP" && KH_OPT=(-o "UserKnownHostsFile=$KH" -o StrictHostKeyChecking=yes)
SSH=(ssh -i "$KEY" "${KH_OPT[@]}" -o BatchMode=yes -o ConnectTimeout=10 "${USER_}@${IP}")

# --- object store helpers (OA_LOGS_UPLOAD=1) ---------------------------------------------------
PREFIX="backups/bastion-logs"
s3() { # <store 0|1> <aws s3 args…>
  local i="$1"; shift
  AWS_ACCESS_KEY_ID="${S3_AK[$i]}" AWS_SECRET_ACCESS_KEY="${S3_SK[$i]}" aws s3 "$@" --endpoint-url "${S3_EP[$i]}" --region "${S3_REGION[$i]}"
}
upload_pending() { # stores every file of $OUT not yet marked, in both stores; returns 1 if a store failed
  local i name marker rc=0 f
  for i in 0 1; do
    marker="$OUT/.uploaded.$([ "$i" = 0 ] && echo primary || echo replica)"
    touch "$marker"
    for f in "$OUT"/journal-*.gpg "$OUT"/audit-*.gpg; do
      [ -e "$f" ] || continue
      name="$(basename "$f")"
      grep -qxF "$name" "$marker" && continue
      if s3 "$i" cp "$f" "s3://${S3_BUCKET[$i]}/$PREFIX/$name" --sse AES256 >/dev/null; then
        printf '%s\n' "$name" >>"$marker"
        echo "✓ uploaded $name -> s3://${S3_BUCKET[$i]}/$PREFIX/ ($([ "$i" = 0 ] && echo primary || echo replica))"
      else
        echo "✗ upload of $name to the $([ "$i" = 0 ] && echo primary || echo replica) store FAILED: it stays pending for the next run" >&2; rc=1
      fi
    done
  done
  return "$rc"
}

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

# The watermark: this directory's, else (with the bucket) the one the last pull left there, whichever machine it ran on.
if [ "$UPLOAD" = 1 ] && [ ! -s "$CURSOR_FILE" ]; then
  s3 0 cp "s3://${S3_BUCKET[0]}/$PREFIX/.journal-cursor" "$CURSOR_FILE" >/dev/null 2>&1 \
    && echo "~ journal: resuming from the cursor kept in the bucket" || rm -f "$CURSOR_FILE"
fi
# What can this account read? Said up front: a journalctl that is denied looks like an empty journal otherwise.
PRE="$("${SSH[@]}" 'id -nG; id -u; if [ -r /var/log/audit ] && [ -x /var/log/audit ]; then echo audit-yes; else echo audit-no; fi')" \
  || { echo "✗ could not run a command on the bastion (ssh failed)" >&2; exit 2; }
P_GROUPS="$(sed -n 1p <<<"$PRE")"; P_UID="$(sed -n 2p <<<"$PRE")"; P_AUDIT="$(sed -n 3p <<<"$PRE")"
if [ "$P_UID" != 0 ] && ! grep -qwE 'adm|systemd-journal' <<<"$P_GROUPS"; then
  echo "✗ journal: ${USER_} is not in adm or systemd-journal on the bastion (groups: ${P_GROUPS:-none}), so it cannot read the journal." >&2
  echo "  The groups and the persistent journal come with bastion_baseline.enabled (audit_logging is not needed). A bastion without" >&2
  echo "  the baseline, or one built before they moved out of audit_logging, has to be replaced, or the logs pulled as root." >&2
  exit 1
fi
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

if [ "$P_AUDIT" != audit-yes ]; then
  # Not an error: bastion_baseline.audit_logging=false (forced by closed egress) never installs auditd, so there is no archive to take.
  echo "~ audit: skipped, /var/log/audit is absent or unreadable on the bastion (audit_logging=false: auditd is not installed). Only the journal is exported."
else
  "${SSH[@]}" "tar -C /var/log/audit -czf - ." >"$RAW"
  if [ -s "$RAW" ]; then
    store "audit-$STAMP.tar.gz" <"$RAW"
    echo "✓ audit: -> $OUT/audit-$STAMP.tar.gz${OA_LOGS_PASSPHRASE:+.gpg}"
  else
    echo "✗ audit: the bastion returned nothing (is auditd running, is the user in adm?)" >&2
    exit 1
  fi
fi

if [ "$UPLOAD" = 1 ]; then
  # Cursor last, and only when both stores hold everything pulled so far: a watermark ahead of the stored logs would lose them.
  if upload_pending; then
    [ -s "$CURSOR_FILE" ] && for i in 0 1; do s3 "$i" cp "$CURSOR_FILE" "s3://${S3_BUCKET[$i]}/$PREFIX/.journal-cursor" --sse AES256 >/dev/null 2>&1 || echo "⚠ the cursor was not copied to store $i" >&2; done
  else
    echo "✗ not every pulled file reached both stores; the bucket watermark was not moved" >&2; exit 1
  fi
fi
