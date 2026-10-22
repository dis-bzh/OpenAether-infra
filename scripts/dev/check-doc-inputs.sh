#!/usr/bin/env bash
# Every input the operator MUST supply has to be named where they will look, and
# present in the example they are told to copy.
#
# The rule this enforces is the release criterion itself: deploy, idempotency,
# upgrade and backup must work by FOLLOWING THE DOCUMENTATION, without
# correction. A required variable that no document mentions is a deploy that
# fails on a stranger's first attempt and works on ours, which is the same shape
# as every false-green this repository keeps meeting — it passes for us because
# we already know the answer.
#
# Source of truth is the CODE: a variable in cluster/variables.tf with no
# `default` is required, by definition, and nothing else is. Documentation is
# what gets checked against it, never the other way round.
#
# Usage: check-doc-inputs.sh
#   STRICT_EXAMPLES=0  skip the "the example carries every required field" check
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VARS="$ROOT/infrastructure/opentofu/cluster/variables.tf"
ENVS="$ROOT/infrastructure/opentofu/cluster/envs"

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

[ -r "$VARS" ] || { echo "✗ no $VARS" >&2; exit 1; }

# --- what the code requires ---------------------------------------------------
# A variable block with no `default =` line before its closing brace. awk rather
# than a regex over the whole file: `default` also appears inside descriptions
# and validation messages, and matching those would silently shrink the list —
# which is the failure mode that makes a checker useless.
required() {
  awk '
    /^variable "/ { name = $2; gsub(/"/, "", name); has = 0; depth = 1; next }
    name != "" {
      if ($0 ~ /^[[:space:]]*default[[:space:]]*=/) has = 1
      if ($0 ~ /^\}/) { if (!has) print name; name = ""; }
    }
  ' "$VARS"
}

mapfile -t REQ < <(required)

# Zero floor. An extractor that matches nothing reports a clean run, and a clean
# run that checked nothing is worse than no check at all.
if [ "${#REQ[@]}" -eq 0 ]; then
  echo "✗ extracted ZERO required variables from ${VARS#"$ROOT"/} — the extractor is broken, not the docs" >&2
  exit 1
fi

echo "=== ${#REQ[@]} variable(s) the operator must supply, per the code ==="

# --- are they documented where the operator will look? ------------------------
DOCS=("$ROOT/README.md" "$ROOT/README.fr.md")
while IFS= read -r f; do DOCS+=("$f"); done < <(find "$ROOT/docs" -maxdepth 1 -name '*.md' 2>/dev/null)

GLOB=0
for v in "${REQ[@]}"; do
  if grep -qlF "$v" "${DOCS[@]}" 2>/dev/null; then
    ok "$v — named in the documentation"
  # `s3_primary_*` in a comment does tell the reader the field exists, so it is
  # not the same defect as silence. It is still not enough to act on: it says
  # neither that the value is a URL nor that the replica is meant to live at
  # ANOTHER provider, which is the whole of the backup claim. Reported apart so
  # the strict count stays meaningful and the checker does not cry wolf.
  elif grep -qlE "${v%%_*}_[a-z_]*\*|${v}s?\b" "${DOCS[@]}" 2>/dev/null; then
    printf '  \033[33m~\033[0m %s — named only as a glob, never explained\n' "$v"
    GLOB=$((GLOB + 1))
  else
    bad "$v — REQUIRED by variables.tf and named in no README or docs/*.md"
  fi
done

# --- does the example the operator is told to copy carry them? ----------------
# "cp the .example, then edit" is only true if the example has a line to edit.
if [ "${STRICT_EXAMPLES:-1}" = "1" ]; then
  echo
  echo "=== every management example carries every required field ==="
  shopt -s nullglob
  for ex in "$ENVS"/management-*.tfvars.example; do
    missing=""
    for v in "${REQ[@]}"; do
      grep -qE "^[[:space:]]*${v}[[:space:]]*=" "$ex" || missing+="$v "
    done
    if [ -z "$missing" ]; then
      ok "$(basename "$ex") — complete"
    else
      bad "$(basename "$ex") — missing: $missing"
    fi
  done

  # A copy without these builds an infrastructure-only cluster (lab 15c): the platform switches are set, not left to the default.
  echo
  echo "=== the management and workload examples set deploy_flux (and deploy_app_lb where a cloud LB exists) ==="
  for ex in "$ENVS"/management-*.tfvars.example "$ENVS"/workload-*.tfvars.example; do
    miss=""
    grep -qE '^deploy_flux[[:space:]]*=[[:space:]]*true' "$ex" || miss+="deploy_flux "
    case "$ex" in *proxmox*) ;; *) grep -qE '^deploy_app_lb[[:space:]]*=[[:space:]]*true' "$ex" || miss+="deploy_app_lb " ;; esac
    if [ -z "$miss" ]; then ok "$(basename "$ex") — sets the platform switches"; else bad "$(basename "$ex") — missing: $miss"; fi
  done

  # infra #378: cluster-roll refuses above (workers - 1) x 100% of CPU requested; lab 16 measured 172% on 2 x 4 vCPU workers with the
  # platform, so a 4 vCPU example needs 3 workers, and 4 since the 0.4.0 HA additions (owner decision 2026-10-21: ~0.45 vCPU of margin on 3). Outscale cannot (20 vCPU quota) and says so in its comment instead, and sets the
  # root volume (#376) because the platform does not fit the OMI's own size.
  echo
  echo "=== the Scaleway and OVH examples can be rolled (4 workers), the Outscale ones set the root size ==="
  for ex in "$ENVS"/{management,failover,workload}-{scaleway,ovh}.tfvars.example; do
    w="$(grep -E '^[[:space:]]*workers[[:space:]]*=' "$ex" | head -1 | sed -E 's/^[^=]*=[[:space:]]*([0-9]+).*/\1/')"
    if [ "${w:-0}" -ge 4 ]; then ok "$(basename "$ex") — $w workers"; else bad "$(basename "$ex") — ${w:-no} workers: the full platform measured ~9 vCPU of requests (lab 21), more than 3 workers leave the gate; ship 4 (#378, docs/capacity.md)"; fi
  done
  # 0.4.0 owner rule 2026-10-22: the third grafana-db instance (synchronous replication) adds ~100 m of CPU requests to that arithmetic;
  # the capacity pages must say so, in both languages, instead of keeping the figures from before it.
  for cap in "$ROOT/docs/capacity.md" "$ROOT/docs/capacity.fr.md"; do
    if grep -q 'grafana-db' "$cap" && grep -q '100 m' "$cap"; then ok "$(basename "$cap") — counts the third grafana-db instance (+100 m of CPU requests)"; else bad "$(basename "$cap") — does not account for the third grafana-db instance (+100 m): the 4-worker arithmetic is stale"; fi
  done
  for ex in "$ENVS"/{management,failover,workload}-outscale.tfvars.example; do
    if grep -qE '^outscale_root_volume_size_gb[[:space:]]*=' "$ex"; then ok "$(basename "$ex") — sets outscale_root_volume_size_gb"; else bad "$(basename "$ex") — outscale_root_volume_size_gb is commented out (#376)"; fi
  done
fi

echo
printf '%s passed, %s failed, %s named only as a glob\n' "$PASS" "$FAIL" "$GLOB"
[ "$GLOB" -eq 0 ] || printf '  a glob names a field; it does not tell the reader what to put in it.\n'
[ "$FAIL" -eq 0 ]
