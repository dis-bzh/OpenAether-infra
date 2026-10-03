#!/usr/bin/env bash
# ==============================================================================
# `task cluster-up` succeeds only when the verifier does (#84).
#
# The real Taskfile runs under the real go-task, from cluster-up's first guard to
# its closing line, in a throwaway copy of the repository layout. Only the leaves
# are stubs: tofu, and every script the journey calls except the S3 credential
# resolver. The verifier's exit code is the one input a case chooses.
#
# Offline, no credentials: the S3 keys the guards insist on are placeholders.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

TASK="$(command -v task)" || { echo "✗ task is required and not on PATH — nothing was checked" >&2; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"
mkdir -p "$C/envs" "$C/bootstrap-manifests" "$W/scripts"/{internal,bootstrap,ops,dev,lib} "$W/bin"
cp Taskfile.yml "$W/"
cp scripts/lib/common.sh "$W/scripts/lib/"
cp scripts/internal/resolve-s3-cred.sh "$W/scripts/internal/"

# One stub behind every leaf: it logs "<name> <args>" in call order, then answers
# what the next step reads. A plan file must exist for infra-apply to take it.
cat >"$W/stub" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$0") \$*" >>"$W/calls.log"
case "\$(basename "\$0") \$*" in
  "tofu plan"*) for a in "\$@"; do case "\$a" in -out=*) : >"\${a#-out=}" ;; esac; done ;;
  "tofu output -raw "*) echo "fixture-\$3" ;;
  "talos-version.sh workload-"*) echo v0.0.1-fixture ;;
  talos-version.sh*) echo v0.0.0-fixture ;;
  tf-backend.sh*) echo -backend-config=path=fixture.tfstate ;;
  bootstrap-in-state.sh*) echo false ;;
  ssh-keygen*) exit 1 ;;
  infra-verify.sh*) echo "fixture verifier \$*: exit \${VERIFY_RC:?}"; exit "\$VERIFY_RC" ;;
  adopt-bootstrap.sh*) exit "\${ADOPT_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$W/stub"
for s in internal/talos-version.sh internal/ensure-buckets.sh internal/converge-versions.sh \
         internal/tf-backend.sh internal/bootstrap-in-state.sh internal/explain-failure.sh bootstrap/talos-image.sh \
         bootstrap/render-bootstrap-manifests.sh bootstrap/talos-tunnels.sh bootstrap/adopt-bootstrap.sh bootstrap/grow-nodes.sh internal/refuse-node-deletes.sh \
         ops/backup-state.sh dev/infra-verify.sh; do
  ln -s "$W/stub" "$W/scripts/$s"
done
ln -s "$W/stub" "$W/bin/tofu"; ln -s "$W/stub" "$W/bin/ssh-keygen"
echo 'fixture: rendered' >"$C/bootstrap-manifests/cilium.yaml"
for e in management-scaleway workload-ovh; do echo 'cluster_name = "fixture"' >"$C/envs/$e.tfvars"; done
: >"$W/key"

O="$W/out"
run() { # <verifier rc> <task args...> — combined output in $O, calls in calls.log; EXTRA=NAME=value sets one env var, last, so it overrides the defaults
  local rc="$1"; shift
  : >"$W/calls.log"
  env -i PATH="$W/bin:$PATH" HOME="$W" VERIFY_RC="$rc" \
      TF_VAR_encryption_passphrase=fixture-passphrase-of-at-least-32-characters \
      SCW_ACCESS_KEY=scw-access-key SCW_SECRET_KEY=scw-secret-key \
      OVH_AWS_ACCESS_KEY_ID=ovh-access-key OVH_AWS_SECRET_ACCESS_KEY=ovh-secret-key \
      ${EXTRA:+"$EXTRA"} \
      "$TASK" -d "$W" "$@" </dev/null >"$O" 2>&1
}
calls() { grep -c "$1" "$W/calls.log"; }
# Last matching line; converge-versions' --check dry run is not the roll.
line_of() { grep -n "$2" "$1" | grep -v -- '--check$' | tail -1 | cut -d: -f1; }
tail_of() { tail -n 4 "$O" | tr '\n' ' '; }
# Phase 2 asks the nodes whether a bootstrap the state forgot already ran (#67): once,
# for this role then provider, after the tunnels it needs and before the plan that would
# re-send the RPC. A hardcoded role or provider reaches another cluster's tfvars.
adopted_once() { # <role> <provider>
  local t a p
  t="$(line_of "$W/calls.log" '^talos-tunnels.sh open')"; a="$(line_of "$W/calls.log" '^adopt-bootstrap.sh ')"
  p="$(line_of "$W/calls.log" '^tofu plan -out=phase2-')"
  [ "$(calls '^adopt-bootstrap.sh ')" = 1 ] && grep -qx "adopt-bootstrap.sh $1 $2" "$W/calls.log" \
    && [ -n "$t" ] && [ -n "$a" ] && [ -n "$p" ] && [ "$t" -lt "$a" ] && [ "$a" -lt "$p" ] \
    && ok "the adoption check runs once, for $1/$2 (role, then provider), between the tunnels and phase 2's plan" \
    || bad "adopt-bootstrap.sh was called $(calls '^adopt-bootstrap.sh ') times, got: $(grep '^adopt-bootstrap' "$W/calls.log"); tunnels at ${t:-none}, it at ${a:-none}, plan at ${p:-none}"
}
UP=(cluster-up KEY="$W/key" APPROVE=auto)


echo "--- a failing verifier fails cluster-up ---"
run 1 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && ok "cluster-up exits $rc" || bad "cluster-up exits 0 on a failing verifier"
grep -q 'cluster-up complete' "$O" \
  && bad "the success line was printed (or echoed) on a failing verifier" \
  || ok "the success line is nowhere in the output"
# Without this, a journey that died on an earlier step would pass both above.
# A plan that deletes a node is refused before the question and before any apply (the stub answers 0 here,
# the real script's verdicts are test-refuse-node-deletes.sh's).
r1="$(grep -n '^refuse-node-deletes.sh up-' "$W/calls.log" | head -1 | cut -d: -f1)"
pl="$(grep -n '^tofu plan -out=up-' "$W/calls.log" | head -1 | cut -d: -f1)"
ap="$(grep -n '^tofu apply up-' "$W/calls.log" | head -1 | cut -d: -f1)"
{ [ -n "$r1" ] && [ -n "$pl" ] && [ -n "$ap" ] && [ "$pl" -lt "$r1" ] && [ "$r1" -lt "$ap" ]; } \
  && ok "the node-delete guard runs after the plan is written and before anything is applied" \
  || bad "the node-delete guard is misplaced: plan at ${pl:-none}, guard at ${r1:-none}, apply at ${ap:-none}"
# Three places, none redundant: cluster-up before its question, infra-apply before its apply, phase 2 before its question.
{ [ "$(calls '^refuse-node-deletes.sh up-')" = 2 ] && [ "$(calls '^refuse-node-deletes.sh phase2-')" = 1 ]; } \
  && ok "the guard is called by cluster-up and infra-apply on the phase-1 plan, and by phase 2 on its own" \
  || bad "the guard was called: $(grep '^refuse-node-deletes' "$W/calls.log" | tr '\n' '|')"
[ "$(calls '^infra-verify.sh ')" = 1 ] && grep -qx 'infra-verify.sh scaleway management' "$W/calls.log" \
  && ok "the verifier ran once, for scaleway/management — it is what failed the run" \
  || bad "the verifier was not what failed: $(tail_of)"
adopted_once management scaleway


echo "--- a passing verifier lets cluster-up say so ---"
# Both variables differ from the case above, so a hardcoded one cannot pass.
run 0 "${UP[@]}" PROVIDER=ovh ROLE=workload; rc=$?
[ "$rc" = 0 ] && ok "cluster-up exits 0" || bad "cluster-up exits $rc: $(tail_of)"
grep -qx 'infra-verify.sh ovh workload' "$W/calls.log" \
  && ok "ROLE and PROVIDER reach the verifier" \
  || bad "the verifier got: $(grep '^infra-verify' "$W/calls.log")"
v="$(line_of "$O" '^fixture verifier')"; s="$(line_of "$O" '^✓ cluster-up complete')"
[ -n "$v" ] && [ -n "$s" ] && [ "$s" -gt "$v" ] \
  && ok "the success line is printed, after the verifier's verdict" \
  || bad "verifier at line ${v:-none}, success line at ${s:-none}"
adopted_once workload ovh
# The roll needs a kubeconfig, and so does the verifier after it: every cluster in
# the checkout writes the same path, so the verifier must not trust the pre-roll copy.
K='^tofu output -raw kubeconfig'
k1="$(grep -n "$K" "$W/calls.log" | head -1 | cut -d: -f1)"; k2="$(line_of "$W/calls.log" "$K")"
c="$(line_of "$W/calls.log" '^converge-versions.sh ')"; i="$(line_of "$W/calls.log" '^infra-verify.sh')"
[ "$(calls "$K")" = 2 ] && [ -n "$c" ] && [ -n "$i" ] && [ "${k1:-0}" -lt "$c" ] && [ "$c" -lt "${k2:-0}" ] && [ "$k2" -lt "$i" ] \
  && ok "kubeconfig is fetched before the roll, and again between the roll and the verifier" \
  || bad "fetches: $(calls "$K"), first ${k1:-none}, last ${k2:-none}; roll at ${c:-none}; verify at ${i:-none}"


echo "--- a failing adoption stops phase 2 before its plan ---"
# The script exits 1 only after etcd answered and its import failed: planning on would
# re-send the Bootstrap it exists to prevent.
EXTRA=ADOPT_RC=1 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
[ "$rc" != 0 ] && [ "$(calls '^adopt-bootstrap.sh ')" = 1 ] && ok "cluster-up exits $rc after the adoption failed" \
  || bad "exit $rc, adoption calls: $(calls '^adopt-bootstrap.sh ')"
[ "$(calls '^tofu plan -out=phase2-')" = 0 ] && [ "$(calls '^tofu apply phase2-')" = 0 ] \
  && ok "phase 2 never planned nor applied" \
  || bad "phase 2 went on: $(grep -E '^tofu (plan -out=phase2-|apply phase2-)' "$W/calls.log" | tr '\n' '|')"
[ "$(calls '^infra-verify.sh ')" = 0 ] && ! grep -q 'cluster-up complete' "$O" \
  && ok "the verifier is not reached and no success line is printed" \
  || bad "the journey went on: $(tail_of)"


echo "--- the image is the one ROLE's tfvars pins ---"
# Only the workload pin differs from the management one, so a build that
# ignored ROLE would take the management image.
run 0 "${UP[@]}" PROVIDER=ovh ROLE=workload; rc=$?
[ "$rc" = 0 ] && grep -qx 'talos-image.sh ovh v0.0.1-fixture --ensure' "$W/calls.log" \
  && ok "a workload cluster builds the workload pin" \
  || bad "exit $rc; the build was: $(grep '^talos-image' "$W/calls.log")"
# VERSION is not a cluster-up option, and a name that generic is often exported
# for something else: neither form may steer the image.
for how in env cli; do
  if [ "$how" = env ]; then EXTRA=VERSION=v9.9.9 run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
  else run 0 "${UP[@]}" PROVIDER=scaleway VERSION=v9.9.9; rc=$?; fi
  [ "$rc" = 0 ] && grep -qx 'talos-image.sh scaleway v0.0.0-fixture --ensure' "$W/calls.log" \
    && ok "VERSION given as $how is ignored: the pin is built" \
    || bad "VERSION as $how, exit $rc; the build was: $(grep '^talos-image' "$W/calls.log")"
done


echo "--- a bad passphrase is refused before the buckets are created ---"
# ensure-buckets creates the buckets and the image build follows: neither may have run.
run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
# (infra-apply calls it again later, so the control counts the --preflight call.)
[ "$rc" = 0 ] && [ "$(calls '^ensure-buckets.sh .*--preflight$')" = 1 ] \
  && ok "control: a good passphrase reaches the preflight ensure-buckets once" \
  || bad "control, exit $rc, preflight calls $(calls '^ensure-buckets.sh .*--preflight$'): $(tail_of)"
for c in "|is not set" "change-me-fixture-passphrase|is still the example"; do
  EXTRA="TF_VAR_encryption_passphrase=${c%%|*}" run 0 "${UP[@]}" PROVIDER=scaleway; rc=$?
  # Anchored: go-task echoes the whole script into $O, so an unanchored match is always true.
  [ "$rc" != 0 ] && grep -q "^✗ TF_VAR_encryption_passphrase ${c#*|}" "$O" \
    && [ "$(calls '^ensure-buckets.sh ')" = 0 ] && [ "$(calls '^talos-image.sh ')" = 0 ] \
    && ok "passphrase '${c%%|*}': refused, nothing built" \
    || bad "passphrase '${c%%|*}', exit $rc, ensure-buckets $(calls '^ensure-buckets.sh '), image $(calls '^talos-image.sh '): $(tail_of)"
done


echo "--- cluster-verify on its own still refreshes kubeconfig ---"
run 0 cluster-verify PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && [ "$(calls '^tofu output -raw kubeconfig')" = 1 ] && [ "$(calls '^infra-verify.sh ')" = 1 ] \
  && ok "one refresh, then the verifier — a cold shell still verifies" \
  || bad "exit $rc, refreshes $(calls '^tofu output -raw kubeconfig'), verifier $(calls '^infra-verify.sh ')"


echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
