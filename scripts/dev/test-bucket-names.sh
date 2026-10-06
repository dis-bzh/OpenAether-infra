#!/usr/bin/env bash
# Seven places build a bucket name. They must agree, or the backend points at a
# bucket nothing created and the apply dies after the network exists.
#
# The derivations live in two languages that cannot import each other:
#   shell  — oa_project / oa_state_bucket / oa_artifact_bucket / oa_backup_bucket
#            (lib/common.sh), used by tf-backend.sh, ensure-buckets.sh,
#            infra-verify.sh, restore-artifacts.sh, talos-image.sh and
#            seed-openbao.sh, all of which run BEFORE or AROUND OpenTofu;
#   HCL    — local.backup_project in cluster/backup.tf, which names the same
#            buckets from inside the apply.
# Nothing but this file compares them.
#
# Why the suffix exists at all: S3 bucket names are unique across a whole
# provider (Scaleway "in our whole platform", OVH "within OVHcloud", Outscale per
# region), so the hardcoded names were unusable by any second account.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
oa_require_fn oa_state_bucket oa_artifact_bucket oa_backup_bucket oa_project || exit 1

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
eq()  { [ "$2" = "$3" ] && ok "$1 → $2" || bad "$1 → got '$2', want '$3'"; }

echo "=== oa_project: the namespace, with and without a suffix ==="
eq "no suffix"              "$(oa_project example)"            "example"
eq "empty suffix"           "$(oa_project example '')"         "example"
eq "suffix appended"        "$(oa_project example a1b2c3)"     "example-a1b2c3"
# cluster_name's FIRST segment only — this is why `workload-scaleway` and
# `management-scaleway` share a state bucket, and why a hyphenated name does not
# silently create a second one.
eq "first segment only"     "$(oa_project example-scaleway)"   "example"
eq "first segment + suffix" "$(oa_project example-scaleway z9)" "example-z9"

echo "=== the full bucket names ==="
eq "state, no suffix"    "$(oa_state_bucket "$(oa_project example)" scaleway dev)"        "s3-example-scaleway-tfstate-dev"
eq "state, suffix"       "$(oa_state_bucket "$(oa_project example a1b2c3)" scaleway dev)" "s3-example-a1b2c3-scaleway-tfstate-dev"
eq "artifact, suffix"    "$(oa_artifact_bucket "$(oa_project example a1b2c3)" ovh management prod)" "s3-example-a1b2c3-ovh-management-prod"
eq "backups, suffix"     "$(oa_backup_bucket "$(oa_project example a1b2c3)" outscale prod)" "s3-example-a1b2c3-outscale-backups-prod"

echo "=== HCL and shell derive the SAME namespace ==="
# `join("-", compact([...]))` in backup.tf against oa_project here. Reproduced
# rather than executed: running tofu needs a backend and credentials, and this
# file must stay in the credential-free rung.
hcl_project() { # <cluster_name> <bucket_suffix> — mirrors local.backup_project
  local first="${1%%-*}"
  if [ -n "$2" ]; then printf '%s-%s' "$first" "$2"; else printf '%s' "$first"; fi
}
for cn in example example-scaleway my-cluster; do
  for sfx in "" a1b2c3; do
    s="$(oa_project "$cn" "$sfx")"; h="$(hcl_project "$cn" "$sfx")"
    [ "$s" = "$h" ] && ok "cluster_name='${cn}' suffix='${sfx:-<none>}' → both say ${s}" \
      || bad "cluster_name='${cn}' suffix='${sfx:-<none>}': shell says '${s}', HCL says '${h}'"
  done
done

echo "=== backup.tf still derives it the way this file assumes ==="
# The mirror above is only worth anything while the HCL it mirrors is unchanged.
# If someone rewrites local.backup_project, this fails and sends them here.
BT="$ROOT/infrastructure/opentofu/cluster/backup.tf"
if grep -qF 'backup_project        = join("-", compact([split("-", var.cluster_name)[0], var.bucket_suffix]))' "$BT"; then
  ok "backup.tf:local.backup_project is the expression mirrored above"
else
  bad "backup.tf:local.backup_project changed — update hcl_project() here, then re-check every caller"
fi
if grep -qF 'backup_data_bucket = "${local.backup_bucket_prefix}-backups-${var.environment}"' "$BT"; then
  ok "backup.tf:local.backup_data_bucket is <prefix>-backups-<env>, what oa_backup_bucket() prints"
else
  bad "backup.tf:local.backup_data_bucket changed — oa_backup_bucket() and seed-openbao.sh now name a different bucket"
fi

echo "=== every name is legal on all three providers ==="
# 3-63 characters, lowercase alphanumerics and hyphens, no leading or trailing
# hyphen, no double hyphen (OVH: "must not contain multiple punctuation marks in
# a row"). A leading hyphen in cluster_name would make the project empty and
# yield `s3--scaleway-…`, which OVH rejects.
for name in \
  "$(oa_state_bucket "$(oa_project example a1b2c3)" scaleway dev)" \
  "$(oa_artifact_bucket "$(oa_project example a1b2c3)" outscale management prod)-backup"; do
  if [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{1,61})[a-z0-9]$ ]] && [[ ! "$name" =~ -- ]]; then
    ok "${name} is a legal bucket name (${#name} chars)"
  else
    bad "${name} is not a legal bucket name on at least one provider"
  fi
done

echo "=== the variable's own validation matches what the helper accepts ==="
VARS="$ROOT/infrastructure/opentofu/cluster/variables.tf"
if grep -qE 'regex\("\^\[a-z0-9\]\{0,16\}\$"' "$VARS"; then
  ok "bucket_suffix is validated as 0-16 lowercase alphanumerics"
else
  bad "bucket_suffix has no validation, or it no longer matches — an illegal suffix would reach a bucket name"
fi

echo

echo "=== the restore path derives the SAME name as everything else ==="
# Not a grep of the source: this RUNS restore-artifacts.sh with a stub aws and
# reads the bucket it announces. The previous harness checked the replica branch
# by grepping the file, and could not see that this was the only one of five
# oa_project callers dropping the suffix — so a cluster with a bucket_suffix got
# "not found" for a backup that was sitting there.
SB="$(mktemp -d)"; SUF=a1b2c3
printf '#!/usr/bin/env bash\nexit 9\n' >"$SB/aws"; chmod +x "$SB/aws"
# Both scripts read the fixture from a sandbox envs dir, never the operator's.
mkdir "$SB/envs"; FIX="$SB/envs/oatest-scaleway.tfvars"; export OA_ENVS_DIR="$SB/envs"
trap 'rm -rf "$SB"' EXIT
sed -E "s/^bucket_suffix.*//" infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example >"$FIX"
printf '\nbucket_suffix = "%s"\n' "$SUF" >>"$FIX"
CNAME="$(grep -E '^cluster_name' "$FIX" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
ENVV="$(grep -E '^environment' "$FIX" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
# --role picks the FILE (oatest-scaleway.tfvars); the bucket's role segment is the file's cluster_role,
# as backup.tf and ensure-buckets.sh read it. The fixture declares "management", the file prefix does not.
CROLE="$(grep -E '^cluster_role' "$FIX" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
[ "$CROLE" = management ] && ok "the fixture declares cluster_role management" || bad "fixture cluster_role is '$CROLE'"
WANT="$(oa_artifact_bucket "$(oa_project "$CNAME" "$SUF")" scaleway "$CROLE" "$ENVV")-backup"

for kind in primary replica; do
  want="$WANT"; [ "$kind" = primary ] && want="${WANT%-backup}"
  got="$(PATH="$SB:$PATH" TF_VAR_encryption_passphrase=x SCW_AWS_ACCESS_KEY_ID=k SCW_AWS_SECRET_ACCESS_KEY=k \
         ./scripts/ops/restore-artifacts.sh scaleway --role oatest --from "$kind" 2>&1 |
         sed -nE 's#.*s3://([a-z0-9-]+)/backups/.*#\1#p' | head -1)"
  eq "restore --from $kind targets the suffixed bucket, named by the file's cluster_role" "$got" "$want"
done

echo "=== the Day-1 seeder names the SAME backups bucket backup.tf publishes ==="
# Same shape: RUN seed-openbao.sh against a stub kubectl (every path reads as
# already set, so nothing is written) and read the bucket it announces. It was
# the seventh place building the name and the only one dropping the suffix, so
# restic and Loki were seeded with a bucket backup.tf never created (#166).
cat >"$SB/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in "get secret openbao-recovery"*) printf 'stub-token' | base64 ;; "exec "*" secrets list") printf 'secret/\n' ;; esac
exit 0
STUB
chmod +x "$SB/kubectl"; printf 'apiVersion: v1\n' >"$SB/kubeconfig"
WANT_SEED="$(oa_backup_bucket "$(oa_project "$CNAME" "$SUF")" scaleway "$ENVV")"
got="$(PATH="$SB:$PATH" KUBECONFIG="$SB/kubeconfig" OPENBAO_WAIT=0 SCW_AWS_ACCESS_KEY_ID=k SCW_AWS_SECRET_ACCESS_KEY=k \
       ./scripts/ops/seed-openbao.sh scaleway oatest 2>&1 | sed -nE 's/.*bucket ([a-z0-9-]+)\).*/\1/p' | head -1)"
eq "seed-openbao announces the suffixed backups bucket" "$got" "$WANT_SEED"


echo "--- the state lock is claimed only where the store honours it ---"
# use_lockfile locks by PUTting a .tflock with `If-None-Match: *`. MEASURED with
# one client against all three stores on 2026-08-20: Scaleway and OVH refuse the
# second write, Outscale ACCEPTS it. Claiming a lock there would print
# "Acquiring state lock" and hold nothing, which is worse than none — so this
# asserts the asymmetry rather than trusting it to stay true by accident.
# Keyed on the endpoint, because a Proxmox cluster's state lives elsewhere.
# The shipped examples, not the operator's gitignored tfvars: those decided the
# verdict locally, and in CI, where they do not exist, nothing was asserted.
EX=infrastructure/opentofu/cluster/envs/management
lock_of() { # <tfvars> → yes|no|error: a crashed tf-backend.sh must not read as "no"
  local out; out="$(scripts/internal/tf-backend.sh "$1" 2>/dev/null)" || { echo error; return; }
  case "$out" in *-backend-config=bucket=*) ;; *) echo error; return ;; esac
  case "$out" in *use_lockfile=true*) echo yes ;; *) echo no ;; esac
}
for pair in "scaleway:yes" "ovh:yes" "outscale:no"; do
  prov="${pair%%:*}"; want="${pair##*:}"
  eq "${prov}: state lock claimed = ${want}" "$(lock_of "$EX-${prov}.tfvars.example")" "$want"
done

# And the reason it is keyed on the endpoint, not the provider name.
got="$(lock_of "$EX-proxmox.tfvars.example")"
case "$(grep -E '^s3_primary_endpoint' "$EX-proxmox.tfvars.example")" in
  *scw.cloud*|*io.cloud.ovh.net*) eq "proxmox on a locking store claims the lock" "$got" "yes" ;;
  *outscale.com*)                 eq "proxmox on Outscale claims no lock"        "$got" "no"  ;;
  *) bad "the proxmox example's endpoint is none of the three — nothing asserted" ;;
esac


echo "--- one data directory per cluster, so two providers cannot collide ---"
# .terraform/ holds the CURRENT backend, so with one shared source directory the
# target that inited last owned it, and a second run applied one cloud's plan
# against another's pointer. Survived twice by luck. Every task that talks to a
# backend must therefore carry its own TF_DATA_DIR, keyed on the pair that
# selects the tfvars — and must declare ROLE, or the key collapses to
# `.terraform--<provider>` and two roles share a directory again.
OUT_TDD="$(python3 - <<'PY2'
import yaml, re
raw = open('Taskfile.yml').read()
t = yaml.safe_load(raw)['tasks']
blocks = re.split(r'\n  (?=[a-z_][a-z0-9_-]*:\n)', raw)
bad = []
for b in blocks:
    name = b.split(':', 1)[0].strip()
    has_env = '*provider-env' in b or '&provider-env' in b
    # A backend init without the anchor is how restore-state could have shipped with no data dir and no S3 keys.
    if not has_env and any('tofu init -reconfigure' in l for l in b.splitlines() if not l.lstrip().startswith('#')):
        bad.append(f'{name}: runs tofu init -reconfigure without *provider-env (no TF_DATA_DIR, no S3 keys)')
        continue
    if not has_env:
        continue
    spec = t.get(name) or {}
    env = spec.get('env') or {}
    tdd = env.get('TF_DATA_DIR')
    if not tdd:
        bad.append(f'{name}: no TF_DATA_DIR')
        continue
    if '{{.ROLE}}' not in tdd or '{{.PROVIDER}}' not in tdd:
        bad.append(f'{name}: TF_DATA_DIR={tdd} is not keyed on ROLE and PROVIDER')
    if 'ROLE' not in (spec.get('vars') or {}) and 'ROLE' not in [v for v in (spec.get('requires') or {}).get('vars', [])]:
        bad.append(f'{name}: inherits the data dir but declares no ROLE')
print('\n'.join(bad))
PY2
)"
if [ -z "$OUT_TDD" ]; then
  ok "every backend-touching task has its own TF_DATA_DIR, keyed on ROLE and PROVIDER"
else
  while IFS= read -r l; do bad "$l"; done <<<"$OUT_TDD"
fi


printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
