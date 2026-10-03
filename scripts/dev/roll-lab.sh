#!/usr/bin/env bash
# OpenAether — iterate on the node roll without rebuilding the cluster.
#
# A roll fix used to be retested by deploying an 85-minute cluster in order to
# exercise its last twenty minutes. Two moves make that unnecessary, and both
# were used for real while fixing the roll on 2026-08-15:
#
#   resume                re-run the roll on the live cluster. `--upgrade` skips
#                         every node already on the target version, so a fixed
#                         roll costs minutes instead of a redeploy.
#   inject-cnpg-deadlock  reproduce in ~2 minutes the CNPG deadlock that cost
#                         four cloud rolls to characterise: cordon the node
#                         holding a primary and delete that pod. Its
#                         local-path-retain PVC pins it to the cordoned node, so
#                         it cannot come back and CNPG stalls mid-switchover.
#   status                what the next resume will see: node versions, cordons,
#                         CNPG state, the budgets that block a drain.
#   cleanup               uncordon what a roll or an injection left cordoned.
#   self-test             no cluster needed: prove the roll's gates this lab
#                         borrows still behave the way it reports them.
#
# This script BREAKS a running cluster on purpose. It therefore refuses to run
# anywhere that does not look disposable, and it needs a live cluster — neither
# is assumed, both are checked below.
#
# Usage: roll-lab.sh <resume|inject-cnpg-deadlock|status|cleanup|self-test> [provider]
#                    [--offset N] [--yes] [--dry-run]
#                    [--workers-only|--cp-only|--all]   (resume)
#                    [--cluster <ns>/<name>]            (inject-cnpg-deadlock)
#   The offset also comes from TALOS_TUNNEL_OFFSET, like every other script here.
# ==============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/common.sh"

info() { printf '▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }
hr()   { printf -- '─%.0s' {1..70}; printf '\n'; }

usage() {
  sed -n '/^# Usage:/,/^# ===/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^===/d' >&2
}

# --- args --------------------------------------------------------------------
CMD="${1:-}"; shift || true
case "$CMD" in
  resume | inject-cnpg-deadlock | status | cleanup | self-test) ;;
  *) usage; exit 2 ;;
esac

PROVIDER=""
SCOPE="--workers-only"   # a lab retest is nearly always the worker roll
TARGET_CNPG=""
ASSUME_YES=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offset)  export TALOS_TUNNEL_OFFSET="${2:-}"; shift 2 ;;
    --cluster) TARGET_CNPG="${2:-}"; shift 2 ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --workers-only | --cp-only) SCOPE="$1"; shift ;;
    --all)     SCOPE=""; shift ;;
    -*) usage; die "unknown flag: $1" ;;
    *)  PROVIDER="$1"; shift ;;
  esac
done
PROVIDER="${PROVIDER:-scaleway}"
case "$PROVIDER" in
  scaleway | ovh | outscale | proxmox) ;;
  *) die "unknown provider: $PROVIDER (expected scaleway|ovh|outscale|proxmox)" ;;
esac
OFFSET="$(oa_tunnel_offset)" || exit 1
# The cluster root reads the same number from TF_VAR_talos_tunnel_port_offset;
# Taskfile.yml derives one from the other so they cannot drift, and a script
# calling the roll directly has to do the same.
export TF_VAR_talos_tunnel_port_offset="$OFFSET"

# rolling-replace.sh reads `envs/…` and `./kubeconfig` relative to the cwd, so
# the lab has to stand where the roll stands.
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
ROLL="$ROOT/scripts/ops/rolling-replace.sh"
ROLL_LIB="$ROOT/scripts/lib/roll-gates.sh"   # where the gates it borrows are defined
cd "$CLUSTER_DIR" || die "no cluster root at $CLUSTER_DIR"
TFVARS="envs/management-${PROVIDER}.tfvars"
KUBECONFIG_FILE="${KUBECONFIG:-./kubeconfig}"
KCTL=(kubectl --kubeconfig "$KUBECONFIG_FILE")
INJECT_TIMEOUT="${INJECT_TIMEOUT:-300}"   # seconds to reach the deadlock shape

# --- the two things this script may not assume -------------------------------
# 1. Disposable. An environment name is a claim about the tfvars, not about the
#    cluster kubectl is pointed at, so it is only half the guard.
DISPOSABLE_ENVS="${ROLL_LAB_DISPOSABLE_ENVS:-dev test staging lab sandbox feint}"
# 2. Live, and the SAME cluster this state describes — otherwise "dev" was read
#    from one cluster's tfvars and the pod would be deleted on another's.
NODES_TSV=""   # name \t Ready \t cordoned|schedulable \t internal-ip \t osImage
CP_COUNT=0     # from the state, never assumed: a non-HA cluster has ONE control
WK_COUNT=0     # plane, and a check hardcoding three would refuse it for ever.

live_nodes_tsv() {
  local json
  # `|| true` here is the defect this repo keeps paying for: an apiserver that
  # did not answer would read as a cluster with no nodes, and every guard below
  # would pass on the empty set.
  json="$("${KCTL[@]}" get nodes -o json 2>/dev/null)" ||
    die "kubectl cannot reach the cluster via ${KUBECONFIG_FILE}.
  This script needs a LIVE cluster — it has nothing to say about a dead one.
  If the API goes through a tunnel, check the offset: this run used ${OFFSET}."
  jq -r '.items[] | [ .metadata.name,
      ([.status.conditions[]? | select(.type=="Ready") | .status] | first // "?"),
      (if .spec.unschedulable then "cordoned" else "schedulable" end),
      ([.status.addresses[]? | select(.type=="InternalIP") | .address] | first // "-"),
      (.status.nodeInfo.osImage // "-") ] | @tsv' <<<"$json"
}

require_disposable_live_cluster() {
  [[ -f "$TFVARS" ]] || die "tfvars not found: ${CLUSTER_DIR}/${TFVARS}"
  [[ -f "$KUBECONFIG_FILE" ]] || die "kubeconfig not found: ${KUBECONFIG_FILE} (looked from ${CLUSTER_DIR})"
  for bin in kubectl jq tofu; do command -v "$bin" >/dev/null 2>&1 || die "$bin is required"; done

  local envn
  envn="$(tfv "$TFVARS" environment)"
  [[ -n "$envn" ]] || die "no environment= in ${TFVARS} — refusing to guess whether it is disposable"
  # shellcheck disable=SC2076  # literal match on the padded list, not a regex
  [[ " $DISPOSABLE_ENVS " == *" $envn "* ]] ||
    die "${TFVARS} says environment=\"${envn}\", which is not one of: ${DISPOSABLE_ENVS}.
  This script cordons nodes and deletes database pods on purpose. Point it at a
  throwaway cluster, or name that environment in ROLL_LAB_DISPOSABLE_ENVS."

  NODES_TSV="$(live_nodes_tsv)"
  [[ -n "$NODES_TSV" ]] || die "the apiserver answered with an EMPTY node list — that is not a cluster to experiment on"

  # Tie the kubeconfig to the state: at least one control-plane IP from the tofu
  # output must be a node's InternalIP. Without this the guard above proves only
  # that some file on disk said "dev".
  local outputs cp_ips ip
  outputs="$(tofu output -json 2>/dev/null)" || outputs='{}'
  cp_ips="$(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$outputs")"
  CP_COUNT="$(jq -r '(.control_plane_private_ips.value // []) | length' <<<"$outputs")"
  WK_COUNT="$(jq -r '(.worker_private_ips.value // []) | length' <<<"$outputs")"
  [[ -n "$cp_ips" ]] ||
    die "no control_plane_private_ips in \`tofu output\` (run from ${CLUSTER_DIR}, after \`tofu init\`).
  Without it there is nothing tying ${KUBECONFIG_FILE} to ${TFVARS}, and the
  disposable check above would be about a different cluster."
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    if awk -F'\t' -v want="$ip" '$4 == want { found = 1 } END { exit !found }' <<<"$NODES_TSV"; then
      ok "cluster is disposable (environment=${envn}) and live: $(wc -l <<<"$NODES_TSV") node(s)"
      return 0
    fi
  done <<<"$cp_ips"
  die "none of the control-plane IPs in \`tofu output\` is an InternalIP of the nodes
  ${KUBECONFIG_FILE} reaches — that kubeconfig is NOT the cluster ${TFVARS} describes."
}

announce() { hr; info "About to, on ${PROVIDER} (offset ${OFFSET}):"; printf '   %s\n' "$@"; hr; }

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || die "no terminal to confirm on — re-run with --yes if this really is a lab cluster"
  local a; read -rp "Proceed? [y/N] " a
  [[ "$a" == [yY] ]] || die "aborted by operator"
}

# --- CNPG ---------------------------------------------------------------------
cnpg_installed() { "${KCTL[@]}" get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; }

# "|"-separated, one cluster per line, because an EMPTY field must stay a field.
# `.status.currentPrimary` is empty mid-election, and a `read` that drops the gap
# hands the TARGET to a caller asking for the primary — this lab then cordons a
# node and deletes the pod of a cluster that is already electing.
# The separator may NOT be a tab: bash treats space, tab and newline as IFS
# *whitespace* and collapses runs of them, so `IFS=$'\t' read` loses empty fields
# exactly like the space-separated version it replaced. "|" cannot occur in an
# RFC1123 namespace or object name, so it splits one field per delimiter.
# ALWAYS read it into a variable — `while read … < <(cnpg_list)` would run the
# die below in a subshell, so a failed query would arrive as an empty list and
# every caller would carry on as if the cluster had no databases.
CNPG_SEP='|'
cnpg_list() {
  "${KCTL[@]}" get clusters.postgresql.cnpg.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.instances}{"|"}{.status.readyInstances}{"|"}{.status.currentPrimary}{"|"}{.status.targetPrimary}{"\n"}{end}' 2>/dev/null ||
    die "the CNPG CRD exists but its clusters could not be listed — refusing to act blind"
}

# ==============================================================================
# The roll's own gates, and the proof that they still do what this lab reports
# ==============================================================================
# The injection is only worth anything if it produces the state the roll's own
# unstick fires on, and `status` only means something if the budgets it prints
# are the ones the roll's gate waits on — so borrow THAT code, extracted from
# roll-gates.sh the way scripts/dev/test-rolling-replace.sh does. A local
# copy would drift, and a drifted lab is worse than none.
#
# Extraction alone proves nothing: a detector that can no longer fire answers
# "no deadlock" to every question and reads as good news, and one whose helper
# the extraction does not carry does the same, silently. So run the borrowed
# code offline against the shapes measured on 2026-08-15 before quoting it.
ROLL_GATES=(cnpg_pod_state cnpg_deadlocked pdb_short)

# A kubectl the self-test can predict. The variables below pick the shape.
STUB_CUR=ready STUB_TGT=notready STUB_THIRD=True STUB_PDB=""
STUB_CLUSTERS="ns db pod-a pod-b"   # the roll's own query is space-separated
stub_pod() {
  case "$1" in
    ready)    echo True ;;
    notready) echo False ;;
    gone)     echo 'Error from server (NotFound): pods "pod-a" not found' >&2; return 1 ;;
    *)        echo 'The connection to the server was refused' >&2; return 1 ;;
  esac
}
stub_kubectl() {
  case "$*" in
    *'{.status.targetPrimary}'*) echo "$STUB_CLUSTERS" ;;
    *'get pod pod-a'*)           stub_pod "$STUB_CUR" ;;
    *'get pod pod-b'*)           stub_pod "$STUB_TGT" ;;
    *'cnpg.io/cluster=db'*)      printf 'pod-b False\npod-c %s\n' "$STUB_THIRD" ;;
    *'get pdb -A -o json'*)      [[ -n "$STUB_PDB" ]] && echo "$STUB_PDB" || return 1 ;;
    *) return 1 ;;
  esac
}

assert_roll_gates() {
  local fn missing=""
  # self-test skips the live preflight, and the borrowed budget gate parses with jq.
  command -v jq >/dev/null 2>&1 || die "jq is required"
  eval "$(awk -v fns="${ROLL_GATES[*]}" '
    BEGIN { n = split(fns, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\).*/, "", name); inside = (name in want) }
    inside { print }
    inside && /^\}/ { inside = 0 }' "$ROLL_LIB")"
  for fn in "${ROLL_GATES[@]}"; do
    declare -F "$fn" >/dev/null || missing+="${fn} "
  done
  [[ -z "$missing" ]] || die "roll-gates.sh no longer defines: ${missing}
  This lab must exercise the roll's own gates, not a copy of them — update
  ROLL_GATES here (and scripts/dev/test-rolling-replace.sh) to match."

  # `resume`'s whole claim belongs to rolling-replace.sh, not to us: without its
  # "already on the target version → skip" early return a retry re-rolls every
  # node, which is the redeploy this lab exists to avoid.
  #
  # Match the comparison AND the `return` that makes it a skip, both on
  # non-comment lines. Grepping the condition alone was a fingerprint, not an
  # assertion: it still matched when the block was commented out, and when only
  # the `return 0` was deleted — the two edits that actually break the skip.
  awk '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line ~ /^#/ { next }
    line ~ /\$running/ && line ~ /TALOS_IMAGE##\*:/ && line ~ /==/ { hit = NR }
    hit && NR > hit && NR <= hit + 4 && line ~ /^return[[:space:]]+0/ { ok = 1 }
    END { exit !ok }' "$ROLL" ||
    die "rolling-replace.sh no longer skips nodes already on the target version:
  the \`running == TALOS_IMAGE\` early return in its --upgrade path is gone (or
  no longer returns), so \`resume\` would re-roll the whole cluster instead of
  continuing the roll."

  # In a subshell: the stub must not leak into the live queries that follow.
  ( KCTL=(stub_kubectl)
    local name cur tgt third clusters want got errf
    # The extraction can drop a helper the detector calls. When that helper sits
    # in a `… || continue` the case table catches it; in a `… && continue` the
    # 127 just makes the guard a no-op and every case still passes. So treat ANY
    # stderr from the borrowed code as a failure: it means we did not carry all
    # of it, whichever direction the missing call is used in.
    errf="$(mktemp)"; trap 'rm -f "$errf"' EXIT
    while IFS='|' read -r name cur tgt third clusters want; do
      [[ -n "$name" ]] || continue
      STUB_CUR="$cur" STUB_TGT="$tgt" STUB_THIRD="$third"
      STUB_CLUSTERS="${clusters:-ns db pod-a pod-b}"
      : > "$errf"
      got="$(cnpg_deadlocked 2>"$errf")" || got="(the detector exited non-zero)"
      [[ ! -s "$errf" ]] || die "the roll's detector wrote to stderr on the '${name}' case:
  $(head -2 "$errf")
  Something it calls is not in the range this lab extracts, so the code running
  here is NOT the code the roll runs. Add it to ROLL_GATES."
      [[ "$got" == "$want" ]] || die "the roll's detector fails its own '${name}' case:
  expected '${want}', got '${got}'. This lab only ever repeats what that detector
  says; one that cannot fire — or fires on anything — makes every verdict it
  prints meaningless. Fix scripts/ops/rolling-replace.sh, not this file."
    done <<'CASES'
deadlock|gone|notready|True||ns db pod-b pod-a
normal-election|ready|notready|True||
unanswered-api|error|notready|True||
target-unanswered|gone|error|True||
target-also-gone|gone|gone|True||
no-switchover|gone|notready|True|ns db pod-a pod-a|
nothing-to-elect|gone|notready|False||
CASES

    # And the budget discriminator: a budget at 0 allowed / 1 healthy / 1
    # expected is zero BY DESIGN (a CNPG primary, a Longhorn instance-manager)
    # and must not be reported; one short of a pod must be.
    local pdb='{"items":[{"metadata":{"namespace":"ns","name":"b"},"spec":{"selector":{"matchLabels":{"k":"v"}}},"status":{"disruptionsAllowed":0,"currentHealthy":1,"expectedPods":EXP}}]}'
    STUB_PDB="${pdb/EXP/1}"
    [[ -z "$(pdb_short)" ]] || die "the roll's budget gate reports a by-design zero (0 allowed, 1/1 healthy) as short — waiting on that never ends"
    STUB_PDB="${pdb/EXP/2}"
    [[ "$(pdb_short | cut -f1-3 | tr '\t' '/')" == "ns/b/1/2" ]] ||
      die "the roll's budget gate no longer reports a budget short of a pod: got '$(pdb_short)'"
    # The OTHER half of the discriminator: a budget that still allows a
    # disruption blocks nothing, however short it is. Reporting it would make
    # wait_pdb_headroom sit out PDB_TIMEOUT on a deployment that is merely
    # scaling up.
    STUB_PDB="${pdb/EXP/5}"; STUB_PDB="${STUB_PDB/\"disruptionsAllowed\":0/\"disruptionsAllowed\":3}"
    [[ -z "$(pdb_short)" ]] ||
      die "the roll's budget gate reports a budget that ALLOWS a disruption as blocking:
  got '$(pdb_short)'. The gate waits on these, so the roll would stall on a
  budget that was never in its way."
    STUB_PDB=""
    if pdb_short >/dev/null 2>&1; then
      die "the roll's budget gate returns success on a failed query — an unanswered
  question is not 'no budget blocks', and this lab would print reassurance."
    fi ) || exit 1
}

# --- the target Talos version, i.e. what `resume` will skip -------------------
target_talos() {
  local tag
  tag="$(tofu output -raw installer_image 2>/dev/null || true)"
  [[ -n "$tag" ]] && { printf '%s' "${tag##*:}"; return 0; }
  tfv "$TFVARS" talos_version
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# The node tunnel ports this cluster actually uses (talos-tunnels.sh: CP
# 50000+offset+i, workers 50100+offset+i), one per line, absent ones only.
missing_tunnels() {
  local i
  for ((i = 0; i < CP_COUNT; i++)); do port_open $((50000 + OFFSET + i)) || echo "$((50000 + OFFSET + i))"; done
  for ((i = 0; i < WK_COUNT; i++)); do port_open $((50100 + OFFSET + i)) || echo "$((50100 + OFFSET + i))"; done
}

# ==============================================================================
# Subcommands
# ==============================================================================

do_status() {
  assert_roll_gates
  local target; target="$(target_talos)"
  hr; info "Nodes — target Talos ${target:-?} (resume skips those already on it)"
  awk -F'\t' -v t="${target:-none}" '
    { v = $5; sub(/.*\(/, "", v); sub(/\).*/, "", v)
      printf "  %-28s %-6s %-12s %-10s %s\n", $1, $2, $3, v,
             (t != "none" && v == t ? "on target" : "PENDING") }' <<<"$NODES_TSV"

  if cnpg_installed; then
    hr; info "CNPG"
    local ns name inst ready cur tgt clusters
    clusters="$(cnpg_list)"
    while IFS="$CNPG_SEP" read -r ns name inst ready cur tgt; do
      [[ -n "$ns" ]] || continue
      printf '  %-32s %s/%s ready   primary %s → %s\n' \
        "${ns}/${name}" "${ready:-?}" "${inst:-?}" "${cur:-none}" "${tgt:-none}"
    done <<<"$clusters"
    local d; d="$(cnpg_deadlocked)"
    if [[ -n "$d" ]]; then warn "the roll's detector says DEADLOCKED: ${d}"
    else ok "the roll's detector sees no deadlock"; fi
  fi

  # The roll's own discriminator, not a copy of it: printing budgets the gate
  # does not wait on (or missing the ones it does) is the drift this lab exists
  # to avoid. And a query that FAILED is not "no budget blocks a drain".
  hr; info "Budgets that would block a drain (allowed=0 and short of a pod)"
  local short
  if ! short="$(pdb_short)"; then
    warn "the apiserver did not answer — an unanswered query is not an empty list"
  elif [[ -z "$short" ]]; then
    ok "every budget that could recover allows a disruption"
  else
    awk -F'\t' '{ printf "  %s/%s  healthy %s\n", $1, $2, $3 }' <<<"$short"
  fi

  # A Kustomization left suspended is how rolling-replace fails halfway: it
  # suspends the CNPG owner for the roll and restores it on exit.
  local susp
  if susp="$("${KCTL[@]}" get kustomizations.kustomize.toolkit.fluxcd.io -A \
      -o jsonpath='{range .items[?(@.spec.suspend==true)]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null)"; then
    [[ -z "$susp" ]] || warn "Flux Kustomizations left SUSPENDED: ${susp}"
  else
    warn "could not list Flux Kustomizations — cannot say whether the roll left one suspended"
  fi

  hr; info "Talos tunnels (offset ${OFFSET})"
  local gone; gone="$(missing_tunnels | tr '\n' ' ')"
  if [[ -n "$gone" ]]; then warn "not listening: ${gone}(resume needs all $((CP_COUNT + WK_COUNT)))"
  else ok "all $((CP_COUNT + WK_COUNT)) node tunnels are listening"; fi
}

do_resume() {
  assert_roll_gates
  local target; target="$(target_talos)"
  [[ -n "$target" ]] || die "no target Talos version (no installer_image output and no talos_version in ${TFVARS})"
  local pending
  pending="$(awk -F'\t' -v t="$target" '{ v = $5; sub(/.*\(/, "", v); sub(/\).*/, "", v)
             if (v != t) printf "%s ", $1 }' <<<"$NODES_TSV")"
  [[ -n "$pending" ]] || warn "every node already reports ${target} — the roll will skip all of them"

  local -a cmd=("$ROLL" "$PROVIDER" --upgrade)
  [[ -n "$SCOPE" ]] && cmd+=("$SCOPE")
  # One prompt, ours: the roll runs unattended so a lab iteration is one command.
  [[ $DRY_RUN -eq 1 ]] && cmd+=(--dry-run) || cmd+=(--yes)

  # Tunnels are the roll's silent prerequisite: without them talosctl fails per
  # node, mid-roll, after the node has been cordoned and drained.
  local missing; missing="$(missing_tunnels | tr '\n' ' ')"
  if [[ -n "$missing" && $DRY_RUN -eq 0 ]]; then
    die "no Talos tunnel listening on ${missing}— open them first:
    SSH_KEY=~/.ssh/<key> ${ROOT}/scripts/bootstrap/talos-tunnels.sh open ${CLUSTER_DIR}
  (or run the roll through \`task cluster-roll\`, which opens them for you)."
  fi

  announce "run: ${cmd[*]}" \
           "nodes still to upgrade to ${target}: ${pending:-none}" \
           "nodes already on ${target} are SKIPPED — that is what makes this a retry"
  confirm
  exec "${cmd[@]}"
}

do_inject() {
  cnpg_installed || die "no CNPG on this cluster — nothing to deadlock"
  assert_roll_gates

  local ns name inst ready cur tgt found=0 clusters
  clusters="$(cnpg_list)"
  while IFS="$CNPG_SEP" read -r ns name inst ready cur tgt; do
    [[ -n "$ns" && -n "$name" ]] || continue
    if [[ -n "$TARGET_CNPG" && "${ns}/${name}" != "$TARGET_CNPG" ]]; then continue; fi
    # Three READY instances minimum. The deadlock the roll unsticks needs a third
    # instance to elect — on a 2-instance cluster the detector is right not to
    # fire, so injecting there would produce a state nothing is meant to fix.
    if ! [[ "$inst" =~ ^[3-9][0-9]*$ && "$ready" == "$inst" ]]; then
      [[ -z "$TARGET_CNPG" ]] ||
        die "${ns}/${name} is ${ready:-?}/${inst:-?} — the injection needs 3+ instances, all ready"
      continue
    fi
    found=1; break
  done <<<"$clusters"
  [[ $found -eq 1 ]] || die "no healthy CNPG cluster with 3+ instances${TARGET_CNPG:+ matching ${TARGET_CNPG}} — nothing to inject into"
  [[ -n "$cur" ]] || die "${ns}/${name} reports no currentPrimary — it is already mid-election, not a clean start"

  # A deadlock that was already there is not one this run reproduced, and a
  # detector that fires before anything is injected is not evidence of anything.
  local before; before="$(cnpg_deadlocked)"
  [[ -z "$before" ]] || die "the roll's detector ALREADY reports a deadlock, before this run touched
  anything: ${before}
  Clear it first ($(basename "${BASH_SOURCE[0]}") cleanup ${PROVIDER}), or this run
  would credit the injection with a state it did not create."

  local node
  node="$("${KCTL[@]}" -n "$ns" get pod "$cur" -o jsonpath='{.spec.nodeName}' 2>/dev/null)" ||
    die "could not read the node of ${ns}/${cur} — the apiserver did not answer"
  [[ -n "$node" ]] || die "primary pod ${ns}/${cur} does not exist — the cluster is already broken"

  announce "cordon ${node} (holds ${ns}/${name}'s primary ${cur})" \
           "delete pod ${ns}/${cur} — its local-path-retain PVC pins it to ${node}, so it cannot come back" \
           "wait up to ${INJECT_TIMEOUT}s for the roll's own detector to call it deadlocked" \
           "undo with: $(basename "${BASH_SOURCE[0]}") cleanup ${PROVIDER}"
  if [[ $DRY_RUN -eq 1 ]]; then ok "dry-run — nothing touched"; return 0; fi
  confirm

  "${KCTL[@]}" cordon "$node" || die "cordon failed for ${node}"
  "${KCTL[@]}" -n "$ns" delete pod "$cur" --wait=false >/dev/null ||
    { "${KCTL[@]}" uncordon "$node" || true; die "could not delete ${ns}/${cur} — node uncordoned, nothing injected"; }
  ok "deleted ${ns}/${cur}; waiting for CNPG to stall"

  local waited=0 d
  while [[ $waited -lt $INJECT_TIMEOUT ]]; do
    d="$(cnpg_deadlocked)"
    if [[ -n "$d" ]]; then
      # It has to be the cluster we injected into. A detector firing somewhere
      # else is a finding, not a reproduction.
      awk -v n="$ns" -v c="$name" '$1 == n && $2 == c { found = 1 } END { exit !found }' <<<"$d" ||
        die "the detector fired, but not on ${ns}/${name} — it says: ${d}
  Whatever that is, this run did not inject it. ${node} is still cordoned."
      hr; ok "deadlock reproduced after ${waited}s — <ns> <cluster> <target> <gone primary>:"
      printf '   %s\n' "$d"
      info "This is the state the roll unsticks after CNPG_UNSTICK_AFTER (${CNPG_UNSTICK_AFTER:-180}s)."
      info "Clean up with: $(basename "${BASH_SOURCE[0]}") cleanup ${PROVIDER}"
      return 0
    fi
    sleep 10; waited=$((waited + 10))
  done
  # An injection that quietly failed to inject would send someone off to debug a
  # detector against a healthy cluster. Fail, and print what the state really is.
  hr; cnpg_list | sed 's/^/   /' >&2 || true
  die "after ${INJECT_TIMEOUT}s the roll's detector still sees no deadlock (state above).
  ${node} is still cordoned — clean up with: $(basename "${BASH_SOURCE[0]}") cleanup ${PROVIDER}"
}

do_cleanup() {
  local cordoned
  cordoned="$(awk -F'\t' '$3 == "cordoned" { printf "%s ", $1 }' <<<"$NODES_TSV")"
  [[ -n "$cordoned" ]] || { ok "no node is cordoned — nothing to clean up"; return 0; }
  announce "uncordon: ${cordoned}" \
           "pods pinned to those nodes by a local PVC can then be rescheduled there"
  if [[ $DRY_RUN -eq 1 ]]; then ok "dry-run — nothing touched"; return 0; fi
  confirm
  local n
  for n in $cordoned; do
    "${KCTL[@]}" uncordon "$n" || warn "uncordon failed for ${n}"
  done
  ok "uncordoned: ${cordoned}"
  info "CNPG recovers on its own once the pod can come back; check with: $(basename "${BASH_SOURCE[0]}") status ${PROVIDER}"
}

# ==============================================================================
# self-test is the offline half of this lab: it asks nothing of a cluster, and
# it is what the other three subcommands rely on being true.
if [[ "$CMD" == self-test ]]; then
  assert_roll_gates
  ok "the roll's detector and budget gate behave the way this lab reports them"
  exit 0
fi

require_disposable_live_cluster
case "$CMD" in
  status)               do_status ;;
  resume)               do_resume ;;
  inject-cnpg-deadlock) do_inject ;;
  # NOT gated on assert_roll_gates: cleanup is the recovery path, and it has to
  # work when the roll's own code is what is broken.
  cleanup)              do_cleanup ;;
esac
