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
cp "$ROOT/scripts/dev/rung-receipt.py" "$ROOT/scripts/dev/feint.sh" "$ROOT/scripts/dev/ssh-ca-check.sh" \
  "$ROOT/scripts/dev/script-shard.sh" "$repo/scripts/dev/"
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

echo "=== test-scripts runs every test-*.sh but the excluded ones, and fails on anything written under envs/ ==="
fixture
cp "$ROOT/.pre-commit-config.yaml" "$repo/"
EXCL=scripts/dev/exclude-from-test-scripts.txt
cp "$ROOT/$EXCL" "$repo/$EXCL" 2>/dev/null || bad "$EXCL is missing: test-scripts has no list of what it leaves out"
# A stub for every harness of this tree, one for a harness added later (the Taskfile is not touched for it), and one
# for each explicit step. Each stub logs its name and arguments; WRITER writes, FAIL_ON fails.
new_harness=test-zz-new-harness.sh
stubs="$(cd "$ROOT" && ls scripts/dev/test-*.sh | sed 's|^|./|'; echo "./scripts/dev/$new_harness"; echo ./scripts/dev/check-jsonpath.sh; echo ./scripts/dev/check-required-checks.sh)"
for s in $stubs; do
  printf '#!/usr/bin/env bash\n%s\n%s\n%s\nexit 0\n' \
    'printf "%s\n" "$(basename "$0")${1:+ $1}" >>"$RUN_LOG"' \
    '[ "$(basename "$0")" != "${FAIL_ON:-}" ] || exit 7' \
    '[ "$(basename "$0")" != "$WRITER" ] || eval "$WRITE"' >"$repo/$s"
  chmod +x "$repo/$s"
done
g add -A && g commit -q -m stubs
envs="infrastructure/opentofu/cluster/envs"
export RUN_LOG="$TMP/run.log"
ts() { : >"$RUN_LOG"; PATH="$TMP/bin:$PATH" WRITER="$new_harness" WRITE="$1" FAIL_ON="${2:-}" task --dir "$repo" test-scripts ${3:+SHARD=$3} >"$TMP/out" 2>&1; }
ts true; rc=$?
[ "$rc" -eq 0 ] && ok "no step writes under envs/: test-scripts passes (rc=$rc)" || bad "clean run failed (rc=$rc): $(tail -5 "$TMP/out")"
# The expected set is computed here from the list, not copied from the Taskfile: every harness minus the excluded.
excluded="$(sed -E 's/[[:space:]]*#.*//; /^[[:space:]]*$/d' "$repo/$EXCL" 2>/dev/null)"
want="$({ for s in $stubs; do basename "$s"; done | grep -v '^check-required-checks.sh$' | grep -vxF -f <(echo "$excluded")
          echo "check-required-checks.sh --self-test"; } | sort)"
got="$(sort "$RUN_LOG")"
[ "$got" = "$want" ] && ok "it ran exactly the $(wc -l <<<"$want") harnesses and steps expected: every test-*.sh minus the excluded, plus the two explicit checks" \
  || bad "the executed set differs from the expected one: $(diff <(echo "$want") <(echo "$got") | head -12)"
grep -qx "$new_harness" "$RUN_LOG" && ok "a harness added without touching the Taskfile ($new_harness) runs" || bad "a new test-*.sh is not run by test-scripts"
head -n1 "$RUN_LOG" | grep -q '^check-jsonpath.sh$' && ok "the jsonpath check still runs first" || bad "check-jsonpath.sh is not first: $(head -n1 "$RUN_LOG")"
leaked=""
for x in $excluded; do grep -qx "$x" "$RUN_LOG" && leaked="$leaked $x"; done
[ -n "$excluded" ] && [ -z "$leaked" ] && ok "none of the $(wc -l <<<"$excluded") excluded harnesses ran" || bad "excluded harnesses ran (or none are excluded):${leaked:- (empty list)}"
ts true "$new_harness"; rc=$?
[ "$rc" -ne 0 ] && grep -q "$new_harness failed" "$TMP/out" && ok "a failing harness fails test-scripts and is named" \
  || bad "a failing harness (rc=$rc): $(tail -5 "$TMP/out")"
ts "printf x >$envs/leftover.tmp"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'a step wrote under envs/' "$TMP/out" && ok "a file left under envs/ fails it" \
  || bad "a file left behind (rc=$rc): $(tail -5 "$TMP/out")"
rm -f "$repo/$envs/leftover.tmp"
ts "printf x >$envs/scratch.tmp; rm $envs/scratch.tmp"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'a step wrote under envs/' "$TMP/out" && ok "…and so does one written and deleted again" \
  || bad "a file written then deleted (rc=$rc): $(tail -5 "$TMP/out")"

echo "=== test-scripts SHARD=k/4: the four quarters are one run, CI runs them on four runners ==="
# (script-shard.sh decides the split; its table is balanced on CI timings and a harness it does not list goes by checksum.)
mocked="$repo/.receipts/mocked.jsonl"
before="$(wc -l <"$mocked" 2>/dev/null || echo 0)"
: >"$TMP/shards.log"
sharded_ok=1
for k in 1 2 3 4; do
  ts true "" "$k/4"; rc=$?
  [ "$rc" -eq 0 ] || { sharded_ok=0; bad "SHARD=$k/4 failed (rc=$rc): $(tail -5 "$TMP/out")"; }
  cp "$RUN_LOG" "$TMP/shard$k.log"
  cat "$RUN_LOG" >>"$TMP/shards.log"
done
[ "$sharded_ok" -eq 1 ] && [ "$(sort "$TMP/shards.log")" = "$got" ] \
  && ok "SHARD=1/4..4/4 ran exactly what the unsharded task ran, each harness (new one included) in exactly one shard" \
  || bad "the four shards differ from the unsharded run: $(diff <(echo "$got") <(sort "$TMP/shards.log") | head -12)"
smallest="$(wc -l <"$TMP/shard1.log")"; largest="$smallest"
for k in 2 3 4; do
  c="$(wc -l <"$TMP/shard$k.log")"; [ "$c" -lt "$smallest" ] && smallest="$c"; [ "$c" -gt "$largest" ] && largest="$c"
done
[ "$smallest" -gt 2 ] && [ "$largest" -lt "$(wc -l <<<"$got")" ] \
  && ok "every shard runs a share of the harnesses (smallest $smallest, largest $largest of $(wc -l <<<"$got"))" \
  || bad "a shard runs (almost) nothing or everything: $smallest..$largest"
head -n1 "$TMP/shard1.log" | grep -q '^check-jsonpath.sh$' && grep -qx 'check-required-checks.sh --self-test' "$TMP/shard1.log" \
  && ! grep -qE '^check-(jsonpath|required-checks)' "$TMP/shard2.log" "$TMP/shard3.log" "$TMP/shard4.log" \
  && ok "the two preface checks run first, in shard 1 only" || bad "the preface checks are not in shard 1 alone"
[ "$(wc -l <"$mocked" 2>/dev/null || echo 0)" -eq "$before" ] && ok "a SHARD run records no receipt: a quarter of the harnesses is not the mocked rung" \
  || bad "a SHARD run wrote a receipt: $(tail -n1 "$mocked")"
[ "$before" -gt 0 ] && ok "…while the unsharded runs above did record theirs ($before)" || bad "no unsharded run recorded a receipt: the check above proves nothing"
for odd in 0/4 5/4 1/3 x 1/; do
  ts true "" "$odd"; rc=$?
  [ "$rc" -ne 0 ] && ! grep -q '^test-' "$RUN_LOG" && ok "SHARD=$odd is refused before any harness runs" \
    || bad "SHARD=$odd (rc=$rc) ran harnesses: $(grep -c '^test-' "$RUN_LOG")"
done
cp "$repo/scripts/dev/script-shard.sh" "$TMP/script-shard.good"
sed -i '/^test-cluster-up.sh /a test-gone.sh 2' "$repo/scripts/dev/script-shard.sh"
ts true "" 1/4; rc=$?
[ "$rc" -ne 0 ] && grep -q 'test-gone.sh' "$TMP/out" && ! grep -q '^test-' "$RUN_LOG" \
  && ok "a table line naming no harness fails the shard before it runs one" || bad "a stale table line (rc=$rc): $(tail -3 "$TMP/out")"
cp "$TMP/script-shard.good" "$repo/scripts/dev/script-shard.sh"
sed -i '/^test-cluster-up.sh /a test-cluster-up.sh 2' "$repo/scripts/dev/script-shard.sh"
ts true "" 1/4; rc=$?
[ "$rc" -ne 0 ] && grep -q 'twice' "$TMP/out" && ok "a harness listed twice fails the shard" || bad "a duplicate table line (rc=$rc): $(tail -3 "$TMP/out")"
cp "$TMP/script-shard.good" "$repo/scripts/dev/script-shard.sh"
out="$("$ROOT/scripts/dev/script-shard.sh" --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "this tree's table names real harnesses and every one is in exactly one shard: $(tail -n1 <<<"$out")" \
  || bad "script-shard.sh --check on this tree (rc=$rc): $out"

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

echo "=== infra-down-plan replicates the state before it untracks the secrets, and only while they are tracked (#66) ==="
# The real block against a stub tofu (state list / state rm / plan, over a state held in a file) and a stub
# backup-state.sh, all writing one call log: what matters is which calls happen, and in which order.
fixture
C="$repo/infrastructure/opentofu/cluster"
rm -f "$C/new.tf" "$C/envs/real.tfvars"
mkdir -p "$repo/scripts/internal" "$repo/scripts/ops" "$TMP/stub"
printf '#!/usr/bin/env bash\necho placeholder\n' >"$repo/scripts/internal/resolve-s3-cred.sh"
printf '#!/usr/bin/env bash\necho "-backend-config=path=x"\n' >"$repo/scripts/internal/tf-backend.sh"
cat >"$repo/scripts/ops/backup-state.sh" <<'EOF'
#!/usr/bin/env bash
echo "backup-state $*" >>"$CALLS"
[ "${BK_RC:-0}" = 0 ] || { echo "✗ could not read backup_targets" >&2; exit "$BK_RC"; }
echo "${BK_OUT-✓ tfstate replicated (still client-encrypted) to s3://replica/k.tfstate — SAME provider}"
EOF
chmod +x "$repo"/scripts/internal/*.sh "$repo/scripts/ops/backup-state.sh"
cat >"$TMP/stub/tofu" <<'EOF'
#!/usr/bin/env bash
echo "tofu $1 ${2-}" >>"$CALLS"
case "$1 ${2-}" in
  "state list") [ "${LIST_RC:-0}" = 0 ] || { echo "Error: No state file was found!" >&2; exit "$LIST_RC"; }; cat "$STUB_STATE" ;;
  "state rm") [ "${RM_RC:-0}" = 0 ] || { echo "Error: Error acquiring the state lock" >&2; exit "$RM_RC"; }
              grep -vF "$3" "$STUB_STATE" >"$STUB_STATE.new"; mv "$STUB_STATE.new" "$STUB_STATE" ;;
  plan*) for a in "$@"; do case "$a" in -out=*) : >"${a#-out=}" ;; esac; done ;;
esac
exit 0
EOF
chmod +x "$TMP/stub/tofu"
export CALLS="$TMP/calls"
WITH=$'module.scw[0].x\nmodule.talos.talos_machine_bootstrap.this[0]\nmodule.talos.talos_machine_secrets.this[0]'
WITHOUT=$'module.scw[0].x\nmodule.talos.talos_machine_bootstrap.this[0]'
untrack() { # <state held by the stub> [VAR=value…]: the task's stdout in out, its stderr in err
  local s="$1"; shift; : >"$CALLS"; rm -f "$C/d.tfplan"; printf '%s\n' "$s" >"$TMP/stub.state"
  env -i PATH="$TMP/stub:$PATH" HOME="$HOME" CALLS="$CALLS" STUB_STATE="$TMP/stub.state" "$@" \
    task --silent --dir "$repo" infra-down-plan PROVIDER=scaleway ROLE=management OUT=d.tfplan </dev/null >"$TMP/out" 2>"$TMP/err"
}
calls() { grep -E '^(tofu state|backup-state)' "$CALLS" | sed 's/^tofu state /state /' | tr '\n' ';'; }
secrets_tracked() { grep -q talos_machine_secrets "$TMP/stub.state"; }

untrack "$WITH"; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls)" = 'state list;backup-state .;state rm;state list;' ] && ! secrets_tracked && [ -e "$C/d.tfplan" ] \
  && ok "secrets tracked: read the state, replicate it, THEN untrack, then plan" \
  || bad "secrets tracked (rc=$rc, calls: $(calls)): $(cat "$TMP/err")"
grep -q 'Undo, if you decline' "$TMP/out" && ! grep -q 'NOT replicated' "$TMP/err" && grep -q 'no longer tracks the Talos secrets' "$TMP/out" \
  && ok "…and says how to undo it, and again beside the plan that was written" \
  || bad "no undo hint: $(cat "$TMP/out") $(cat "$TMP/err")"

untrack "$WITHOUT"; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls)" = 'state list;state list;' ] && grep -q 'already out of the state' "$TMP/out" && ! grep -q 'Undo, if you decline' "$TMP/out" \
  && ok "secrets already out (an earlier run untracked them): nothing replicated and nothing untracked, so the snapshot stays the undo" \
  || bad "secrets already out (rc=$rc, calls: $(calls)): $(cat "$TMP/out") $(cat "$TMP/err")"
grep -q 'no longer tracks the Talos secrets' "$TMP/out" && ok "…and the plan's last lines still say so" || bad "no reminder beside the plan: $(cat "$TMP/out")"

untrack "$WITH" LIST_RC=1; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls)" = 'state list;state list;' ] && grep -q 'cannot read the state' "$TMP/err" && ! grep -q 'already out of the state' "$TMP/out" \
  && ! grep -q 'no longer tracks' "$TMP/out" && ok "state unreadable: nothing untracked, nothing replicated, said on stderr, the teardown goes on" \
  || bad "state unreadable (rc=$rc, calls: $(calls)): $(cat "$TMP/out") $(cat "$TMP/err")"

untrack "$WITH" BK_RC=1; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls)" = 'state list;backup-state .;state rm;state list;' ] && ! secrets_tracked && grep -q 'NOT replicated' "$TMP/err" \
  && ! grep -q 'Undo, if you decline' "$TMP/out" \
  && ok "replication fails: the secrets are still untracked, the warning is on stderr, no undo is promised, the exit is 0" \
  || bad "replication fails (rc=$rc, calls: $(calls)): $(cat "$TMP/out") $(cat "$TMP/err")"

untrack "$WITH" BK_OUT='⚠ no backup_targets output — apply the infra first. Skipping state backup.'; rc=$?
[ "$rc" -eq 0 ] && grep -q 'NOT replicated' "$TMP/err" && ! grep -q 'Undo, if you decline' "$TMP/out" \
  && ok "replication skipped (exit 0, no ✓ line): no undo is promised either" \
  || bad "replication skipped (rc=$rc): $(cat "$TMP/out") $(cat "$TMP/err")"

untrack "$WITH" RM_RC=1; rc=$?
[ "$rc" -eq 0 ] && secrets_tracked && grep -q 'state rm failed' "$TMP/err" && ! grep -q 'Undo, if you decline' "$TMP/out" \
  && ! grep -q 'no longer tracks' "$TMP/out" \
  && ok "state rm fails (a lock): nothing was untracked, no undo is promised, the exit is 0" \
  || bad "state rm fails (rc=$rc): $(cat "$TMP/out") $(cat "$TMP/err")"

untrack 'module.scw[0].x'; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls)" = 'state list;state list;' ] && ! grep -q 'no longer tracks' "$TMP/out" \
  && ok "a state that never held Talos resources: nothing to untrack, and no warning about secrets it never had" \
  || bad "no Talos resources (rc=$rc, calls: $(calls)): $(cat "$TMP/out") $(cat "$TMP/err")"

echo "=== upgrade hands DRY_RUN and UPGRADE_*_TO to the script, from the command line or the shell ==="
# A Task variable is not an environment variable and cluster-upgrade.sh reads the
# environment, so `task upgrade DRY_RUN=1` once started a real upgrade. The script is a stub.
fixture
printf '#!/usr/bin/env bash\necho "stub dry=[${DRY_RUN-}] talos=[${UPGRADE_TALOS_TO-}] k8s=[${UPGRADE_K8S_TO-}]"\n' >"$repo/scripts/dev/cluster-upgrade.sh"
chmod +x "$repo/scripts/dev/cluster-upgrade.sh"
unset DRY_RUN UPGRADE_TALOS_TO UPGRADE_K8S_TO
up() { PATH="$TMP/bin:$PATH" task --dir "$repo" upgrade PROVIDER=scaleway "$@" </dev/null >"$TMP/out" 2>&1; sed -nE 's/\x1b\[[0-9;]*m//g; s/^stub //p' "$TMP/out"; }  # CI colours Task's lines
check() { [ "$3" = "$2" ] && ok "$1" || bad "$1: want '$2', got '$3': $(tail -3 "$TMP/out")"; }
all='dry=[1] talos=[1.2.3] k8s=[1.30.4]'
check "on the command line, all three reach the script" "$all" "$(up DRY_RUN=1 UPGRADE_TALOS_TO=1.2.3 UPGRADE_K8S_TO=1.30.4)"
check "from the shell, all three reach the script" "$all" "$(DRY_RUN=1 UPGRADE_TALOS_TO=1.2.3 UPGRADE_K8S_TO=1.30.4 up)"
check "one given, the other two arrive empty" 'dry=[1] talos=[] k8s=[]' "$(up DRY_RUN=1)"
check "none given, and nothing leaks from the runs before" 'dry=[] talos=[] k8s=[]' "$(up)"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
