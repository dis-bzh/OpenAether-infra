#!/usr/bin/env bash
# scripts/ops/bastion-logs-pull.sh against a stub ssh: the cursor watermark, the encrypted and clear outputs, and the
# refusals. The stub plays journalctl and tar; nothing connects anywhere. SUT overrides the script (mutants).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/bastion-logs-pull.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The script sources scripts/lib: a SUT override is copied into a tree that has it.
mkdir -p "$TMP/tree/scripts/ops" "$TMP/tree/scripts/lib"
cp "$SUT" "$TMP/tree/scripts/ops/bastion-logs-pull.sh"; cp "$ROOT"/scripts/lib/*.sh "$TMP/tree/scripts/lib/"
SUT="$TMP/tree/scripts/ops/bastion-logs-pull.sh"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${*: -1}"
echo "$cmd" >>"$SSH_LOG"
case "$cmd" in
  "id -nG"*) [ "${STUB_NOGROUPS:-}" = 1 ] && printf 'bastion\n1001\n' || printf 'bastion adm systemd-journal\n1001\n'
             [ "${STUB_AUDITDIR:-yes}" = yes ] && echo audit-yes || echo audit-no ;;
  journalctl*) [ "${STUB_EMPTY:-}" = 1 ] && exit 0
               printf '__CURSOR=s=aaa\nMESSAGE=Accepted publickey for bastion ssh2: ED25519 SHA256:abc\n\n__CURSOR=s=bbb\nMESSAGE=second\n\n' ;;
  tar*) [ "${STUB_NOAUDIT:-}" = 1 ] && exit 0; printf 'FAKE-TARBALL' ;;
esac
STUB
chmod +x "$TMP/bin/ssh"
export SSH_LOG="$TMP/ssh.log"
touch "$TMP/key"
run() { OUT="$(env PATH="$TMP/bin:$PATH" "$@" bash "$SUT" 192.0.2.10 bastion "$TMP/key" "$TMP/out" 2>&1)"; RC=$?; }

echo "=== clear output ==="
run STUB_X=1
[ "$RC" = 0 ] && ls "$TMP"/out/journal-*.export >/dev/null 2>&1 && ls "$TMP"/out/audit-*.tar.gz >/dev/null 2>&1 && ok "a journal export and an audit tarball are written" || bad "first pull: rc=$RC $OUT"
grep -q '^⚠ OA_LOGS_PASSPHRASE is not set' <<<"$OUT" && ok "writing in clear is warned about" || bad "no warning for clear output"
[ "$(cat "$TMP/out/.journal-cursor")" = "s=bbb" ] && ok "the watermark is the LAST entry's cursor" || bad "cursor: $(cat "$TMP/out/.journal-cursor" 2>/dev/null)"
[ "$(stat -c %a "$TMP"/out/journal-*.export | head -1)" = 600 ] && ok "files are 0600" || bad "mode: $(stat -c %a "$TMP"/out/journal-*.export)"
grep -q 'journalctl.*_SYSTEMD_UNIT=ssh.service + SYSLOG_IDENTIFIER=sudo + _TRANSPORT=kernel' "$SSH_LOG" && ! grep -q -- '--after-cursor' "$SSH_LOG" \
  && ok "the first pull asks for everything, with OR'd match groups" || bad "first journalctl: $(head -1 "$SSH_LOG")"
: >"$SSH_LOG"; sleep 1; run STUB_X=1
grep -q -- '--after-cursor=s=bbb' "$SSH_LOG" && ok "the second pull resumes after the stored cursor" || bad "second pull did not resume: $(cat "$SSH_LOG")"

echo "=== nothing new, nothing audited ==="
run STUB_EMPTY=1
grep -q 'nothing new' <<<"$OUT" && [ "$(cat "$TMP/out/.journal-cursor")" = "s=bbb" ] && ok "an empty journal answer keeps the watermark" || bad "empty journal: $OUT"
run STUB_NOAUDIT=1
[ "$RC" = 1 ] && grep -q 'audit: the bastion returned nothing' <<<"$OUT" && ok "an empty audit answer FAILS (auditd absent or user not in adm)" || bad "no audit: rc=$RC $OUT"

echo "=== audit_logging=false: a journal-only bastion (closed egress forces it) ==="
# Lab 11: the audit tarball was unconditional (tar: /var/log/audit: Cannot open, rc 2, nothing written) and the journal was unreadable.
rm -rf "$TMP/out"; : >"$SSH_LOG"
run STUB_AUDITDIR=no
[ "$RC" = 0 ] && ls "$TMP"/out/journal-*.export >/dev/null 2>&1 && ! ls "$TMP"/out/audit-* >/dev/null 2>&1 && grep -q 'audit: skipped' <<<"$OUT" && ! grep -q '^tar ' "$SSH_LOG" \
  && ok "without /var/log/audit the journal is exported, the audit part is skipped with a message, rc 0, no tar is run" || bad "journal-only pull: rc=$RC $OUT"
rm -rf "$TMP/out"
run STUB_AUDITDIR=no STUB_EMPTY=1
[ "$RC" = 0 ] && grep -q 'nothing new' <<<"$OUT" && grep -q 'audit: skipped' <<<"$OUT" && ok "nothing to pull on a journal-only bastion ends rc 0 with both reasons said" || bad "empty journal-only pull: rc=$RC $OUT"
rm -rf "$TMP/out"
run STUB_NOGROUPS=1
[ "$RC" = 1 ] && grep -q 'not in adm or systemd-journal' <<<"$OUT" && ! ls "$TMP"/out/journal-* >/dev/null 2>&1 && ok "an account that cannot read the journal is refused with the reason, not read as an empty journal" || bad "no groups: rc=$RC $OUT"

echo "=== encrypted ==="
rm -rf "$TMP/out"
run OA_LOGS_PASSPHRASE="a-passphrase-of-more-than-32-characters-x"
if command -v gpg >/dev/null 2>&1; then
  F="$(ls "$TMP"/out/audit-*.gpg 2>/dev/null)"
  [ "$RC" = 0 ] && [ -n "$F" ] && ! ls "$TMP"/out/audit-*.tar.gz >/dev/null 2>&1 && ok "with a passphrase only .gpg files exist" || bad "encrypted pull: rc=$RC $OUT"
  GOT="$(GNUPGHOME="$(mktemp -d)" gpg --batch --quiet --pinentry-mode loopback --passphrase 'a-passphrase-of-more-than-32-characters-x' -d "$F" 2>/dev/null)"
  [ "$GOT" = FAKE-TARBALL ] && ok "…and they decrypt with that passphrase" || bad "decrypted: '$GOT'"
  ! grep -q '⚠' <<<"$OUT" && ok "no clear-text warning when encrypting" || bad "warned although encrypting"
else echo "  ~ gpg is not installed: encryption not checked"; fi

echo "=== refusals ==="
OUT="$(env PATH="$TMP/bin:$PATH" bash "$SUT" 192.0.2.10 bastion "$TMP/nokey" "$TMP/out2" 2>&1)"; RC=$?
[ "$RC" = 2 ] && ok "a missing key file is refused before any connection" || bad "missing key: rc=$RC"

echo "=== upload to both object stores, with the watermark (OA_LOGS_UPLOAD=1) ==="
# A stub aws: `s3 cp` between a file and s3://bucket/key, one directory per endpoint. It logs the access key it was
# given and fails on request for one endpoint, to play a store that is down.
cat >"$TMP/bin/aws" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "s3 cp" ] || exit 2
src="$3"; dst="$4"; ep=""; sse=""
for ((i = 1; i <= $#; i++)); do
  [ "${!i}" = --endpoint-url ] && { j=$((i + 1)); ep="${!j}"; }
  [ "${!i}" = --sse ] && sse=1
done
dir="$S3DIR/$(printf '%s' "$ep" | tr -c 'a-zA-Z0-9\n' _)"
echo "ak=$AWS_ACCESS_KEY_ID ep=$ep $src -> $dst sse=${sse:-0}" >>"$AWS_LOG"
if [[ "$dst" == s3://* ]]; then
  [ "${STUB_AWS_FAIL_EP:-}" = "$ep" ] && exit 1
  mkdir -p "$dir/$(dirname "${dst#s3://}")"; cp "$src" "$dir/${dst#s3://}"
else
  [ -f "$dir/${src#s3://}" ] || exit 1
  cp "$dir/${src#s3://}" "$dst"
fi
STUB
chmod +x "$TMP/bin/aws"
cat >"$TMP/targets.json" <<'JSON'
{"provider":"scaleway","artifact_bucket_primary":"bk-primary","artifact_bucket_replica":"bk-replica",
 "primary_endpoint":"https://primary.example","primary_region":"fr-par","replica_endpoint":"https://replica.example","replica_region":"nl-ams"}
JSON
export S3DIR="$TMP/s3" AWS_LOG="$TMP/aws.log"
PP="a-passphrase-of-more-than-32-characters-x"
PRIM="$S3DIR/https___primary_example/bk-primary/backups/bastion-logs"; REPL="$S3DIR/https___replica_example/bk-replica/backups/bastion-logs"
ngpg() { find "$1" -maxdepth 1 -name '*.gpg' 2>/dev/null | wc -l; }
upl() { OUT="$(env PATH="$TMP/bin:$PATH" STUB_X=1 OA_LOGS_UPLOAD=1 OA_LOGS_PASSPHRASE="$PP" OA_BACKUP_TARGETS_JSON="$TMP/targets.json" \
  SCW_AWS_ACCESS_KEY_ID=ak-primary SCW_AWS_SECRET_ACCESS_KEY=sk-primary SCW_BACKUP_AWS_ACCESS_KEY_ID=ak-replica SCW_BACKUP_AWS_SECRET_ACCESS_KEY=sk-replica \
  "$@" bash "$SUT" 192.0.2.10 bastion "$TMP/key" "$TMP/up" 2>&1)"; RC=$?; }

: >"$SSH_LOG"
OUT="$(env PATH="$TMP/bin:$PATH" OA_LOGS_UPLOAD=1 OA_BACKUP_TARGETS_JSON="$TMP/targets.json" bash "$SUT" 192.0.2.10 bastion "$TMP/key" "$TMP/up" 2>&1)"; RC=$?
[ "$RC" = 2 ] && grep -q 'never uploaded in clear' <<<"$OUT" && [ ! -s "$SSH_LOG" ] && [ ! -d "$S3DIR" ] \
  && ok "an upload without a passphrase is refused before any connection and nothing leaves" || bad "clear upload: rc=$RC $OUT"

upl; N1="$(ngpg "$PRIM")"
if [ "$RC" = 0 ] && [ "$N1" = 2 ] && [ "$(ngpg "$REPL")" = 2 ] && [ "$(cat "$PRIM/.journal-cursor")" = "s=bbb" ] && [ "$(cat "$REPL/.journal-cursor")" = "s=bbb" ]; then
  ok "one pull puts the journal and the audit archive, encrypted, plus the cursor, in BOTH stores"
else bad "upload: rc=$RC primary=$(ls "$PRIM" 2>&1 | tr '\n' ' ') replica=$(ls "$REPL" 2>&1 | tr '\n' ' ') $OUT"; fi
grep -q 'ak=ak-primary ep=https://primary.example' "$AWS_LOG" && grep -q 'ak=ak-replica ep=https://replica.example' "$AWS_LOG" && ! grep -q -- '-> s3://.* sse=0' "$AWS_LOG" \
  && ok "each store gets its own credential, and every put asks for server-side encryption" || bad "credentials/sse: $(cat "$AWS_LOG")"
[ -z "$(find "$PRIM" "$REPL" -maxdepth 1 \( -name '*.export' -o -name '*.tar.gz' \))" ] && ok "nothing in clear reached a bucket" || bad "a clear file was uploaded"

# Pending files only: a second pull stores its OWN files and re-sends nothing.
: >"$AWS_LOG"; sleep 1; upl
PUTS="$(grep -c -- '-> s3://.*\.gpg' "$AWS_LOG")"
[ "$RC" = 0 ] && [ "$PUTS" = 4 ] && [ "$(ngpg "$PRIM")" = 4 ] && ok "a second pull uploads its two new files to each store and none of the first pull's" || bad "second pull: puts=$PUTS $(cat "$AWS_LOG")"

# A store that is down: the run fails, the other store has everything, the bucket watermark does not move, and the next
# run retries only what is missing where it is missing.
printf 's=old' >"$PRIM/.journal-cursor"; printf 's=old' >"$REPL/.journal-cursor"
: >"$AWS_LOG"; sleep 1; upl STUB_AWS_FAIL_EP=https://replica.example
[ "$RC" = 1 ] && grep -q 'FAILED: it stays pending' <<<"$OUT" && [ "$(ngpg "$PRIM")" = 6 ] && [ "$(ngpg "$REPL")" = 4 ] \
  && [ "$(cat "$PRIM/.journal-cursor")" = "s=old" ] && [ "$(cat "$REPL/.journal-cursor")" = "s=old" ] \
  && ok "replica down: exit 1, the primary holds the new files, neither bucket cursor moved" || bad "replica down: rc=$RC primary=$(ngpg "$PRIM") replica=$(ngpg "$REPL") $OUT"
: >"$AWS_LOG"; sleep 1; upl
if [ "$RC" = 0 ] && [ "$(ngpg "$REPL")" = 8 ] && [ "$(ngpg "$PRIM")" = 8 ] \
   && [ "$(grep -c 'ep=https://replica.example .*-> s3://.*\.gpg' "$AWS_LOG")" = 4 ] && [ "$(grep -c 'ep=https://primary.example .*-> s3://.*\.gpg' "$AWS_LOG")" = 2 ] && [ "$(cat "$REPL/.journal-cursor")" = "s=bbb" ]; then
  ok "the next run sends the replica its 2 missed files and this pull's 2 (the primary only this pull's 2), then moves the cursor"
else bad "retry: rc=$RC replica=$(ngpg "$REPL") primary=$(ngpg "$PRIM") puts: $(grep -c -- '-> s3://.*\.gpg' "$AWS_LOG") $OUT"; fi

# The watermark is in the bucket: a directory with no cursor resumes from it.
rm -rf "$TMP/up"; : >"$SSH_LOG"; printf 's=zzz' >"$PRIM/.journal-cursor"; upl
grep -q -- '--after-cursor=s=zzz' "$SSH_LOG" && grep -q 'resuming from the cursor kept in the bucket' <<<"$OUT" \
  && ok "a fresh directory resumes from the cursor kept in the bucket" || bad "no resume from the bucket cursor: $(head -1 "$SSH_LOG") $OUT"

echo "=== host key ==="
mkdir -p "$TMP/kh"; ssh-keygen -q -t ed25519 -N '' -f "$TMP/kh/hostkey"
printf '192.0.2.10 %s\n' "$(cut -d' ' -f1,2 "$TMP/kh/hostkey.pub")" >"$TMP/kh/known"
# The stub only records its argv here: what the script passes ssh for the host key is the subject.
printf '#!/usr/bin/env bash\necho "$*" >>"$SSH_ARGV"\n' >"$TMP/bin/ssh"
OUT="$(env PATH="$TMP/bin:$PATH" SSH_ARGV="$TMP/argv" BASTION_KNOWN_HOSTS="$TMP/kh/known" bash "$SUT" 192.0.2.10 bastion "$TMP/key" "$TMP/hk" 2>&1)"
grep -q "UserKnownHostsFile=$TMP/kh/known" "$TMP/argv" && grep -q 'StrictHostKeyChecking=yes' "$TMP/argv" && ok "a pinned known_hosts that holds the bastion is used, strictly" || bad "pinned file not used: $(head -1 "$TMP/argv" 2>/dev/null)"
: >"$TMP/argv"
OUT="$(env PATH="$TMP/bin:$PATH" SSH_ARGV="$TMP/argv" BASTION_KNOWN_HOSTS="$TMP/kh/none" bash "$SUT" 192.0.2.10 bastion "$TMP/key" "$TMP/hk2" 2>&1)"
! grep -q 'StrictHostKeyChecking' "$TMP/argv" && ! grep -q 'accept' "$TMP/argv" && ok "without a pinned entry ssh's own checking applies: an unknown key is never accepted here" || bad "unexpected host-key options: $(head -1 "$TMP/argv")"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
