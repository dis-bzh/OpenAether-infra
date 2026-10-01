#!/usr/bin/env bash
# The guards written into Taskfile.yml itself (#191): `fmt` and `lint` over the
# OpenTofu file list, the check that `test-scripts` leaves envs/ untouched, and
# `infra-down-plan`'s fallback when the refresh fails (#69). They are inline
# shell, so the only way to test them is to run the REAL Taskfile.yml under
# go-task in a throwaway repository: with a stub `tofu` that records what it was
# asked to format and every script of test-scripts stubbed, or, for the destroy
# plan, with the real tofu on a root made of builtin providers.
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

echo "=== infra-down-plan plans a destroy although the image the tfvars pin is gone ==="
# The provider modules' image lookups are read on a destroy plan too: a data source
# that errors (scaleway, ovh) or a coalesce over an empty answer (outscale). The root
# below stands in for them with builtin providers, so the real tofu fails the real way.
real_tofu="$(command -v tofu || true)"
[ -n "${TOFU_CLI_PATH:-}" ] && [ -x "$TOFU_CLI_PATH/tofu-bin" ] && real_tofu="$TOFU_CLI_PATH/tofu-bin"  # CI's wrapper
if [ -z "$real_tofu" ]; then
  bad "tofu is not on PATH: the destroy-plan fallback was not checked"
else
  mkdir -p "$TMP/shim"
  cat >"$TMP/shim/tofu" <<EOF
#!/usr/bin/env bash
"$real_tofu" "\$@"; rc=\$?
printf '%s rc=%s\\n' "\$*" "\$rc" >>"\$TOFU_LOG"
exit "\$rc"
EOF
  chmod +x "$TMP/shim/tofu"
  fixture
  C="$repo/infrastructure/opentofu/cluster"
  rm -f "$C/new.tf" "$C/envs/real.tfvars"
  mkdir -p "$repo/scripts/internal"
  printf '#!/usr/bin/env bash\necho placeholder\n' >"$repo/scripts/internal/resolve-s3-cred.sh"
  printf '#!/usr/bin/env bash\necho "-backend-config=path=%s"\n' "$TMP/cluster.tfstate" >"$repo/scripts/internal/tf-backend.sh"
  chmod +x "$repo"/scripts/internal/*.sh
  cat >"$C/main.tf" <<'EOF'
terraform {
  backend "local" {}
}
variable "image_state" { type = string }
variable "talos_bootstrap" { type = bool }
data "terraform_remote_state" "image" {
  backend = "local"
  config  = { path = var.image_state }
}
locals {
  image = coalesce(try(data.terraform_remote_state.image.outputs.images[0], null))
}
resource "terraform_data" "node" {
  input = local.image
}
EOF
  tfvars="$C/envs/management-scaleway.tfvars"
  printf 'image_state = "%s"\n' "$TMP/image.tfstate" >"$tfvars"
  images() { # the image registry's state: what the lookup finds under the pinned name
    printf '{"version":4,"terraform_version":"1.12.6","serial":1,"lineage":"00000000-0000-0000-0000-000000000000","outputs":{"images":{"value":%s,"type":["tuple",%s]}},"resources":[]}\n' \
      "$1" "$2" >"$TMP/image.tfstate"
  }
  images '["img-1"]' '["string"]'
  unset TF_WORKSPACE   # an exported one sends the seed's state, and the plans, to another workspace
  ( cd "$C" && export TF_DATA_DIR=.seed && "$real_tofu" init -input=false -backend-config=path="$TMP/cluster.tfstate" >/dev/null \
    && "$real_tofu" apply -auto-approve -input=false -var-file="$tfvars" -var talos_bootstrap=false >/dev/null ) \
    || { echo "✗ could not seed the fixture cluster — nothing was checked" >&2; exit 1; }
  rm -rf "$C/.seed"

  down() { : >"$TOFU_LOG"; rm -f "$C/d.tfplan"
    env -i PATH="$TMP/shim:$PATH" HOME="$HOME" TOFU_LOG="$TOFU_LOG" \
      task --dir "$repo" infra-down-plan PROVIDER=scaleway ROLE=management OUT=d.tfplan </dev/null >"$TMP/out" 2>&1; }
  plans() { grep '^plan -destroy ' "$TOFU_LOG"; }
  deletes() { ( cd "$C" && TF_DATA_DIR=.terraform-management-scaleway "$real_tofu" show -json d.tfplan 2>/dev/null ) | grep -q '"actions":\["delete"\]'; }

  down; rc=$?
  [ "$rc" -eq 0 ] && [ "$(plans | wc -l)" -eq 1 ] && ! grep -q -e '-refresh=false' "$TOFU_LOG" \
    && ok "image present: one refreshed plan, and the fallback stays the exit, not the default" \
    || bad "image present (rc=$rc, plans: $(plans | tr '\n' ';')): $(tail -5 "$TMP/out")"

  rm "$TMP/image.tfstate"
  down; rc=$?
  [ "$rc" -eq 0 ] && deletes && grep -q 'Unable to find remote state' "$TMP/out" && [ "$(plans | wc -l)" -eq 2 ] \
    && plans | sed -n 1p | grep -q ' rc=1$' && plans | sed -n 2p | grep -q -e '-refresh=false .*rc=0$' \
    && ok "lookup errors (scaleway, ovh): the refreshed plan fails, the state-only plan is written" \
    || bad "lookup errors (rc=$rc, plans: $(plans | tr '\n' ';')): $(tail -5 "$TMP/out")"
  # Anchored: go-task echoes the script's source into the output too, and every source line starts `echo "`.
  grep -q '^  stuck provisioning; the pinned image' "$TMP/out" \
    && ok "…and the warning names a gone image as a cause" || bad "the warning does not name the image: $(grep -A3 '^⚠ the refresh failed' "$TMP/out")"
  plans | grep -qv -e '-var talos_bootstrap=false' && bad "a plan lost -var talos_bootstrap=false (the tunnel read): $(plans)" \
    || ok "…both plans keep talos_bootstrap=false"

  images '[]' '[]'
  down; rc=$?
  [ "$rc" -eq 0 ] && deletes && grep -q 'no non-null, non-empty-string' "$TMP/out" && [ "$(plans | wc -l)" -eq 2 ] \
    && plans | sed -n 2p | grep -q -e '-refresh=false .*rc=0$' \
    && ok "an empty answer (outscale): the coalesce fails the refreshed plan, the state-only plan is written" \
    || bad "empty answer (rc=$rc, plans: $(plans | tr '\n' ';')): $(tail -5 "$TMP/out")"

  # A failure the fallback does not cure must not read as a plan: the caller (fleet-down) tests the rc.
  printf '# no image_state\n' >"$tfvars"
  down; rc=$?
  [ "$rc" -ne 0 ] && grep -q 'No value for required variable' "$TMP/out" && [ ! -e "$C/d.tfplan" ] \
    && [ "$(plans | wc -l)" -eq 2 ] && ! grep -q 'destruction plan written' "$TMP/out" \
    && ok "both plans failing: non-zero, no plan file, no success line" \
    || bad "both plans failing (rc=$rc, plans: $(plans | tr '\n' ';')): $(tail -5 "$TMP/out")"
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
