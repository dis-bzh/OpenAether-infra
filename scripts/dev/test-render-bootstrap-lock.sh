#!/usr/bin/env bash
# render-bootstrap-manifests.sh: upstream-artifacts.lock must hash the flux-install.yaml the SAME run wrote. Stub
# helm and curl stand for the network; each case runs the real script. SUT overrides it, which is how the mutant runs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${SUT:-$ROOT/scripts/bootstrap/render-bootstrap-manifests.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/helm" <<'STUB'
#!/usr/bin/env bash
case "$1" in version) echo v4.0.0 ;; template) echo "rendered by the stub"; echo "$*" >>"${HELM_ARGS_LOG:-/dev/null}" ;; esac
exit 0
STUB
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
head -c 1500 /dev/zero | tr '\0' 'N'; echo "# the NEW upstream install.yaml"
STUB
chmod +x "$TMP/bin/helm" "$TMP/bin/curl"
run() { # <dir> [env...]
  local d="$1"; shift
  mkdir -p "$d"; printf 'the OLD vendored install.yaml\n' >"$d/flux-install.yaml"
  env OPENAETHER_MANIFESTS_DIR="$d" PATH="$TMP/bin:$PATH" "$@" "$SUT" >"$TMP/out" 2>&1; RC=$?
}
lockhash() { awk '$2=="flux-install.yaml"{print $1}' "$1/upstream-artifacts.lock"; }
filehash() { sha256sum "$1/flux-install.yaml" | cut -d' ' -f1; }

echo "=== a refresh (OPENAETHER_REFRESH_FLUX=1) ==="
run "$TMP/a" OPENAETHER_REFRESH_FLUX=1
[ "$RC" = 0 ] && grep -q 'NEW upstream' "$TMP/a/flux-install.yaml" && ok "the vendored file is the downloaded one" || bad "refresh did not replace flux-install.yaml (rc=$RC)"
[ -n "$(lockhash "$TMP/a")" ] && [ "$(lockhash "$TMP/a")" = "$(filehash "$TMP/a")" ] \
  && ok "the lock holds the hash of that file, from one run" || bad "the lock records $(lockhash "$TMP/a"), the file is $(filehash "$TMP/a")"
(cd "$TMP/a" && sha256sum -c upstream-artifacts.lock >/dev/null 2>&1) && ok "…so check-upstream-artifacts-lock would pass" || bad "sha256sum -c fails on the lock"

echo "=== no refresh ==="
run "$TMP/b"
[ "$RC" = 0 ] && grep -q 'OLD vendored' "$TMP/b/flux-install.yaml" && ok "the vendored file is left alone" || bad "a plain render touched flux-install.yaml (rc=$RC)"
[ "$(lockhash "$TMP/b")" = "$(filehash "$TMP/b")" ] && ok "the lock matches it" || bad "the lock does not match the untouched file"

echo "=== --hubble-drops (opt-in variant) ==="
: >"$TMP/args-default"; run "$TMP/c" HELM_ARGS_LOG="$TMP/args-default"
grep -q 'hubble.enabled=false' "$TMP/args-default" && ! grep -q 'hubble.export' "$TMP/args-default" \
  && ok "the default render keeps Hubble off and exports nothing" || bad "the default render changed its Hubble flags"
: >"$TMP/args-hubble"
mkdir -p "$TMP/d"; printf 'x\n' >"$TMP/d/flux-install.yaml"; printf 'the committed default\n' >"$TMP/d/cilium.yaml"
env OPENAETHER_MANIFESTS_DIR="$TMP/d" PATH="$TMP/bin:$PATH" HELM_ARGS_LOG="$TMP/args-hubble" "$SUT" --hubble-drops >"$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$TMP/d/cilium-hubble-drops.yaml" ] && ok "--hubble-drops writes cilium-hubble-drops.yaml" || bad "--hubble-drops wrote no variant (rc=$rc)"
grep -q 'hubble.relay.enabled=false' "$TMP/args-hubble" && grep -q 'hubble.tls.enabled=false' "$TMP/args-hubble" \
  && grep -q 'hubble.listenAddress=' "$TMP/args-hubble" && grep -q 'hubble.export.static.filePath=stdout' "$TMP/args-hubble" \
  && grep -q 'DROPPED' "$TMP/args-hubble" && ! grep -q 'FORWARDED' "$TMP/args-hubble" \
  && ok "the variant is the server only, stdout, dropped/errored flows only" || bad "the variant's Hubble flags are wrong: $(cat "$TMP/args-hubble")"
grep -q 'cilium-hubble-drops.yaml' "$TMP/d/upstream-artifacts.lock" && ok "the variant is in the lock" || bad "the variant is not locked"
grep -q 'the committed default' "$TMP/d/cilium.yaml" && ok "…and leaves the default cilium.yaml alone" || bad "the variant render overwrote cilium.yaml"
[ -f "$TMP/c/cilium-hubble-drops.yaml" ] && bad "a plain render wrote the variant" || ok "a plain render does not write the variant"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
