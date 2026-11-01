#!/usr/bin/env bash
# oa_require_free_gib (scripts/lib/common.sh) and its use by the Talos image build (lab 27 part C, E5): the step needs about 12 GiB
# (raw ~11.3 GiB next to the compressed file); three attempts died on "No space left on device" AFTER the download. `df` is a stub.
# Usage: test-image-disk-preflight.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "${W:?}"' EXIT
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
mkdir -p "$W/bin"
cat >"$W/bin/df" <<'S'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 100000000 0 %s 1%% /\n' "${STUB_FREE_KIB:?}"
S
chmod +x "$W/bin/df"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
run() { out="$(PATH="$W/bin:$PATH" oa_require_free_gib "$W/d" "$@" 2>&1)"; rc=$?; }
GIB=$((1024 * 1024))

STUB_FREE_KIB=$((10 * GIB)); export STUB_FREE_KIB; run 12 "the image build"
{ [ "$rc" = 1 ] && grep -q "needs about 12 GiB" <<<"$out" && grep -q "only ~10 GiB" <<<"$out"; } && ok_ "10 GiB free (the lab's third failure): refused, with both numbers" || bad "10 GiB: rc $rc / $out"
STUB_FREE_KIB=$((13 * GIB)); run 12 "the image build"; [ "$rc" = 0 ] && ok_ "13 GiB free (the size that passed): accepted" || bad "13 GiB: rc $rc / $out"
STUB_FREE_KIB=$((12 * GIB)); run 12 "x"; [ "$rc" = 0 ] && ok_ "exactly 12 GiB: accepted" || bad "12 GiB: rc $rc"
STUB_FREE_KIB=1; run 0 "x"; [ "$rc" = 0 ] && ok_ "a need of 0 switches the check off" || bad "need 0: rc $rc"
STUB_FREE_KIB=""; run 12 "x"; { [ "$rc" = 0 ] && grep -q "not checked" <<<"$out"; } && ok_ "an unreadable df does not block, and says it did not check" || bad "unreadable: rc $rc / $out"
STUB_FREE_KIB=$((13 * GIB)); run twelve "x"; [ "$rc" = 2 ] && ok_ "a need that is not whole GiB is a usage error" || bad "bad need: rc $rc"

# Wiring: asked before any apply of the build, and not in the list/prune/retain modes (they return before the apply paths).
n="$(grep -c 'disk_preflight' "$ROOT/scripts/bootstrap/talos-image.sh")"
[ "$n" = 3 ] && ok_ "talos-image.sh defines it once and calls it before both applies (ensure and interactive)" || bad "talos-image.sh disk_preflight count $n (want 3)"
awk '/^disk_preflight\(\)/ {d=NR} /disk_preflight; tofu apply "\$PLAN"/ {e=NR} /^  disk_preflight$/ {i=NR} /^case "\$MODE" in/ {c=NR} END {exit !(d && c && e > d && i > d)}' \
  "$ROOT/scripts/bootstrap/talos-image.sh" && ok_ "both calls come after the prune/import modes returned" || bad "the preflight sits before a mode that must not be blocked"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
