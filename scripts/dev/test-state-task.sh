#!/usr/bin/env bash
# ==============================================================================
# `task state` answers "what is in this cluster's state?" and must never change
# the answer (#53).
#
# The real Taskfile target runs, under the real go-task and the real tofu, in a
# throwaway copy of the repository layout. Only two things are swapped: the
# cluster root is a two-resource fixture on a LOCAL backend, and tf-backend.sh
# points that backend at a fixture state file instead of an S3 bucket. The
# encryption block is kept, so the passphrase has to reach tofu for real.
#
# Offline, no credentials: the S3 keys the target insists on are placeholders.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

for t in task tofu python3; do
  command -v "$t" >/dev/null || { echo "✗ $t is required and not on PATH — nothing was checked" >&2; exit 1; }
done

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"
mkdir -p "$C/envs" "$W/scripts/internal" "$W/scripts/lib" "$W/state" "$W/bin"

# CI's setup-opentofu puts a Node wrapper on PATH as `tofu`: under `env -i` it
# loses TOFU_CLI_PATH and dies, or loses GITHUB_OUTPUT and prints ::set-output
# on stdout. The binary behind it is what an operator runs, so test that.
real="$(command -v tofu)"
[ -n "${TOFU_CLI_PATH:-}" ] && [ -x "$TOFU_CLI_PATH/tofu-bin" ] && real="$TOFU_CLI_PATH/tofu-bin"
# The shim in front of it logs what each call gets, so a case can check which keys
# and data dir tofu used rather than what the target meant to give it.
cat >"$W/bin/tofu" <<EOF
#!/usr/bin/env bash
echo "ak=\${AWS_ACCESS_KEY_ID-} sk=\${AWS_SECRET_ACCESS_KEY-} data=\${TF_DATA_DIR-} ws=\${TF_WORKSPACE-unset}" >>"$W/tofu.log"
exec "$real" "\$@"
EOF
chmod +x "$W/bin/tofu"
PATH="$W/bin:$PATH"
ver="$(env -i PATH="$PATH" HOME="$HOME" tofu version 2>&1)"
{ [[ "$ver" == "OpenTofu v"* ]] && ! grep -q '^::' <<<"$ver"; } || {
  echo "✗ tofu does not run cleanly in an empty environment — nothing was checked: $(head -c 300 <<<"$ver")" >&2
  exit 1; }

cp Taskfile.yml "$W/"
cp scripts/lib/common.sh "$W/scripts/lib/"
cp scripts/internal/resolve-s3-cred.sh "$W/scripts/internal/"

# Stands in for the S3 flags: same contract (one tfvars in, -backend-config
# flags out, non-zero on a missing file), and it logs which tfvars it was given.
cat >"$W/scripts/internal/tf-backend.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$1" >>"$(dirname "$0")/../../backend.log"
[ -f "$1" ] || { echo "tf-backend.sh: tfvars not found: $1" >&2; exit 1; }
printf -- '-backend-config=path=%s' "$(sed -n 's/^fixture_state *= *"\(.*\)"$/\1/p' "$1")"
EOF
chmod +x "$W/scripts/internal/tf-backend.sh"

cat >"$C/main.tf" <<'EOF'
variable "encryption_passphrase" {
  type      = string
  sensitive = true
}

terraform {
  encryption {
    key_provider "pbkdf2" "k" {
      passphrase = var.encryption_passphrase
      iterations = 200000 # OpenTofu's floor: a third of the default's CPU, per run
    }
    method "aes_gcm" "m" {
      keys = key_provider.pbkdf2.k
    }
    state {
      method = method.aes_gcm.m
    }
  }
  backend "local" {}
}

resource "terraform_data" "probe" {
  input = "fixture"
}

# A string for_each key: the address carries double quotes and brackets, which
# is what ADDR= has to survive on its way through the shell.
resource "terraform_data" "keyed" {
  for_each = toset(["a-0"])
  input    = each.key
}
EOF

# One env file per case, told apart by ROLE: a deployed cluster, one that was
# never deployed, and one whose resources were all destroyed.
for r in management workload failover; do
  printf 'fixture_state = "%s/state/%s.tfstate"\n' "$W" "$r" >"$C/envs/$r-scaleway.tfvars"
done

PASSPHRASE=fixture-passphrase-of-at-least-32-characters
# A clean environment: nothing from the caller's shell (real keys included)
# reaches the target. The placeholders satisfy its credential guard only.
# AMBIENT holds what a case exports on top, as a stale shell would.
AMBIENT=()
run() { # <stdout> <stderr> <task args...>
  local o="$1" e="$2"; shift 2
  : >"$W/tofu.log"
  env -i PATH="$PATH" HOME="$HOME" TF_VAR_encryption_passphrase="${PP-$PASSPHRASE}" \
      SCW_ACCESS_KEY="${AK-scw-access-key}" SCW_SECRET_KEY="${SK-scw-secret-key}" \
      OVH_AWS_ACCESS_KEY_ID=placeholder OVH_AWS_SECRET_ACCESS_KEY=placeholder \
      ${AMBIENT[@]+"${AMBIENT[@]}"} \
      task -d "$W" state "$@" >"$o" 2>"$e"
}
tofu_ran() { [ -s "$W/tofu.log" ]; }

seed() { # <role> <apply|destroy...>
  local role="$1"; shift
  ( cd "$C" && export TF_DATA_DIR=".seed-$role" TF_VAR_encryption_passphrase="$PASSPHRASE" &&
    tofu init -input=false "$("$W/scripts/internal/tf-backend.sh" "envs/$role-scaleway.tfvars")" >/dev/null &&
    for verb in "$@"; do tofu "$verb" -auto-approve -input=false >/dev/null || exit 1; done ) \
    || { echo "✗ could not seed the $role fixture state — nothing was checked" >&2; exit 1; }
  rm -rf "$C/.seed-$role"
}
seed management apply
seed failover apply destroy
: >"$W/backend.log"
before="$(sha256sum "$W"/state/*.tfstate)"
O="$W/out"; E="$W/err"
LISTING="$(printf '%s\n' 'terraform_data.keyed["a-0"]' 'terraform_data.probe')"


echo "--- it lists the state it was pointed at ---"
run "$O" "$E" PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && ok "task state PROVIDER=scaleway exits 0" || bad "exit $rc: $(head -c 400 "$E")"
[ "$(cat "$O")" = "$LISTING" ] \
  && ok "stdout is exactly the two resource addresses — init's progress is on stderr, so it pipes" \
  || bad "stdout is not the listing alone: $(head -c 300 "$O")"
grep -qx 'envs/management-scaleway.tfvars' "$W/backend.log" \
  && ok "the backend comes from envs/<ROLE>-<PROVIDER>.tfvars, ROLE defaulting to management" \
  || bad "tf-backend.sh was handed: $(tr '\n' ' ' <"$W/backend.log")"
grep -qF "→ state at path=$W/state/management.tfstate" "$E" \
  && ok "it says which state it read" || bad "no location line on stderr"
[ -d "$C/.terraform-management-scaleway" ] && [ ! -e "$C/.terraform" ] \
  && ok "the backend pointer lives in .terraform-management-scaleway, shared with nothing else" \
  || bad "the data dir is not the per-cluster one: $(ls -A "$C" | tr '\n' ' ')"


echo "--- ADDR= shows one resource, quotes and brackets included ---"
run "$O" "$E" PROVIDER=scaleway 'ADDR=terraform_data.keyed["a-0"]'; rc=$?
[ "$rc" = 0 ] && grep -qF '# terraform_data.keyed["a-0"]:' "$O" && grep -qF 'input  = "a-0"' "$O" \
  && ok "a for_each instance address reaches tofu state show intact" \
  || bad "ADDR= keyed: exit $rc — $(head -c 300 "$O") $(head -c 300 "$E")"
run "$O" "$E" PROVIDER=scaleway ADDR=terraform_data.absent; rc=$?
[ "$rc" != 0 ] && grep -q 'No instance found for the given address' "$E" \
  && ok "an address that is not in the state fails, on tofu's own 'No instance found'" \
  || bad "ADDR= absent: exit $rc — $(head -c 300 "$E")"


echo "--- an empty answer is never ambiguous ---"
run "$O" "$E" PROVIDER=scaleway ROLE=workload; rc=$?
[ "$rc" != 0 ] && grep -q 'nothing is stored at that key' "$E" \
  && ok "no state at the key fails, and says what that means instead of passing as empty" \
  || bad "ROLE=workload: exit $rc — $(head -c 300 "$E")"
[ -d "$C/.terraform-workload-scaleway" ] && grep -qx 'envs/workload-scaleway.tfvars' "$W/backend.log" \
  && ok "ROLE=workload reads its own env file, into its own data dir" \
  || bad "ROLE=workload did not select its own backend"
run "$O" "$E" PROVIDER=scaleway ROLE=workload ADDR=terraform_data.probe; rc=$?
[ "$rc" != 0 ] && grep -q 'nothing is stored at that key' "$E" \
  && ok "ADDR= on a key with no state gets the same explanation, not a bare 'No state file was found!'" \
  || bad "ROLE=workload ADDR=: exit $rc — $(head -c 300 "$E")"
run "$O" "$E" PROVIDER=scaleway ROLE=failover; rc=$?
[ "$rc" = 0 ] && [ ! -s "$O" ] && grep -q 'exists and holds no resources' "$E" \
  && ok "a state whose resources were destroyed says so, and exits 0" \
  || bad "ROLE=failover: exit $rc — $(head -c 300 "$O") $(head -c 300 "$E")"


echo "--- a wrong input is refused by name, before tofu runs ---"
run "$O" "$E" PROVIDER=ovh; rc=$?
[ "$rc" != 0 ] && grep -q 'tfvars not found' "$E" && ! tofu_ran && [ ! -e "$C/.terraform-management-ovh" ] \
  && ok "no env file for the provider: refused, and init never ran without a backend" \
  || bad "exit $rc, tofu calls $(wc -l <"$W/tofu.log") — $(head -c 300 "$E")"
# An exported AWS_* is some other cloud's key: it must not satisfy the guard.
AMBIENT=(AWS_ACCESS_KEY_ID=another-clouds-key); AK='' run "$O" "$E" PROVIDER=scaleway; rc=$?; AMBIENT=()
[ "$rc" != 0 ] && grep -q "no S3 access key for 'scaleway'.*source .env.sh" "$E" && ! tofu_ran \
  && ok "no S3 access key: refused by name before tofu runs, even with AWS_ACCESS_KEY_ID exported" \
  || bad "no access key: exit $rc — $(head -c 300 "$E")"
AMBIENT=(AWS_SECRET_ACCESS_KEY=another-clouds-secret); SK='' run "$O" "$E" PROVIDER=scaleway; rc=$?; AMBIENT=()
[ "$rc" != 0 ] && grep -q "no S3 secret key for 'scaleway'.*source .env.sh" "$E" && ! tofu_ran \
  && ok "no S3 secret key: refused by name before tofu runs, even with AWS_SECRET_ACCESS_KEY exported" \
  || bad "no secret key: exit $rc — $(head -c 300 "$E")"
PP='' run "$O" "$E" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && grep -q 'TF_VAR_encryption_passphrase is not set' "$E" && ! tofu_ran \
  && ok "no passphrase: refused by name, not left to a tofu prompt" \
  || bad "no passphrase: exit $rc — $(head -c 300 "$E")"
# Refused by the resolver, not refuse-local's own message: go-task resolves the
# provider env (resolve-s3-cred.sh rejects `local`) before preconditions.
run "$O" "$E" PROVIDER=local; rc=$?
[ "$rc" != 0 ] && grep -q "unknown provider 'local'" "$E" && ! tofu_ran \
  && ok "PROVIDER=local is refused as an unknown provider, before tofu runs" \
  || bad "PROVIDER=local: exit $rc — $(head -c 300 "$E")"


echo "--- the caller's exported AWS_*, TF_DATA_DIR and TF_WORKSPACE do not leak in ---"
AMBIENT=(AWS_ACCESS_KEY_ID=stale-ak AWS_SECRET_ACCESS_KEY=stale-sk TF_DATA_DIR=.terraform-elsewhere TF_WORKSPACE=ghost)
run "$O" "$E" PROVIDER=scaleway; rc=$?; AMBIENT=()
[ "$rc" = 0 ] && [ "$(cat "$O")" = "$LISTING" ] \
  && ok "it still lists the cluster's own state" \
  || bad "stale exports: exit $rc — $(head -c 300 "$O") $(head -c 300 "$E")"
calls="$(sort -u "$W/tofu.log" | tr '\n' ';')"; n="$(wc -l <"$W/tofu.log")"
[ "$n" -ge 2 ] && ! grep -qv '^ak=scw-access-key sk=scw-secret-key ' "$W/tofu.log" \
  && ok "every tofu call got the keys the guard checked, not the exported ones" || bad "tofu got: $calls"
[ "$n" -ge 2 ] && ! grep -qv ' data=\.terraform-management-scaleway ' "$W/tofu.log" \
  && [ ! -e "$C/.terraform-elsewhere" ] \
  && ok "every tofu call used the per-cluster data dir, not the exported one" || bad "tofu got: $calls"
[ "$n" -ge 2 ] && ! grep -qv ' ws=unset$' "$W/tofu.log" && [ ! -e "$C/terraform.tfstate.d" ] \
  && ok "no tofu call saw TF_WORKSPACE, and no workspace was created" || bad "tofu got: $calls"


echo "--- read-only: measured, then held ---"
[ "$(sha256sum "$W"/state/*.tfstate)" = "$before" ] \
  && ok "after every run above, both fixture states are byte-identical" \
  || bad "a state file changed — this target wrote to a state"
# The runs above cover the paths they take. For paths added later, this reads
# the target's text: a tofu verb written out in it must be one of the three
# read-only ones. It does not see a call made through a variable or `sh -c "…"`.
VERBS="$(python3 - <<'PY'
import re, yaml
t = yaml.safe_load(open('Taskfile.yml'))['tasks'].get('state') or {}
body = '\n'.join(c if isinstance(c, str) else c.get('cmd', '') for c in t.get('cmds') or [])
for line in body.splitlines():
    if line.lstrip().startswith('#'):
        continue
    # A quoted string is prose ("if tofu said …"), unless it is a "$(…)" that runs.
    line = re.sub(r'"(?!\$\()[^"]*"', '', line)
    for m in re.finditer(r'\btofu((?:\s+-\S+)*)\s+([a-z-]+)(?:\s+([a-z-]+))?', line):
        verb = m.group(2) + (' ' + m.group(3) if m.group(2) == 'state' and m.group(3) else '')
        flags = re.findall(r'-[a-z-]+', line[m.end():])
        print(verb + ('' if verb != 'init' else ' ' + ' '.join(flags)))
    if re.search(r'ensure-buckets|\btask\s+[a-z]', line):
        print('WRITES ' + line.strip())
PY
)"
BAD_VERBS="$(grep -vE '^(init( .*)?|state list|state show)$' <<<"$VERBS")"
[ -z "$BAD_VERBS" ] && ok "the only tofu verbs written in the target are init, state list and state show" \
  || bad "the target can mutate: $(tr '\n' ';' <<<"$BAD_VERBS")"
grep -E '^init' <<<"$VERBS" | grep -qE -- '-migrate-state|-force-copy' \
  && bad "init is allowed to migrate state" || ok "init never migrates or copies state"
for v in init 'state list' 'state show'; do
  grep -q "^$v" <<<"$VERBS" && ok "found: tofu $v" \
    || bad "no tofu $v in the target — the reader went blind or the target moved"
done
grep -q 'scripts/dev/test-state-task\.sh' Taskfile.yml \
  && ok "this harness is registered in task test-scripts" \
  || bad "this harness is not registered — CI would never run it"


echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
