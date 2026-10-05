#!/usr/bin/env bash
# ==============================================================================
# OpenAether — COMPLETE, idempotent fleet teardown (edges + management)
#
# The destruction order is not free: every CAPI child must disappear BEFORE the
# management, or nothing drives its VMs any more and they stay billed. `task
# destroy` alone only handles the management. This script chains, unattended:
#   1. `edge-down` on every child cluster still present (CAPI cascade);
#   2. `tofu destroy` of the management;
#   3. a report of what is left to purge by hand (buckets, images, keypairs…),
#      deliberately NOT destroyed here: those outlive the clusters, so deleting
#      them is a choice, not a consequence.
#
# Idempotent: re-runnable at any time; skips whatever is already gone.
#
# Usage:
#   fleet-down.sh <provider> [--role management] [--yes] [--keep-images]
#   The management KUBECONFIG is derived from infrastructure/opentofu/cluster/.
# ==============================================================================
set -uo pipefail

PROVIDER="${1:?usage: fleet-down.sh <provider> [--role management] [--plan | --plan-file F] [--yes]}"
shift
ROLE=management
ASSUME_YES=0
FORCE_NO_EDGES=0
# TWO COMMANDS, ALWAYS. Destroying a fleet must not be one line anyone can type
# by accident, and making the macro do plan-then-apply internally would put the
# single line back one level up. --plan computes and stops; --plan-file applies
# exactly what was computed. Nothing else destroys anything.
PLAN_ONLY=0
PLAN_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --plan) PLAN_ONLY=1; shift ;;
    --plan-file) PLAN_FILE="$2"; shift 2 ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    --force-no-edges) FORCE_NO_EDGES=1; shift ;;
    --keep-images) shift ;;   # accepted for symmetry, no effect here
    *) echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# For oa_project(): the bucket-name convention lives in one place, and step 3 of
# this script reports those names to an operator who is about to trust them.
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
ENVS_DIR="${OA_ENVS_DIR:-$CLUSTER_DIR/envs}"   # OA_ENVS_DIR: a test sandbox (absolute)
export KUBECONFIG="${KUBECONFIG:-$CLUSTER_DIR/kubeconfig}"

# Any step that fails flips this; the script exits non-zero at the end. It used
# to report success after a management destroy that never started, leaving
# 7 VMs running and billed (2026-07-28).
FAILED=0

info() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
# This file had no `die`, and the guard added on 2026-08-15 called one. bash
# printed "die: command not found", carried on, and destroyed the management
# after an enumeration that had failed — the exact outcome the guard exists to
# prevent, with the guard in place. Found by scripts/dev/test-teardown.sh on its
# first run, which is the whole argument for that harness.
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ 1. edges
#
# ⚠️ FAIL-SAFE (lesson from 2026-07-26): if the management is unreachable, we
# CANNOT know whether it was driving child clusters. Destroying the management
# in that case leaves their VMs orphaned and BILLED — exactly what happened
# when an earlier version of this script settled for a warning. We STOP, unless
# --force-no-edges is passed (the operator then asserts there is no child, or
# has already purged them on the provider side).
info "Step 1/3 — CAPI child clusters"
# …but "unreachable" and "never existed" are not the same thing, and the state
# knows which. talos_machine_bootstrap is written when Kubernetes is first
# bootstrapped; without it no apiserver ever answered here, so no CAPI
# controller ever ran and there is nothing that could have created a child.
# Measured 2026-08-19: a deploy that died at the load balancer, before phase 2,
# then could not be torn down — the guard demanded an assertion the state was
# already able to prove.
never_bootstrapped() {
  local ak sk
  ak="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" ak 2>/dev/null)" || return 1
  sk="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" sk 2>/dev/null)" || return 1
  [ -n "$ak" ] || return 1
  ( cd "$ROOT/infrastructure/opentofu/cluster" 2>/dev/null || exit 1
    export AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk"
    tofu init -reconfigure \
      $("$ROOT/scripts/internal/tf-backend.sh" "$ENVS_DIR/${ROLE}-${PROVIDER}.tfvars") >/dev/null 2>&1 || exit 1
    # An EMPTY state list is not proof: it can also mean the wrong backend or a
    # failed read. Only a state that holds resources AND no bootstrap is proof.
    local out
    out="$(tofu state list 2>/dev/null)" || exit 1
    [ -n "$out" ] || exit 1
    ! grep -q 'talos_machine_bootstrap' <<<"$out" )
}

if [ ! -r "$KUBECONFIG" ] || ! kubectl cluster-info >/dev/null 2>&1; then
  if [ "$FORCE_NO_EDGES" -eq 1 ]; then
    warn "management unreachable — step skipped (--force-no-edges assumed)."
  elif [ "${OA_SKIP_BOOTSTRAP_PROBE:-}" != 1 ] && never_bootstrapped; then
    ok "this cluster was never bootstrapped (no talos_machine_bootstrap in state) — no CAPI controller ever ran, so no child clusters"
  else
    cat >&2 <<'EOT'

✗ STOP: the management cluster is unreachable (no kubeconfig, or API down).
  Cannot verify that no CAPI child cluster remains. Destroying the management
  now would leave their VMs ORPHANED and BILLED.

  What to do:
    • kubeconfig lost? regenerate it:
        cd infrastructure/opentofu/cluster && tofu output -raw kubeconfig > kubeconfig
        (or  talosctl -e <tunnel> -n <cp-ip> kubeconfig ./kubeconfig --force)
    • children already deleted, or a bootstrap that never reached Kubernetes
      (so no CAPI controller ever ran)? re-run asserting there is none:
        task cluster-down PROVIDER=<provider> -- --force-no-edges --yes
      The bare -- is not optional: without it Task keeps the flags itself.
    • when in doubt: inventory on the provider side FIRST (look for the child
      clusters' prefix among VMs, LBs, networks) — see the GitHub issues
EOT
    exit 1
  fi
else
  # ⚠️ Bare `cluster` is AMBIGUOUS: CNPG also exposes a `Cluster` kind
  # (postgresql.cnpg.io). When the CAPI CRDs are not installed — management
  # partially destroyed, providers not yet reconciled — `kubectl get cluster`
  # returns the DATABASES (observed 2026-07-27: grafana-db, zitadel-db) and this
  # script would run `edge-down` against them. Always qualify the API group.
  # ⚠️ A query that FAILED is not an absence of children. `mapfile` over failing
  # output gives an empty array, indistinguishable from a childless management —
  # and the next step destroys the management, which is precisely how a child
  # outlives the thing that could delete it and bills forever. That is the
  # scenario this script's own header calls non-negotiable.
  if ! EDGES_RAW="$(kubectl get clusters.cluster.x-k8s.io -A -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.namespace}{"\n"}{end}' 2>/dev/null)"; then
    # The query fails in two ways that mean OPPOSITE things, and stderr is the
    # only thing that tells them apart — so ask again, keeping the reason. The
    # second call happens only on the failure path.
    WHY="$(kubectl get clusters.cluster.x-k8s.io -A 2>&1 >/dev/null || true)"
    case "$WHY" in
      # The CRDs are absent: a management with no CAPI has no children BY
      # DEFINITION. Refusing here made --force-no-edges mandatory on every
      # cluster this release builds, and the cost of that refusal is a cloud
      # left billing — measured twice on 2026-08-19, on a teardown that was
      # itself trying to stop the bill.
      *"doesn't have a resource type"*|*"could not find the requested resource"*|*"server could not find"*)
        ok "no CAPI CRDs on this cluster — no child clusters by definition"
        ;;
      # Anything else — unreachable, unauthorized, timed out — is a question we
      # could not answer, and an unanswered question is NOT an absence of
      # children. This is the case the guard was written for, and it still
      # refuses: a child that outlives its management bills for ever.
      *)
        if [ "$FORCE_NO_EDGES" -eq 1 ]; then
          warn "the child-cluster query failed and --force-no-edges says to proceed: ${WHY%%$'\n'*}"
        else
          die "cannot enumerate child clusters (clusters.cluster.x-k8s.io), and the
  reason is NOT that the CAPI CRDs are absent — refusing to destroy the
  management. The provider said: ${WHY%%$'\n'*}
  Fix the access, or pass --force-no-edges to assert there are no children."
        fi
        ;;
    esac
    EDGES_RAW=""
  fi
  mapfile -t EDGES < <(printf '%s' "$EDGES_RAW")
  if [ "${#EDGES[@]}" -eq 0 ]; then
    ok "no child cluster"
  else
    printf '  %s child clusters: %s\n' "${#EDGES[@]}" "$(printf '%s ' "${EDGES[@]%% *}")"
    for e in "${EDGES[@]}"; do
      name="${e%% *}"; ns="${e##* }"
      # --plan destroys NOTHING, and a child cluster is something. Reporting it
      # here and deleting it below would make the first of the two commands
      # destructive, which is the whole thing this split exists to prevent.
      if [ "$PLAN_ONLY" = 1 ]; then
        warn "child cluster ${name} would be destroyed first (not touched by --plan)"
        continue
      fi
      if ! "$ROOT/scripts/ops/edge-down.sh" "$name" --namespace "$ns" --timeout 900 \
             $([ "$ASSUME_YES" -eq 1 ] && echo --yes); then
        warn "edge-down $name FAILED."
        if [ "$FORCE_NO_EDGES" -eq 1 ]; then
          warn "--force-no-edges: continuing anyway (check the VMs on the provider side)."
          FAILED=1
        else
          cat >&2 <<EOT

✗ STOPPING before touching the management: '$name' was not cleanly destroyed.
  Destroying the management now would orphan its VMs. Purge them on the provider
  side first, then re-run (this script is idempotent).
EOT
          exit 1
        fi
      fi
    done
  fi
fi

# -------------------------------------------------------- 2. the management
info "Step 2/3 — management cluster ($ROLE / $PROVIDER)"

# --plan: compute the destruction and STOP. This is the first of the two
# commands, and it is the one an operator reads.
if [ "$PLAN_ONLY" = 1 ]; then
  PLAN_OUT="destroy-${ROLE}-${PROVIDER}.tfplan"
  # Say who is driving, so the inner target does not advertise a next step that
  # would bypass this script's own first phase.
  ( cd "$ROOT" && OA_DRIVEN_BY=fleet-down task infra-down-plan ROLE="$ROLE" PROVIDER="$PROVIDER" OUT="$PLAN_OUT" ) || {
    warn "could not compute the destruction plan"; exit 1; }
  # Echo back the flags we were GIVEN, not a fixed string: step 1 refuses without
  # --force-no-edges when the CAPI CRDs are absent, so a hard-coded line printed a
  # command this same script then rejected. Measured 2026-08-19.
  printf '\n✓ nothing was destroyed. Read the plan above, then land exactly it:\n'
  printf '    task cluster-down PROVIDER=%s ROLE=%s -- --plan-file %s%s --yes\n\n' \
    "$PROVIDER" "$ROLE" "$PLAN_OUT" \
    "$([ "$FORCE_NO_EDGES" = 1 ] && printf ' --force-no-edges')"
  exit 0
fi

# No plan file, no destruction. APPROVE, --yes, force and TF_CLI_ARGS_destroy are all
# deliberately powerless here: the only way past this line is a plan somebody read.
if [ -z "$PLAN_FILE" ]; then
  printf '✗ refusing to destroy without a plan you have read.\n' >&2
  printf '  This takes two commands, always:\n' >&2
  printf '    task cluster-down PROVIDER=%s ROLE=%s -- --plan\n' "$PROVIDER" "$ROLE" >&2
  printf '    task cluster-down PROVIDER=%s ROLE=%s -- --plan-file destroy-%s-%s.tfplan --yes\n' \
    "$PROVIDER" "$ROLE" "$ROLE" "$PROVIDER" >&2
  exit 1
fi
if [ "$ASSUME_YES" -eq 0 ]; then
  read -rp "Destroy the $ROLE-$PROVIDER management? [y/N] " a
  [ "$a" = y ] || [ "$a" = Y ] || { echo "aborted"; exit 1; }
fi
# BOUNDED RETRY. Cloud deletions propagate asynchronously and the network teardown
# races them. Outscale, 2026-08-16: two consecutive passes died on "Subnet ... is
# in use. It has NICs" and "A load balancer is present on Net ... The Internet
# service cannot be detached" — while the provider's own API already answered
# zero instances, zero load balancers and zero network interfaces. Nothing was
# broken; the plan simply ran ahead of the provider, and re-running by hand
# worked. That is a loop's job, not the operator's.
#
# Still fails at the end, and says how many attempts it took: a retry that hides
# a permanent failure would be worse than the race it fixes.
DESTROY_ATTEMPTS="${DESTROY_ATTEMPTS:-3}"
DESTROY_BACKOFF="${DESTROY_BACKOFF:-60}"   # seconds, for deletions to settle
attempt=1
# Kept so the ending can tell "retry this" apart from "only the provider can lift
# it". Without the transcript the report can only say FAILED, which is what sent
# an operator round the same loop on 2026-08-18.
DESTROY_LOG="$(mktemp)"
trap 'rm -f "$DESTROY_LOG"' EXIT
while :; do
  # A PIPE, not a process substitution: `set -o pipefail` above makes the `if`
  # see the destroy's own status, and the pipeline does not return until tee has
  # finished writing — so the transcript is complete when it is read below.
  if ( cd "$ROOT" && task infra-down ROLE="$ROLE" PROVIDER="$PROVIDER" PLAN="$PLAN_FILE" ) 2>&1 | tee "$DESTROY_LOG"; then
    if [ "$attempt" -gt 1 ]; then
      ok "management destroyed (attempt ${attempt}/${DESTROY_ATTEMPTS})"
    else
      ok "management destroyed"
    fi
    break
  fi
  if [ "$attempt" -ge "$DESTROY_ATTEMPTS" ]; then
    warn "the management destroy FAILED after ${attempt} attempt(s) — re-run after fixing (idempotent)"
    FAILED=1
    break
  fi
  warn "destroy attempt ${attempt}/${DESTROY_ATTEMPTS} failed; waiting ${DESTROY_BACKOFF}s for the provider's deletions to propagate, then retrying"
  sleep "$DESTROY_BACKOFF"
  attempt=$((attempt + 1))
done

# ------------------------------------------------ 3. what is left (report)
info "Step 3/3 — left to purge MANUALLY (deliberately survives the teardown)"
# oa_project(), not cluster_name verbatim. The convention is the FIRST SEGMENT of
# cluster_name plus bucket_suffix — `openaether-dev` gives `openaether`, and a
# suffix is appended. Interpolating the raw value printed names that do not exist
# for anyone who set a suffix or put a hyphen in their cluster name, which is
# every reader of docs/first-cluster.md step 3. The report is the deliverable of
# this step, so a report that names the wrong buckets is the whole step wasted.
TFV="$ENVS_DIR/$ROLE-$PROVIDER.tfvars"
_tfv() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFV" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)".*/\1/'; }
CN="$(oa_project "$(_tfv cluster_name)" "$(_tfv bucket_suffix)")"
ENVN="$(_tfv environment)"
cat <<EOT
  S3 buckets (state, artifacts, backups) — destroying them also removes any
  possibility of restoring:
    (each of the first two also has a "-backup" twin)
    s3-${CN:-<project>}-${PROVIDER}-tfstate-${ENVN:-<env>}
    s3-${CN:-<project>}-${PROVIDER}-${ROLE}-${ENVN:-<env>}
    s3-${CN:-<project>}-*-backups-${ENVN:-<env>}   (restic, all providers)
  Talos images (reusable — one set per version built; a rebuild is 8 min to over 1 h on Outscale):
    task talos-image PROVIDER=$PROVIDER LIST=1 shows them, VERSION=<v> PRUNE=1 removes one; the
    state is one key per version in bucket s3-${CN:-<project>}-${PROVIDER}-talos-image.
  Objects created outside OpenTofu for CAPI (to recreate on the next deployment):
    Outscale keypair 'openaether-capi', pre-created OpenStack FIP (edge-2 certSANs).
  Local: kubeconfig, talosconfig, edge-*.kubeconfig, restic-escrow-*.txt
EOT
if [ "$FAILED" -ne 0 ]; then
  # Two very different endings, and telling them apart is the whole point.
  #
  # A managed load balancer that never finished provisioning cannot be deleted by
  # ANYONE but the provider, and it holds a port inside the customer subnet — so
  # the subnet, then the network, then the teardown all queue behind it. Measured
  # on Outscale 2026-08-16 and on OVH 2026-08-18: the same mechanism, and on
  # Outscale the provider's own listing said zero load balancers while its refusal
  # named one. Retrying that is not a strategy. See .claude/skills/teardown.
  if grep -qEi 'load balancer is present on Net|Invalid state PENDING_(CREATE|DELETE)|is in use\. It has NICs|has dependencies and cannot be deleted' "$DESTROY_LOG" 2>/dev/null; then
    printf '\n\033[33m─── this is not yours to fix ───\033[0m\n' >&2
    printf 'The provider refused with one of the signatures of a WEDGED MANAGED LOAD\n' >&2
    printf 'BALANCER. It reserves a port inside your subnet before its own backend\n' >&2
    printf 'exists; when the backend never attaches it cannot be deleted, and the\n' >&2
    printf 'subnet and network queue behind it. Re-running will not change that.\n\n' >&2
    grep -Ei 'load balancer is present on Net|Invalid state PENDING_|is in use\. It has NICs|has dependencies and cannot be deleted' "$DESTROY_LOG" |
      sort -u | head -6 | sed 's/^/    /' >&2
    printf '\nWhat to do, in order:\n' >&2
    printf '  1. Confirm nothing BILLABLE is left — instances, volumes, public IPs, NAT.\n' >&2
    printf '     Networks, subnets, route tables and gateways are not the expensive part.\n' >&2
    printf '       python3 scripts/ops/purge-orphans/%s.py        # dry-run, asks the provider\n' "$PROVIDER" >&2
    printf '  2. Open a support ticket, and put BOTH answers in it — the listing that\n' >&2
    printf '     says the resource is absent AND the refusal that names it. That\n' >&2
    printf '     contradiction is the whole argument.\n' >&2
    printf '  3. Move on. Nothing in this repository can lift it.\n\n' >&2
    exit 1
  fi
  printf '\n✗ fleet-down INCOMPLETE — see the ⚠ above. Resources may still exist\n'  >&2
  printf '  and be BILLED. Check the provider, then re-run (idempotent).\n' >&2
  exit 1
fi
ok "fleet-down complete"
