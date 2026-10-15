#!/usr/bin/env bash
# docs/network.md (and .fr.md) carry the node-inbound rules of each provider as a table GENERATED from the Terraform
# (gen-flow-matrix.sh). This fails when a table differs from the code, when a rule has no justification row, and when the
# generator itself stops understanding the files (a provider whose output has fewer than the rules it is known to hold).
# It also proves the comparison can fail: a mutated copy of a table must be reported.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$ROOT/scripts/dev/gen-flow-matrix.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

block() { # <file> <provider> : the text between the markers, markers excluded
  awk -v b="<!-- flow-matrix:$2:begin -->" -v e="<!-- flow-matrix:$2:end -->" '$0 == b { on = 1; next } $0 == e { on = 0 } on' "$1"
}
why() { # <file> : section 5.3 only
  awk '/^### 5\.3 / { on = 1; next } /^### / { on = 0 } on' "$1"
}

# Floors: fewer rules than these means the generator lost its grip on the file, not that the code shrank.
declare -A MIN=([scw]=12 [ovh]=6 [outscale]=7)

for lang in en fr; do
  if [ "$lang" = en ]; then DOC="$ROOT/docs/network.md"; FLAG=(); else DOC="$ROOT/docs/network.fr.md"; FLAG=(--fr); fi
  echo "=== docs/$(basename "$DOC") ==="
  [ -f "$DOC" ] || { bad "$DOC is missing"; continue; }
  for p in scw ovh outscale; do
    "$GEN" "${FLAG[@]}" "$p" >"$TMP/gen.$p.$lang" 2>"$TMP/err" || { bad "$p: the generator failed: $(cat "$TMP/err")"; continue; }
    block "$DOC" "$p" >"$TMP/doc.$p.$lang"
    if diff -u "$TMP/doc.$p.$lang" "$TMP/gen.$p.$lang" >"$TMP/diff"; then ok "$p: the table is what the code generates"; else bad "$p: the table differs from the code (regenerate it):"; sed 's/^/      /' "$TMP/diff" | head -20; fi
    n=$(grep -c '^| `' "$TMP/gen.$p.$lang" || true)
    [ "$n" -ge "${MIN[$p]}" ] && ok "$p: $n rules read" || bad "$p: only $n rules read, expected at least ${MIN[$p]}"
    why "$DOC" >"$TMP/why.$lang"
    while IFS= read -r name; do
      grep -qF "\`$name\`" "$TMP/why.$lang" || bad "$p: rule \`$name\` has no row in section 5.3"
    done < <(sed -n 's/^| `\([^`]*\)`.*/\1/p' "$TMP/gen.$p.$lang")
  done
done

echo "=== the comparison can fail ==="
sed 's/| 6443 |/| 6444 |/' "$TMP/gen.scw.en" >"$TMP/mutated"
diff -q "$TMP/mutated" "$TMP/gen.scw.en" >/dev/null && bad "a changed port was not noticed" || ok "a changed port makes the tables differ"
# Mutating the Terraform: a rule added to the map must appear in the output.
mkdir -p "$TMP/tree/infrastructure/opentofu/modules/providers"
cp -r "$ROOT/infrastructure/opentofu/modules/providers/scw" "$TMP/tree/infrastructure/opentofu/modules/providers/scw"
sed -i 's|^    dhcp  *= { protocol = "UDP", ports = "68" }|    dhcp             = { protocol = "UDP", ports = "68" }\n    extra-test-rule  = { protocol = "TCP", ports = "9999" }|' "$TMP/tree/infrastructure/opentofu/modules/providers/scw/security.tf"
mutated_out="$("$GEN" scw "$TMP/tree")"
grep -q 'extra-test-rule' <<<"$mutated_out" && ok "a rule added to the Terraform shows up in the generated table" || bad "a rule added to the Terraform was not picked up"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
