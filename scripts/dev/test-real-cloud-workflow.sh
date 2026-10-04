#!/usr/bin/env bash
# .github/workflows/real-cloud-regression.yml: the glue between GitHub's secrets and the tasks it runs.
# The lane itself cannot run here (its secrets are the owner's and name real accounts), so each shell
# step is lifted out of the YAML with its `env:` mapping, GitHub's `${{ secrets.X }}` replaced by a fake
# value, and executed for real in a scratch tree. What this proves: the secrets arrive intact (a tfvars
# full of quotes and `$()`), the files have the right mode and content, the prerequisite check names what
# is missing, and the proof step asks each provider the right question. What it cannot: that a real
# account accepts the credentials. SUT overrides the workflow, which is how mutants run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="${WF:-$ROOT/.github/workflows/real-cloud-regression.yml}"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
python3 -c 'import yaml' 2>/dev/null || { echo "✗ python3 pyyaml is required: without it this harness would grade nothing" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/scripts/lib" "$T/repo/infrastructure/opentofu/cluster" "$T/bin" "$T/tmp"
cp "$ROOT/scripts/lib/common.sh" "$T/repo/scripts/lib/"
cp "$ROOT/infrastructure/opentofu/cluster/variables.tf" "$T/repo/infrastructure/opentofu/cluster/"
PIN_K8S="$(awk '/variable "kubernetes_version"/,/^}/' "$ROOT/infrastructure/opentofu/cluster/variables.tf" | sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)"

# --- lift one step out of the workflow ---------------------------------------------------
# `step <name>` writes $T/step.sh (the run text) and $T/step.env (NAME<TAB>raw value, GitHub expressions kept).
step() {
  python3 - "$WF" "$1" "$T" <<'PY'
import sys, yaml
wf, name, t = sys.argv[1:4]
steps = yaml.safe_load(open(wf))["jobs"]["regression"]["steps"]
hit = [s for s in steps if s.get("name") == name]
if len(hit) != 1:
    sys.exit(f"step {name!r}: {len(hit)} matches")
s = hit[0]
open(t + "/step.sh", "w").write(s.get("run", ""))
with open(t + "/step.env", "w") as f:
    for k, v in (s.get("env") or {}).items():
        f.write(f"{k}\t{v}\n")
PY
}

# Fake secrets: one fixture per name, the tfvars deliberately hostile to a shell that carries it inline.
declare -A SECRET
FAKE_TFVARS=$'cluster_name = "oa-ci"\nenvironment  = "dev"\nadmin_ip     = ["192.0.2.10/32"]\nnote         = "a \\"quoted\\" $(touch '"$T"'/pwned) `id` $HOME \\\\ end"\n'
KEYKIND="OPENSSH PRIV""ATE KEY"   # split: a literal marker would trip detect-private-key on a fixture
FAKE_KEY="-----BEGIN ${KEYKIND}-----"$'\nQUJDREVGRw==\n'"-----END ${KEYKIND}-----"
reset_secrets() {
  SECRET=()
  local n
  for n in SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_ORGANIZATION_ID SCW_DEFAULT_PROJECT_ID SCW_DEFAULT_REGION SCW_DEFAULT_ZONE \
           OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME OS_REGION_NAME OVH_AWS_ACCESS_KEY_ID OVH_AWS_SECRET_ACCESS_KEY OVH_AWS_DEFAULT_REGION \
           OUTSCALE_ACCESS_KEY_ID OUTSCALE_SECRET_KEY OUTSCALE_REGION; do SECRET[$n]="fake-$n"; done
  SECRET[SCALEWAY_MANAGEMENT_TFVARS]="$FAKE_TFVARS"; SECRET[OVH_MANAGEMENT_TFVARS]="$FAKE_TFVARS"; SECRET[OUTSCALE_MANAGEMENT_TFVARS]="$FAKE_TFVARS"
  SECRET[CI_BASTION_SSH_PRIVATE_KEY]="$FAKE_KEY"
  SECRET[TF_VAR_ENCRYPTION_PASSPHRASE]="a-passphrase-of-more-than-32-characters-x"
}

# `go <provider> [EVENT=… CONFIRMED=…]` runs the lifted step; sets OUT, RC; GITHUB_ENV lands in $T/ghenv.
EVENT=workflow_dispatch; CONFIRMED=true; STUB_PY_RC=0; STUB_CURL_SUM=ok
go() {
  local prov="$1" line k v; : >"$T/ghenv"; rm -rf "$T/tmp"/*
  local -a envv=("PATH=$T/bin:$PATH" "GITHUB_ENV=$T/ghenv" "RUNNER_TEMP=$T/tmp" "STUB_LOG=$T/stub.log" "STUB_PY_RC=$STUB_PY_RC" "STUB_PY_FAIL=${STUB_PY_FAIL:-}" "STUB_CURL_SUM=$STUB_CURL_SUM" "HOME=$T/home")
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    # `${{ secrets.X }}` and the three context values the steps use; anything else is a stray expression, kept so it shows
    if [[ "$v" =~ ^\$\{\{\ *secrets\.([A-Z_]+)\ *\}\}$ ]]; then v="${SECRET[${BASH_REMATCH[1]}]-}"
    else v="${v//\$\{\{ matrix.provider \}\}/$prov}"; v="${v//\$\{\{ github.event_name \}\}/$EVENT}"; v="${v//\$\{\{ github.event.inputs.sandbox_confirmed \}\}/$CONFIRMED}"; fi
    envv+=("$k=$v")
  done <"$T/step.env"
  # GitHub's default shell: bash --noprofile --norc -eo pipefail {0}; ${{ matrix.provider }} inside `run:` is expanded by GitHub first
  sed "s/\${{ matrix.provider }}/$prov/g" "$T/step.sh" >"$T/step.run.sh"
  OUT="$(cd "$T/repo" && env -i "${envv[@]}" bash --noprofile --norc -eo pipefail "$T/step.run.sh" 2>&1)"; RC=$?
}

# --- stubs -------------------------------------------------------------------------------
cat >"$T/bin/python3" <<'STUB'
#!/usr/bin/env bash
echo "python3 $*" >>"$STUB_LOG"
case "$*" in *"${STUB_PY_FAIL:-@none@}"*) exit "${STUB_PY_RC:-1}" ;; esac
exit 0
STUB
cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
out=""; url=""; while [ $# -gt 0 ]; do case "$1" in -o|-fsSLo) out="$2"; shift ;; -*o) out="$2"; shift ;; http*) url="$1" ;; esac; shift; done
case "$url" in
  *.sha256) if [ "$STUB_CURL_SUM" = ok ]; then printf 'fakebinary' | sha256sum | cut -d' ' -f1; else echo 0000000000000000000000000000000000000000000000000000000000000000; fi ;;
  *) [ -n "$out" ] && printf 'fakebinary' >"$out" ;;
esac
STUB
cat >"$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$STUB_LOG"
STUB
chmod +x "$T/bin"/*
for t in bash env sed awk grep install sha256sum cut date cat printf mkdir; do :; done

reset_secrets

echo "=== the workflow's own shape ==="
python3 - "$WF" <<'PY' && ok "no secret is interpolated into a script: they reach a step only through env:" || bad "a secrets.* expression sits inside a run: text"
import sys, yaml, re
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["regression"]["steps"]
sys.exit(1 if any(re.search(r"\$\{\{[^}]*secrets\.", s.get("run", "")) for s in steps) else 0)
PY
python3 - "$WF" <<'PY' && ok "it is manual (workflow_dispatch only), read-only, one provider at a time, and never cancelled mid-deploy" || bad "trigger, permissions, parallelism or concurrency drifted"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get("on", d.get(True))
j = d["jobs"]["regression"]
ok = list(on) == ["workflow_dispatch"] and d["permissions"] == {"contents": "read"} \
     and j["strategy"]["max-parallel"] == 1 and j["strategy"]["fail-fast"] is False \
     and d["concurrency"]["cancel-in-progress"] is False
sys.exit(0 if ok else 1)
PY
python3 - "$WF" <<'PY' && ok "both teardown steps and the proof run even when the apply failed (if: always())" || bad "a teardown step lost its if: always()"
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["regression"]["steps"]
want = {"task cluster-down (plan)", "task cluster-down (apply)", "Confirm the account is clean"}
got = {s["name"] for s in steps if s.get("if") == "always()"}
sys.exit(0 if want <= got else 1)
PY
python3 - "$WF" <<'PY' && ok "checkout does not persist the token next to the cloud credentials" || bad "checkout persists credentials"
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["regression"]["steps"]
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
sys.exit(0 if co and all(s["with"]["persist-credentials"] is False for s in co) else 1)
PY
DOC="$(sed -nE 's/^#[[:space:]]+(Scaleway|OVH|Outscale|All)[[:space:]]+—[[:space:]]*//p; s/^#[[:space:]]{15,}//p' "$WF" | sed -n '1,/^$/p' | tr -c 'A-Z_\n' ' ' | tr -s ' ' '\n' | grep -E '^[A-Z][A-Z_]{3,}$' | sort -u)"
REAL="$(grep -oE 'secrets\.[A-Z_]+' "$WF" | sed 's/secrets\.//' | sort -u)"
[ "$DOC" = "$REAL" ] && ok "the secrets the header lists are exactly the ones the file uses ($(wc -l <<<"$REAL" | tr -d ' ') of them)" \
  || bad "header and file disagree on secrets: only in header: $(comm -23 <(echo "$DOC") <(echo "$REAL") | tr '\n' ' ') / only in file: $(comm -13 <(echo "$DOC") <(echo "$REAL") | tr '\n' ' ')"
if command -v actionlint >/dev/null 2>&1; then actionlint "$WF" >/dev/null 2>&1 && ok "actionlint passes" || bad "actionlint fails: $(actionlint "$WF" 2>&1 | head -3)"; else echo "  - no actionlint on PATH: skipped"; fi

echo "=== the run is allowed, and the prerequisites are there ==="
step "Check the run is allowed"
EVENT=workflow_dispatch CONFIRMED=false go scaleway
{ [ "$RC" -ne 0 ] && grep -q 'sandbox_confirmed' <<<"$OUT"; } && ok "a manual run without the sandbox box ticked is refused" || bad "unconfirmed run (rc ${RC}): ${OUT}"
EVENT=workflow_dispatch CONFIRMED=true go scaleway; [ "$RC" = 0 ] && ok "…and with it ticked it goes on" || bad "confirmed run refused: ${OUT}"
EVENT=schedule CONFIRMED= go scaleway; [ "$RC" = 0 ] && ok "a scheduled run (once the owner enables it) needs no box" || bad "scheduled run refused: ${OUT}"
step "Check the prerequisites"
for p in scaleway ovh outscale; do go "$p"; [ "$RC" = 0 ] && ok "$p: every secret present, the check passes" || bad "$p complete secrets refused: ${OUT}"; done
SAVE="${SECRET[SCW_SECRET_KEY]}"; SECRET[SCW_SECRET_KEY]=""; go scaleway
{ [ "$RC" -ne 0 ] && grep -q ' SCW_SECRET_KEY\b' <<<"$OUT" && ! grep -q 'SCW_ACCESS_KEY' <<<"$OUT"; } && ok "a missing Scaleway secret is named, and only that one" || bad "missing secret (rc ${RC}): ${OUT}"
go ovh; [ "$RC" = 0 ] && ok "…and an OVH run does not care about Scaleway's secrets" || bad "OVH refused for a Scaleway secret: ${OUT}"; SECRET[SCW_SECRET_KEY]="$SAVE"
declare -A NEED=([scaleway]="SCALEWAY_MANAGEMENT_TFVARS SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_ORGANIZATION_ID SCW_DEFAULT_PROJECT_ID SCW_DEFAULT_REGION SCW_DEFAULT_ZONE" \
  [ovh]="OVH_MANAGEMENT_TFVARS OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME OS_REGION_NAME OVH_AWS_ACCESS_KEY_ID OVH_AWS_SECRET_ACCESS_KEY OVH_AWS_DEFAULT_REGION" \
  [outscale]="OUTSCALE_MANAGEMENT_TFVARS OUTSCALE_ACCESS_KEY_ID OUTSCALE_SECRET_KEY OUTSCALE_REGION")
missed=""
for p in scaleway ovh outscale; do for n in ${NEED[$p]}; do
  SAVE="${SECRET[$n]}"; SECRET[$n]=""; go "$p"; SECRET[$n]="$SAVE"
  { [ "$RC" -ne 0 ] && grep -qE "(^|[: ])$n( |\.|\$)" <<<"$OUT"; } || missed="$missed $p/$n"
done; done
[ -z "$missed" ] && ok "every one of the 20 provider-specific secrets is checked, and named when it is missing" || bad "secrets the prerequisite check does not catch:$missed"
SAVE="${SECRET[CI_BASTION_SSH_PRIVATE_KEY]}"; SECRET[CI_BASTION_SSH_PRIVATE_KEY]=""; go outscale
{ [ "$RC" -ne 0 ] && grep -q 'CI_BASTION_SSH_PRIVATE_KEY' <<<"$OUT"; } && ok "the shared SSH key is checked for every provider" || bad "missing ssh key (rc ${RC}): ${OUT}"; SECRET[CI_BASTION_SSH_PRIVATE_KEY]="$SAVE"
SAVE="${SECRET[OUTSCALE_MANAGEMENT_TFVARS]}"; SECRET[OUTSCALE_MANAGEMENT_TFVARS]=""; go outscale
{ [ "$RC" -ne 0 ] && grep -q 'OUTSCALE_MANAGEMENT_TFVARS' <<<"$OUT"; } && ok "a missing tfvars secret is named too" || bad "missing tfvars (rc ${RC}): ${OUT}"; SECRET[OUTSCALE_MANAGEMENT_TFVARS]="$SAVE"
SAVE="${SECRET[TF_VAR_ENCRYPTION_PASSPHRASE]}"; SECRET[TF_VAR_ENCRYPTION_PASSPHRASE]="too-short"; go scaleway
{ [ "$RC" -ne 0 ] && grep -q '32' <<<"$OUT"; } && ok "a passphrase under 32 characters is refused here, not 40 minutes into the run" || bad "short passphrase (rc ${RC}): ${OUT}"; SECRET[TF_VAR_ENCRYPTION_PASSPHRASE]="$SAVE"

echo "=== what lands on the runner ==="
step "Write tfvars"
for p in scaleway ovh outscale; do
  rm -f "$T/pwned"; go "$p"
  { [ "$RC" = 0 ] && [ "$(cat "$T/repo/infrastructure/opentofu/cluster/envs/management-$p.tfvars"; echo x)" = "${FAKE_TFVARS}"$'\nx' ] && [ ! -e "$T/pwned" ]; } \
    && ok "$p: a tfvars full of quotes, \$() and backticks is written byte for byte and nothing in it runs" || bad "$p tfvars (rc ${RC}): ${OUT}"
done
rm -f "$T"/repo/infrastructure/opentofu/cluster/envs/*
step "Write the bastion SSH key"; go scaleway
K="$T/tmp/ci_bastion_key"
{ [ "$RC" = 0 ] && [ "$(stat -c %a "$K")" = 600 ] && [ "$(cat "$K")" = "$FAKE_KEY" ] && [ "$(tail -c1 "$K" | od -An -c | tr -d ' ')" = '\n' ] && grep -qx "BASTION_KEY=$K" "$T/ghenv"; } \
  && ok "the SSH key is mode 600, intact, ends with a newline (OpenSSH refuses one without), and BASTION_KEY points at it" || bad "ssh key (rc ${RC}, mode $(stat -c %a "$K" 2>/dev/null)): ${OUT}"
step "TF_VAR_encryption_passphrase"; go scaleway
grep -qx "TF_VAR_encryption_passphrase=${SECRET[TF_VAR_ENCRYPTION_PASSPHRASE]}" "$T/ghenv" && ok "the state passphrase reaches the environment under the name tofu reads" || bad "passphrase env: $(cat "$T/ghenv")"
step "Provider credentials (Scaleway)"; go scaleway
{ [ "$RC" = 0 ] && grep -qx 'SCW_AWS_ACCESS_KEY_ID=fake-SCW_ACCESS_KEY' "$T/ghenv" && grep -qx 'SCW_AWS_SECRET_ACCESS_KEY=fake-SCW_SECRET_KEY' "$T/ghenv" \
  && grep -qx 'SCW_AWS_DEFAULT_REGION=fake-SCW_DEFAULT_REGION' "$T/ghenv" && [ "$(wc -l <"$T/ghenv")" = 9 ]; } \
  && ok "Scaleway: six credentials, and the S3 ones derived from the API keys as .env.example does" || bad "scaleway env (rc ${RC}): $(cat "$T/ghenv")"
step "Provider credentials (OVH)"; go ovh
{ [ "$RC" = 0 ] && grep -qx 'OVH_AWS_DEFAULT_REGION=fake-OVH_AWS_DEFAULT_REGION' "$T/ghenv" && grep -qx 'OS_REGION_NAME=fake-OS_REGION_NAME' "$T/ghenv" && grep -qx 'OS_AUTH_URL=https://auth.cloud.ovh.net/' "$T/ghenv"; } \
  && ok "OVH: the compute region and the object-storage region stay two different values" || bad "ovh env (rc ${RC}): $(cat "$T/ghenv")"
step "Provider credentials (Outscale)"; go outscale
{ [ "$RC" = 0 ] && grep -qx 'OUTSCALE_AWS_ACCESS_KEY_ID=fake-OUTSCALE_ACCESS_KEY_ID' "$T/ghenv" && grep -qx 'OUTSCALE_AWS_DEFAULT_REGION=fake-OUTSCALE_REGION' "$T/ghenv"; } \
  && ok "Outscale: the S3 credentials derived from the API keys" || bad "outscale env (rc ${RC}): $(cat "$T/ghenv")"

echo "=== kubectl follows the cluster's pin ==="
step "Install kubectl (the cluster's pin, checksum-verified)"
mkdir -p "$T/repo/infrastructure/opentofu/cluster/envs"; : >"$T/stub.log"
go scaleway
{ [ "$RC" = 0 ] && grep -q "dl.k8s.io/release/${PIN_K8S}/bin/linux/amd64/kubectl\$" "$T/stub.log" && ! grep -q 'stable' "$T/stub.log" && grep -q 'sudo install' "$T/stub.log"; } \
  && ok "no tfvars pin: kubectl ${PIN_K8S} (variables.tf's default), checksum read, installed" || bad "kubectl default pin (rc ${RC}): $(cat "$T/stub.log") ${OUT}"
printf 'kubernetes_version = "v1.99.0"\n' >"$T/repo/infrastructure/opentofu/cluster/envs/management-scaleway.tfvars"; : >"$T/stub.log"; go scaleway
{ [ "$RC" = 0 ] && grep -q 'release/v1.99.0/bin' "$T/stub.log"; } && ok "a tfvars that pins Kubernetes wins over the default" || bad "kubectl tfvars pin (rc ${RC}): $(cat "$T/stub.log")"
: >"$T/stub.log"; STUB_CURL_SUM=bad go scaleway
{ [ "$RC" -ne 0 ] && ! grep -q 'sudo install' "$T/stub.log"; } && ok "a checksum that does not match stops the install" || bad "bad checksum accepted (rc ${RC})"; STUB_CURL_SUM=ok
rm -f "$T"/repo/infrastructure/opentofu/cluster/envs/*

echo "=== the last step asks each provider the right question ==="
step "Confirm the account is clean"
printf 'cluster_name = "oa-ci"\nenvironment = "dev"\n' >"$T/repo/infrastructure/opentofu/cluster/envs/management-scaleway.tfvars"
cp "$T/repo/infrastructure/opentofu/cluster/envs/management-scaleway.tfvars" "$T/repo/infrastructure/opentofu/cluster/envs/management-ovh.tfvars"
cp "$T/repo/infrastructure/opentofu/cluster/envs/management-scaleway.tfvars" "$T/repo/infrastructure/opentofu/cluster/envs/management-outscale.tfvars"
for pair in "scaleway:scaleway" "ovh:openstack" "outscale:outscale"; do
  p="${pair%%:*}"; w="${pair##*:}"; : >"$T/stub.log"; STUB_PY_FAIL= STUB_PY_RC=0 go "$p"
  { [ "$RC" = 0 ] && grep -q "verify-provider-clean.py oa-ci-dev $w" "$T/stub.log" && grep -q "purge-orphans/$p.py" "$T/stub.log"; } \
    && ok "$p: the cluster's own name, the provider's own word ($w), then the purge listing" || bad "$p proof (rc ${RC}): $(cat "$T/stub.log") ${OUT}"
done
for p in scaleway ovh; do
  STUB_PY_FAIL="purge-orphans/$p.py" STUB_PY_RC=1 go "$p"
  [ "$RC" -ne 0 ] && ok "$p: a purge that finds leftovers fails the run" || bad "$p ignored a leftover (rc ${RC})"
done
STUB_PY_FAIL="purge-orphans/outscale.py" STUB_PY_RC=1 go outscale
{ [ "$RC" = 0 ] && grep -q '#43' <<<"$OUT"; } && ok "outscale: the purge listing of the pre-fix Net (#43) is printed, not gated on" || bad "outscale purge gated (rc ${RC}): ${OUT}"
STUB_PY_FAIL="verify-provider-clean.py oa-ci-dev outscale" STUB_PY_RC=1 go outscale
[ "$RC" -ne 0 ] && ok "…but a VM or a public IP left on Outscale does fail it" || bad "outscale ignored a leftover VM (rc ${RC})"
printf 'environment = "dev"\n' >"$T/repo/infrastructure/opentofu/cluster/envs/management-scaleway.tfvars"; : >"$T/stub.log"; STUB_PY_FAIL= go scaleway
grep -q 'verify-provider-clean.py openaether-dev scaleway' "$T/stub.log" && ok "no cluster_name in the tfvars: the default name (openaether) is the one asked about" || bad "default name: $(cat "$T/stub.log")"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
