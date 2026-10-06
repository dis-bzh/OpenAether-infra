#!/usr/bin/env bash
# ==============================================================================
# OpenAether — teardown-all: the DEV fast lane. Plan, confirm, destroy and check a whole
# cluster in one command, and REFUSE unless its tfvars say environment = "dev".
# Production keeps the two commands of `task cluster-down`, unchanged.
#
# Every doubt is a refusal, evaluated before any network or state call, and nothing
# overrides one (no flag, no variable, no test seam: the harness runs a copy of the tree):
#   - OA_NO_TEARDOWN_ALL set (even empty), or a .no-teardown-all file at the repo root:
#     a kill switch, whatever the tfvars say;
#   - environment must be exactly "dev", read by tfv_strict, which refuses what tofu might read differently
#     (a duplicate, an indented or nested line, a heredoc, a block comment);
#   - the target's cluster id must be typed: after the plan on a tty, else --confirm up front
#     (the refusal names the format, never the value); CONFIRM exported in the environment is refused;
#   - `all`: every guard of every target passes before any plan runs; confirm with `all`.
# Never: purge-orphans --apply (it targets the WHOLE project), deleting buckets, images or
# keypairs (fleet-down step 3 lists them: they keep billing), or --force-no-edges unless typed.
# The guard trusts the declared environment: a prod cluster deployed as "dev" is not protected.
# fleet-down deletes the CAPI children of the cluster its kubeconfig reaches: this script
# fetches the target's own before each call and ignores the caller's KUBECONFIG.
# A plan is not read-only (it untracks the Talos secrets): stopped() says so on every exit after one.
#
# Exit: 0 destroyed and proven clean; 1 nothing destroyed (refused, aborted, a plan failed);
#       2 usage; 3 a destroy failed partway, or leftovers / a check that could not run;
#       4 destroyed, but no provider-side check exists for it (proxmox).
#
# Usage: teardown-all.sh <scaleway|ovh|outscale|proxmox|all> [--role management]
#                        [--confirm <cluster id | all>] [-- --force-no-edges]
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
ENVS_DIR="$CLUSTER_DIR/envs"
FLEET_DOWN="$ROOT/scripts/ops/fleet-down.sh"
PROVIDERS="scaleway ovh outscale proxmox"
# fleet-down honors OA_ENVS_DIR: the guard must read the file the destroy reads.
unset OA_ENVS_DIR

info() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }

# ---------------------------------------------------------------- the guards
# Both set GUARD_WHY and return 1 on a refusal; no output, no network, no state.

# What could make tofu read something other than the tfvars the guard reads.
teardown_guard_env() {
  local v
  GUARD_WHY=""
  { [ -z "${OA_NO_TEARDOWN_ALL+x}" ] && [ ! -e "$ROOT/.no-teardown-all" ]; } ||
    { GUARD_WHY="the kill switch is on (OA_NO_TEARDOWN_ALL is set, or $ROOT/.no-teardown-all exists): this host forbids teardown-all"; return 1; }
  # -var / -var-file in TF_CLI_ARGS* beat the tfvars the guard reads.
  for v in $(compgen -e TF_CLI_ARGS); do
    case "${!v}" in
      *-var*) GUARD_WHY="$v carries -var, which would override the tfvars the guard reads"; return 1 ;;
    esac
  done
}

# <tfvars> <provider>: on success GUARD_CLUSTER is "<cluster_name>-<environment>" and
# GUARD_ID adds "-<provider>", the cluster_id of cluster/main.tf.
teardown_guard() {
  local f="$1" p="$2" env name rc
  GUARD_WHY=""; GUARD_ID=""; GUARD_CLUSTER=""
  { [ -f "$f" ] && [ -r "$f" ]; } || { GUARD_WHY="$f is missing or unreadable"; return 1; }
  env="$(tfv_strict "$f" environment)"; rc=$?
  case $rc in
    0) ;;
    1) GUARD_WHY="environment: no such line in $f"; return 1 ;;
    *) GUARD_WHY="environment: the line in $f is duplicated, indented, or not a plain quoted string"; return 1 ;;
  esac
  [ "$env" = dev ] || { GUARD_WHY="environment: \"$env\" in $f, not exactly \"dev\""; return 1; }
  # Absent cluster_name is legitimate: tofu then uses the variable's default.
  name="$(tfv_strict "$f" cluster_name)"; rc=$?
  if [ "$rc" -eq 1 ]; then name="$(oa_pinned_version "$CLUSTER_DIR" "" cluster_name)"; rc=0; fi
  { [ "$rc" -eq 0 ] && [ -n "$name" ]; } || { GUARD_WHY="cannot read a cluster_name from $f to name the confirmation"; return 1; }
  # cluster_id uses the provider the tfvars DECLARES; the credentials follow the file name.
  [ "$(tfv_provider "$f")" = "$p" ] ||
    { GUARD_WHY="$f is named for $p but declares '$(tfv_provider "$f")'"; return 1; }
  GUARD_CLUSTER="$name-$env"; GUARD_ID="$name-$env-$p"
}

refuse() { # <why>...: a guard said no, and the way out is the production lane
  local pv="${PROVIDER:-<provider>}"; [ "$pv" != all ] || pv="<provider>"
  printf '✗ teardown-all refused. Nothing was planned or destroyed.\n' >&2
  printf '    %s\n' "$@" >&2
  cat >&2 <<EOT
  This lane takes down environment = "dev" clusters only, and no flag lifts a refusal.
  Anything else takes the two commands, always:
    task cluster-down PROVIDER=$pv ROLE=${ROLE:-management} -- --plan
    task cluster-down PROVIDER=$pv ROLE=${ROLE:-management} -- --plan-file destroy-${ROLE:-management}-$pv.tfplan --yes
EOT
  exit 1
}

need() { # <what to fix>: the operator's input is wrong, not the cluster
  printf '✗ teardown-all: %s. Nothing was planned or destroyed.\n' "$1" >&2
  exit 1
}

usage() {
  echo "usage: teardown-all.sh <scaleway|ovh|outscale|proxmox|all> [--role R] [--confirm <id|all>] [-- --force-no-edges]" >&2
  exit 2
}

# fleet-down deletes the CAPI children of whichever cluster its kubeconfig reaches, and the checkout has ONE
# kubeconfig path, left by whatever ran last. Fetch this target's; when that fails point at nothing, so
# fleet-down stops as for a lost kubeconfig (or proves nothing was bootstrapped) instead of acting on another cluster.
use_kubeconfig() { # <provider>
  if ( cd "$ROOT" && task kubeconfig PROVIDER="$1" ROLE="$ROLE" ) >/dev/null; then
    export KUBECONFIG="$CLUSTER_DIR/kubeconfig"
  else
    export KUBECONFIG="$CLUSTER_DIR/kubeconfig.unavailable"
    warn "no kubeconfig for $1: fleet-down will treat its management as unreachable"
  fi
}

stopped() { # <what happened>: leaves after at least one plan, which is not read-only
  printf '✗ %s. Nothing was destroyed, but a plan may have untracked the Talos secrets of %s from the state.\n' "$1" "${PLANNED[*]}" >&2
  printf '  Before any apply or cluster-up, restore the replica (infrastructure/opentofu/cluster/README.md, "Lost the Talos secrets"), or run teardown-all again.\n' >&2
  exit 1
}

# ------------------------------------------------------------------ the proof
# Each check is read from its exit code (0 clean, 1 leftovers, 2 could not check) with the
# output captured whole: a pipe into grep -q or tail has read a truncated listing as clean.
LEFT=0
LEFT_PROVIDERS=""
UNPROVEN=""
left() { LEFT=1; case " $LEFT_PROVIDERS " in *" $1 "*) ;; *) LEFT_PROVIDERS="$LEFT_PROVIDERS $1" ;; esac; }
check() { # <provider> <label> <gates 1|0> <cmd...>
  local p="$1" label="$2" gate="$3" out rc
  shift 3
  out="$("$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  case $rc in
    0) ok "$label: clean" ;;
    1) if [ "$gate" = 1 ]; then warn "$label: LEFTOVERS found"; left "$p"; else warn "$label: lists resources; read them, this run does not gate on them"; fi ;;
    *) warn "$label: could not check (exit $rc), so this is NOT clean"; left "$p" ;;
  esac
}

prove() { # <provider> <cluster>
  local p="$1" c="$2" kind purge_gates=1
  case "$p" in
    scaleway) kind=scaleway ;;
    ovh)      kind=openstack ;;
    # Its pre-fix Net (#43) can never be deleted: the listing is read, not gated on (as in real-cloud-regression.yml).
    outscale) kind=outscale; purge_gates=0 ;;
    *) warn "no provider-side check exists for $p: look at the provider yourself"; UNPROVEN="$UNPROVEN $p"; return ;;
  esac
  # A missing script is python3's exit 2, so a renamed check cannot read as clean. Dry-run only: --apply would reach the whole project.
  check "$p" "purge-orphans/$p.py, WHOLE PROJECT (dry-run)" "$purge_gates" python3 "$ROOT/scripts/ops/purge-orphans/$p.py"
  check "$p" "verify-provider-clean $c" 1 python3 "$ROOT/scripts/ops/verify-provider-clean.py" "$c" "$kind"
}

# ----------------------------------------------------------------------- main
main() {
  local PROVIDER="" ROLE=management given="" p i q expected typed format interactive=0
  local -a PASS=() TARGETS=() IDS=() CLUSTERS=() PLANNED=() DESTROYED=() WHYS=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --role)    [ $# -ge 2 ] || usage; ROLE="$2"; shift 2 ;;
      --confirm) [ $# -ge 2 ] || usage; given="$2"; shift 2 ;;
      --)        shift; break ;;
      -*)        usage ;;
      *)         [ -z "$PROVIDER" ] || usage; PROVIDER="$1"; shift ;;
    esac
  done
  # Only this flag is forwarded: --plan, --plan-file, --role and --yes would change what
  # is destroyed, or skip the plan that was read.
  for p in "$@"; do
    [ "$p" = --force-no-edges ] || { echo "✗ '$p' is not forwarded to fleet-down (only --force-no-edges is)" >&2; exit 2; }
    PASS=(--force-no-edges)
  done
  case "$PROVIDER" in scaleway | ovh | outscale | proxmox | all) ;; *) usage ;; esac
  [[ "$ROLE" =~ ^[a-z][a-z0-9]*$ ]] || { echo "✗ --role must be a plain lowercase name, got '$ROLE'" >&2; exit 2; }

  # ---- 1. every guard, for every target, before anything else runs
  teardown_guard_env || refuse "$GUARD_WHY"
  if [ "$PROVIDER" = all ]; then
    for p in $PROVIDERS; do
      [ -e "$ENVS_DIR/$ROLE-$p.tfvars" ] || [ -L "$ENVS_DIR/$ROLE-$p.tfvars" ] && TARGETS+=("$p")
    done
    [ "${#TARGETS[@]}" -gt 0 ] || refuse "no $ROLE-<provider>.tfvars under $ENVS_DIR, so there is no target"
  else
    TARGETS=("$PROVIDER")
  fi
  for p in "${TARGETS[@]}"; do
    if teardown_guard "$ENVS_DIR/$ROLE-$p.tfvars" "$p"; then
      IDS+=("$GUARD_ID"); CLUSTERS+=("$GUARD_CLUSTER")
    else
      WHYS+=("$p: $GUARD_WHY")
    fi
  done
  [ "${#WHYS[@]}" -eq 0 ] || refuse "${WHYS[@]}"

  # ---- 2. the typed confirmation: checked now when it is given or cannot be asked later
  expected="${IDS[0]}"; format="the cluster id, <cluster_name>-<environment>-<provider> (see the tfvars)"
  [ "$PROVIDER" = all ] && { expected=all; format="all"; }
  [ -t 0 ] && interactive=1
  [ -z "${CONFIRM+x}" ] || need "CONFIRM is exported in this environment, and an inherited value must not stand for the typed id: unset it and pass --confirm"
  if [ -n "$given" ] && [ "$given" != "$expected" ]; then need "--confirm '$given' is not $format"; fi
  if [ -z "$given" ] && [ "$interactive" -eq 0 ]; then need "no terminal to ask: pass CONFIRM=<value>, where the value is $format"; fi

  info "teardown-all: ${#TARGETS[@]} target(s), role $ROLE"
  for i in "${!TARGETS[@]}"; do printf '  %s   (provider %s)\n' "${IDS[$i]}" "${TARGETS[$i]}"; done

  # ---- 3. plan: destroys nothing, and prints what a child cluster would cost
  for i in "${!TARGETS[@]}"; do
    p="${TARGETS[$i]}"; PLANNED+=("${IDS[$i]}")
    use_kubeconfig "$p"
    "$FLEET_DOWN" "$p" --role "$ROLE" --plan ${PASS[@]+"${PASS[@]}"} </dev/null ||
      stopped "planning $p failed (a management that is unreachable and has no child: task teardown-all PROVIDER=$p -- --force-no-edges)"
  done

  # ---- 4. confirmation: after the plans, so what is typed is what was read
  if [ "$interactive" -eq 1 ]; then
    echo "Read the plans above: a CAPI child cluster they list is destroyed first, with no prompt of its own."
    echo "Ignore the 'task cluster-down' line a plan prints: this lane lands the plan itself, behind the dev guard."
    if [ "$PROVIDER" = all ]; then
      read -r -p "Destroy EVERY target listed above? Type 'all': " typed || typed=""
    else
      read -r -p "Destroy $expected? Type its cluster id: " typed || typed=""
    fi
    [ "$typed" = "$expected" ] || stopped "aborted"
  fi

  # ---- 5. destroy, one target after the other, stopping at the first failure
  for i in "${!TARGETS[@]}"; do
    p="${TARGETS[$i]}"
    info "destroying ${IDS[$i]}"
    use_kubeconfig "$p"
    if "$FLEET_DOWN" "$p" --role "$ROLE" --plan-file "destroy-$ROLE-$p.tfplan" --yes ${PASS[@]+"${PASS[@]}"} </dev/null; then
      DESTROYED+=("${IDS[$i]}")
    else
      printf '✗ destroying %s FAILED, stopping here and skipping the proof.\n' "${IDS[$i]}" >&2
      printf '  destroyed before it, NOT proven clean: %s\n' "${DESTROYED[*]:-none}" >&2
      printf '  not attempted: %s\n' "${TARGETS[*]:i+1}" >&2
      printf '  A destroyed target has no plan left, so re-run the others one provider at a time:\n' >&2
      for q in "${TARGETS[@]:i}"; do printf '    task teardown-all PROVIDER=%s ROLE=%s\n' "$q" "$ROLE" >&2; done
      for q in "${TARGETS[@]:0:i}"; do printf '  and read what %s left: python3 scripts/ops/purge-orphans/%s.py (dry-run)\n' "$q" "$q" >&2; done
      exit 3
    fi
  done

  # ---- 6. proof
  for i in "${!TARGETS[@]}"; do
    info "proof for ${IDS[$i]}"
    prove "${TARGETS[$i]}" "${CLUSTERS[$i]}"
  done
  if [ "$LEFT" -ne 0 ]; then
    printf '\n✗ teardown-all: destroyed, but NOT proven clean. Resources may still be billed.\n' >&2
    for p in $LEFT_PROVIDERS; do
      printf '    python3 scripts/ops/purge-orphans/%s.py            # dry-run: what it would delete\n' "$p" >&2
      printf '    python3 scripts/ops/purge-orphans/%s.py --apply    # deletes it\n' "$p" >&2
    done
    printf '  ⚠ purge-orphans targets the WHOLE project, not this cluster: on an account that also\n' >&2
    printf '    holds another cluster (a prod one included) --apply deletes that one too.\n' >&2
    exit 3
  fi
  if [ -n "$UNPROVEN" ]; then
    warn "destroyed: ${DESTROYED[*]}, but NOT proven clean on:$UNPROVEN. Buckets, images and keypairs are left too."
    exit 4
  fi
  ok "teardown-all complete: ${DESTROYED[*]}. Buckets, images and keypairs are NOT deleted and keep billing (fleet-down step 3 lists them)."
}

# Sourced by test-teardown-all.sh, which calls the guards alone.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
