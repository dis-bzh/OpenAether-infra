#!/usr/bin/env bash
# scripts/ops/kubeconfig-new.sh with a stub kubectl and the real openssl: the request it files (subject, group, signer,
# expirationSeconds), the argument limits, the file it writes (0600, outside the repository, the private key never in the
# request) and the refusals (a signer that over-grants, an unsigned request). SUT overrides the script under test (mutants).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/ops/kubeconfig-new.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# The script locates the repository from its own path: run a copy placed in a fake checkout.
FAKE="$TMP/repo"; mkdir -p "$FAKE/scripts/ops" "$FAKE/scripts/lib"; cp "$SUT" "$FAKE/scripts/ops/kubeconfig-new.sh"; SUT="$FAKE/scripts/ops/kubeconfig-new.sh"

# A throwaway CA that plays the controller-manager's signer.
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/ca.key" 2>/dev/null
openssl req -x509 -new -key "$TMP/ca.key" -subj "/CN=fixture-ca" -days 2 -out "$TMP/ca.crt" 2>/dev/null

mkdir -p "$TMP/bin"
cat >"$TMP/bin/kubectl" <<STUB
#!/usr/bin/env bash
echo "kubectl \$*" >>"$TMP/calls.log"
case "\$1 \$2" in
  "config view") printf '{"clusters":[{"name":"fixture","cluster":{"server":"https://127.0.0.1:6443","certificate-authority-data":"%s"}}]}' "\$CA_DATA" ;;
  "create -f")   cat >"$TMP/csr.yaml" ;;
  "certificate approve") [ "\${STUB_NOAPPROVE:-}" = 1 ] && exit 1; exit 0 ;;
  "wait --for=jsonpath={.status.certificate}") [ "\${STUB_UNSIGNED:-}" = 1 ] && exit 1; exit 0 ;;
  "get csr")
    sed -n 's/^  request: //p' "$TMP/csr.yaml" | base64 -d >"$TMP/req.csr"
    secs="\${STUB_SECS:-\$(sed -n 's/^  expirationSeconds: //p' "$TMP/csr.yaml")}"
    openssl x509 -req -in "$TMP/req.csr" -CA "$TMP/ca.crt" -CAkey "$TMP/ca.key" -CAcreateserial -not_after "\$(date -u -d "+\${secs}sec" +%Y%m%d%H%M%SZ)" -out "$TMP/crt.pem" 2>/dev/null
    base64 -w0 <"$TMP/crt.pem" ;;
  "delete csr") exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"
CAB64="$(base64 -w0 <"$TMP/ca.crt")"
mkdir -p "$TMP/tmpd"
run() { : >"$TMP/calls.log"; OUT="$(TMPDIR="$TMP/tmpd" PATH="$TMP/bin:$PATH" HOME="$TMP/home" CA_DATA="$CAB64" bash "$SUT" "$@" 2>&1)"; RC=$?; }

echo "=== defaults: a reader, 8 hours ==="
run alice --out "$TMP/home/a.kubeconfig"
[ "$RC" = 0 ] && ok "a certificate is issued" || bad "default run: rc=$RC $OUT"
grep -q 'expirationSeconds: 28800' "$TMP/csr.yaml" && grep -q 'signerName: kubernetes.io/kube-apiserver-client' "$TMP/csr.yaml" \
  && ok "the request carries expirationSeconds 28800 and the client signer" || bad "request: $(cat "$TMP/csr.yaml")"
S="$(openssl req -in "$TMP/req.csr" -noout -subject)"
[[ "$S" == *"O=oa:readers"* && "$S" == *"CN=alice"* ]] && ok "subject CN=alice, O=oa:readers (the default is the read-only group)" || bad "subject: $S"
grep -q 'kubectl delete csr' "$TMP/calls.log" && ok "the request is deleted afterwards" || bad "CSR left behind"
[ "$(stat -c %a "$TMP/home/a.kubeconfig")" = 600 ] && ok "the kubeconfig is 0600" || bad "mode $(stat -c %a "$TMP/home/a.kubeconfig")"
grep -q 'client-key-data' "$TMP/home/a.kubeconfig" && grep -q 'server: https://127.0.0.1:6443' "$TMP/home/a.kubeconfig" \
  && ok "it embeds the key, the server and the CA of the admin kubeconfig" || bad "kubeconfig content"
[ -z "$(ls -A "$TMP/tmpd")" ] && ok "the temporary directory holding the private key is removed" || bad "temp dir left: $(ls "$TMP/tmpd")"
grep -q 'PRIVATE KEY' "$TMP/csr.yaml" && bad "private key in the request" || ok "the private key is not in the request"

echo "=== admin is explicit ==="
run bob --role admin --ttl 90m --out "$TMP/home/b.kubeconfig"
S="$(openssl req -in "$TMP/req.csr" -noout -subject)"
[ "$RC" = 0 ] && [[ "$S" == *"O=oa:admins"* ]] && grep -q 'expirationSeconds: 5400' "$TMP/csr.yaml" \
  && ok "--role admin gives O=oa:admins; --ttl 90m is 5400 s" || bad "admin: rc=$RC $S $OUT"

echo "=== refusals ==="
run alice --ttl 5m --out "$TMP/home/x"; [ "$RC" = 2 ] && ok "a ttl under 10m is refused" || bad "5m: rc=$RC"
run alice --ttl 25h --out "$TMP/home/x"; [ "$RC" = 2 ] && ok "a ttl over 24h is refused" || bad "25h: rc=$RC"
run alice --ttl forever --out "$TMP/home/x"; [ "$RC" = 2 ] && ok "a malformed ttl is refused" || bad "forever: rc=$RC"
run "system:masters" --out "$TMP/home/x"; [ "$RC" = 2 ] && ok "a name with a system: prefix is refused" || bad "system name: rc=$RC"
run alice --role root --out "$TMP/home/x"; [ "$RC" = 2 ] && ok "an unknown role is refused" || bad "role root: rc=$RC"
run alice --out "$FAKE/kubeconfig.alice"; [ "$RC" = 2 ] && [ ! -e "$FAKE/kubeconfig.alice" ] && ok "an output inside the repository is refused" || bad "in-repo out: rc=$RC"
STUB_SECS=2592000 run alice --out "$TMP/home/c.kubeconfig"
[ "$RC" = 1 ] && [ ! -e "$TMP/home/c.kubeconfig" ] && ok "a signer that grants 30 days for an 8h request is refused, nothing written" || bad "over-grant: rc=$RC $OUT"
STUB_UNSIGNED=1 run alice --out "$TMP/home/d.kubeconfig"
[ "$RC" = 1 ] && grep -q 'kubectl delete csr' "$TMP/calls.log" && [ ! -e "$TMP/home/d.kubeconfig" ] && ok "an unsigned request fails, is cleaned up, writes nothing" || bad "unsigned: rc=$RC"
CA_DATA="" ; OUT="$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" CA_DATA="" bash "$SUT" alice --out "$TMP/home/e" 2>&1)"; RC=$?
[ "$RC" = 1 ] && ok "an admin kubeconfig without an embedded CA is refused" || bad "no CA: rc=$RC"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
