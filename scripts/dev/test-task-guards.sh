#!/usr/bin/env bash
# The guards written into Taskfile.yml itself (#191): `fmt` and `lint` over the
# OpenTofu file list, and the check that `test-scripts` leaves envs/ untouched.
# They are inline shell, so the only way to test them is to run the REAL
# Taskfile.yml under go-task in a throwaway repository, with a stub `tofu` that
# records what it was asked to format and every script of test-scripts stubbed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

repo="$TMP/repo"
mkdir -p "$repo/scripts/dev" "$TMP/bin"
cp "$ROOT/Taskfile.yml" "$ROOT/.gitignore" "$ROOT/.pre-commit-config.yaml" "$repo/"
cp "$ROOT/scripts/dev/rung-receipt.py" "$ROOT/scripts/dev/feint.sh" "$ROOT/scripts/dev/ssh-ca-check.sh" "$repo/scripts/dev/"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

cat >"$TMP/bin/tofu" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TOFU_LOG"
EOF
chmod +x "$TMP/bin/tofu"
export TOFU_LOG="$TMP/tofu.log"

# The roots come out of the Taskfile, so a root added there is covered here.
roots="$(awk '/^  TF_ROOTS:/ {on=1; next} on && /^    [a-z]/ {print $1; next} {on=0}' "$ROOT/Taskfile.yml")"
[ -n "$roots" ] && ok "TF_ROOTS read from the Taskfile ($(wc -w <<<"$roots") roots)" || bad "no TF_ROOTS found in the Taskfile"

fixture() { # rebuild the repository: one tracked main.tf per root, and what the guards must skip
  rm -rf "$repo/.git" "$repo/infrastructure"
  mkdir -p "$repo/infrastructure/opentofu/cluster/envs"
  for r in $roots; do mkdir -p "$repo/$r"; printf 'variable "x" {}\n' >"$repo/$r/main.tf"; done
  printf 'gone\n' >"$repo/infrastructure/opentofu/cluster/gone.tf"
  : >"$repo/infrastructure/opentofu/cluster/envs/.gitkeep"
  g init -q && g add -A && g commit -q -m fixture
  rm "$repo/infrastructure/opentofu/cluster/gone.tf"                 # tracked, deleted: fmt cannot open it
  printf 'x = 1\n' >"$repo/infrastructure/opentofu/cluster/envs/real.tfvars"   # the operator's, gitignored
  printf 'variable "y" {}\n' >"$repo/infrastructure/opentofu/cluster/new.tf"   # untracked, not ignored
}
t() { : >"$TOFU_LOG"; PATH="$TMP/bin:$PATH" task --dir "$repo" "$@" >"$TMP/out" 2>&1; }
logged() { cat "$TOFU_LOG"; }

echo "=== fmt and lint hand tofu the right files ==="
fixture
t fmt; rc=$?
files="$(logged)"
[ "$rc" -eq 0 ] && ok "fmt succeeds (rc=$rc)" || bad "fmt failed: $(cat "$TMP/out")"
missing=""
for r in $roots; do grep -qF "$r/main.tf" <<<"$files" || missing="$missing $r"; done
[ -z "$missing" ] && ok "…and names every root's tracked file" || bad "fmt skipped the roots:$missing — got: $files"
grep -qF cluster/new.tf <<<"$files" && ok "…and an untracked file that is not ignored" || bad "new.tf not formatted: $files"
grep -qE 'real\.tfvars|gone\.tf' <<<"$files" && bad "fmt was handed a gitignored or deleted file: $files" \
  || ok "…but neither a gitignored envs/*.tfvars nor a deleted file"
t lint; grep -qF -e '-check' "$TOFU_LOG" && ok "lint runs tofu fmt -check over the same list" || bad "lint never reached tofu fmt -check: $(cat "$TMP/out")"

echo "=== a bad file list stops fmt and lint before tofu ==="
last="$(tail -n1 <<<"$roots")"
mv "$repo/$last" "$TMP/moved"
for target in fmt lint; do
  t "$target"; rc=$?
  [ "$rc" -ne 0 ] && grep -q "TF_ROOTS: no directory $last" "$TMP/out" && [ ! -s "$TOFU_LOG" ] \
    && ok "$target: a root that is gone fails, and says which" || bad "$target, missing root (rc=$rc, tofu got: $(logged)): $(cat "$TMP/out")"
done
mv "$TMP/moved" "$repo/$last"

fixture
for r in $roots; do g rm -q -f "$r/main.tf"; done
rm -f "$repo/infrastructure/opentofu/cluster/new.tf"
for target in fmt lint; do
  t "$target"; rc=$?
  [ "$rc" -ne 0 ] && grep -q 'no OpenTofu file under TF_ROOTS' "$TMP/out" && [ ! -s "$TOFU_LOG" ] \
    && ok "$target: an empty list fails instead of formatting nothing (or the current directory)" \
    || bad "$target, empty list (rc=$rc, tofu got: $(logged)): $(cat "$TMP/out")"
done

echo "=== lint compares terraform_fmt's hook with TF_FMT_RE ==="
fixture
sed -i '/- id: terraform_fmt$/,/- id:/s/^\( *files: \).*/\1\\.tf$/' "$repo/.pre-commit-config.yaml"
t lint; rc=$?
[ "$rc" -ne 0 ] && grep -q "terraform_fmt's files:" "$TMP/out" && ! grep -qF -e '-check' "$TOFU_LOG" \
  && ok "a hook whose files: drifted from TF_FMT_RE fails lint before fmt -check" \
  || bad "drifted hook (rc=$rc, tofu got: $(logged)): $(cat "$TMP/out")"

echo "=== test-scripts fails on anything written under envs/ ==="
fixture
cp "$ROOT/.pre-commit-config.yaml" "$repo/"
PATH="$TMP/bin:$PATH" task --dir "$repo" --dry test-scripts >"$TMP/dry" 2>&1
stubs="$(grep -o '\./scripts/dev/[A-Za-z0-9._-]*\.sh' "$TMP/dry" | sort -u)"
[ "$(wc -l <<<"$stubs")" -gt 10 ] && ok "$(wc -l <<<"$stubs") scripts of test-scripts stubbed" || bad "too few scripts in the dry run: $(cat "$TMP/dry")"
last_script="$(grep -o '\./scripts/dev/[A-Za-z0-9._-]*\.sh' "$TMP/dry" | tail -n1)"
for s in $stubs; do
  printf '#!/usr/bin/env bash\n%s\nexit 0\n' '[ "$(basename "$0")" != "$WRITER" ] || eval "$WRITE"' >"$repo/$s"
  chmod +x "$repo/$s"
done
g add -A && g commit -q -m stubs
envs="infrastructure/opentofu/cluster/envs"
ts() { PATH="$TMP/bin:$PATH" WRITER="$(basename "$last_script")" WRITE="$1" task --dir "$repo" test-scripts >"$TMP/out" 2>&1; }
ts true; rc=$?
[ "$rc" -eq 0 ] && ok "no step writes under envs/: test-scripts passes (rc=$rc)" || bad "clean run failed (rc=$rc): $(tail -5 "$TMP/out")"
ts "printf x >$envs/leftover.tmp"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'a step wrote under envs/' "$TMP/out" && ok "a file left under envs/ fails it" \
  || bad "a file left behind (rc=$rc): $(tail -5 "$TMP/out")"
rm -f "$repo/$envs/leftover.tmp"
ts "printf x >$envs/scratch.tmp; rm $envs/scratch.tmp"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'a step wrote under envs/' "$TMP/out" && ok "…and so does one written and deleted again" \
  || bad "a file written then deleted (rc=$rc): $(tail -5 "$TMP/out")"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
