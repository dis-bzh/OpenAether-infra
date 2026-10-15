#!/usr/bin/env bash
# scripts/ops/bastion-logs-pull.sh against a stub ssh: the cursor watermark, the encrypted and clear outputs, and the
# refusals. The stub plays journalctl and tar; nothing connects anywhere. SUT overrides the script (mutants).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/bastion-logs-pull.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${*: -1}"
echo "$cmd" >>"$SSH_LOG"
case "$cmd" in
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

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
