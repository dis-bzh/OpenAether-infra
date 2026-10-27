#!/usr/bin/env bash
# ==============================================================================
# OpenAether — the rolling replacement's gates and helpers (source this; do not
# execute)
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/roll-gates.sh"
#
# Definitions only. The caller sets what they read when they RUN, not when they
# are defined: KCTL, CP_IPS, WK_IPS, MOD, TUNNEL_OFFSET, STOP_REQUESTED, the
# *_TIMEOUT knobs and POLL. Moved verbatim from rolling-replace.sh so that
# another script can reuse the gates (drain, CNPG, PDB, etcd, plan checks)
# instead of copying them.
# ==============================================================================

# --- logging -----------------------------------------------------------------
info() { printf '▶ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }
hr()   { printf -- '─%.0s' {1..70}; printf '\n'; }

talos_ep() { # <type> <index>
  case "$1" in
    cp)     echo "127.0.0.1:$((50000 + TUNNEL_OFFSET + $2))" ;;
    worker) echo "127.0.0.1:$((50100 + TUNNEL_OFFSET + $2))" ;;
  esac
}

# Kubernetes node name for a private IP. Node NAMES are provider-specific; the
# InternalIP is not, and it is what the tofu state gives us.
k8s_node_for_ip() { # <private-ip>
  local name
  name="$("${KCTL[@]}" get nodes -o jsonpath="{range .items[*]}{.metadata.name}{' '}{range .status.addresses[?(@.type=='InternalIP')]}{.address}{end}{'\n'}{end}" 2>/dev/null \
          | awk -v ip="$1" '$2 == ip { print $1; exit }')"
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}

# ==============================================================================
# Health gates
# ==============================================================================

# What version is this node ACTUALLY running? Empty when it cannot be asked.
#
# `talosctl version` exits 1 whenever the endpoint is unreachable — measured
# 2026-08-18: 1 against a closed port, 1 against a socket that accepts and says
# nothing, 0 only against a live apid. Under `set -euo pipefail` a bare
# assignment from that pipeline therefore KILLS the roll, with no message at
# all: on Outscale it printed the header for the last worker and exited 1, five
# nodes into a six-node upgrade. A probe that cannot answer must say "I do not
# know" and let the caller decide, not take the script down with it.
node_talos_version() { # <endpoint> <node_ip>  → version, or empty
  local out
  out="$(talosctl version -e "$1" -n "$2" --short 2>/dev/null |
         awk '/Server/{f=1} f && /Tag:/{print $2; exit}')" || out=""
  printf '%s' "$out"
}

# Which SCHEMATIC is this node actually running? Empty when it cannot be asked.
#
# The version tag is not the whole identity. The schematic carries the system
# extensions, and the node publishes it as an ExtensionStatus named "schematic"
# — verified against a live node 2026-08-19. Two nodes can report the same Talos
# version from entirely different images, which is how a schematic change became
# undeliverable: every gate compared the tag and called the fleet done.
node_schematic() { # <endpoint> <node_ip>  → schematic id, or empty
  local out
  out="$(talosctl get extensions -e "$1" -n "$2" -o json 2>/dev/null |
         jq -s -r '.[] | select(.spec.metadata.name == "schematic") | .spec.metadata.version' 2>/dev/null)" || out=""
  printf '%s' "${out%%$'\n'*}"
}

# Find a healthy CP endpoint OTHER than the one being replaced.
# Echoes "ep ip" for the first CP (index != exclude) whose etcd service is OK.
healthy_peer_cp() { # <exclude_index>
  local excl="$1" k ep ip
  for k in "${!CP_IPS[@]}"; do
    [[ "$k" == "$excl" ]] && continue
    ep="$(talos_ep cp "$k")"; ip="${CP_IPS[$k]}"
    if talosctl -e "$ep" -n "$ip" service etcd 2>/dev/null | grep -qE 'HEALTH[[:space:]]+OK'; then
      echo "$ep $ip"; return 0
    fi
  done
  return 1
}

# Remove a control-plane node's stale etcd membership from a healthy peer.
# REQUIRED before recreating a CP: tofu destroys the VM WITHOUT a graceful etcd
# leave, so the member lingers (dead peer). The fresh-disk node would then rejoin
# as a NEW member → N+1 members, quorum math broken, gate hangs. Talos auto-rejoins
# the recreated node, so we only need to evict the old member.
#
# `talosctl etcd remove-member` takes the hex MEMBER ID, not the node name. The
# `etcd members` table is: NODE  ID  HOSTNAME  PEER_URLS  CLIENT_URLS  LEARNER —
# so we resolve name→ID by matching HOSTNAME (col 3) and reading ID (col 2).
# Cordon + drain, tolerant of a drain that cannot finish. A PDB with zero allowed
# disruptions (a single-replica workload declaring minAvailable: 1) makes a node
# permanently undrainable, so a drain that must succeed can never roll such a
# cluster. We report it and let the operator decide; talosctl's own drain does
# not, which is why --upgrade runs it with --drain=false and calls this instead.
# CNPG guards its primary with a PodDisruptionBudget that forbids eviction until
# a switchover has happened, and a plain `kubectl drain` does not trigger one —
# so the drain simply times out. Telling the operator a node maintenance is in
# progress is the documented way to say "you may move these": it relaxes the
# budget and lets the instance be recreated, reusing its PVC.
#
# Without this the roll drained for five minutes, gave up, and rebooted the node
# under a live primary — three times in one run on 2026-08-14, which left
# `zitadel-db` stuck in "Switchover in progress" and `grafana-db` with no active
# instance, and took eight Kustomizations down behind them.
# MEASURED on Scaleway 2026-08-15, because "necessary and not sufficient" was
# still not saying WHICH budget refused. With the maintenance window ON, CNPG
# deletes the replica budget and KEEPS `<cluster>-primary` at
# disruptionsAllowed=0 / currentHealthy=1 / expectedPods=1. The primary is
# therefore unevictable on any node, by design, for as long as it is primary —
# which is the 900s drain, exactly.
#
# `spec.enablePDB: false` deletes BOTH, primary included; the operator's own
# webhook recommends it over the maintenance window on every patch. Turning it
# off for the roll lets the drain evict the primary and CNPG fail over to a
# replica — an unplanned failover, which is what a planned node reboot is going
# to cause anyway a few seconds later.
#
# The maintenance window stays alongside it: it is what tells the operator to
# reuse the PVC rather than reprovision the instance elsewhere, which on
# node-local storage it could not do.
# Flux owns the CNPG Cluster objects and reconciles them every 10 minutes, which
# is shorter than a roll: measured on Scaleway 2026-08-15, the budgets were back
# and the drain blocked again three nodes in, because git says enablePDB is on
# and git wins. Suspend the Kustomization that owns them for the duration and
# resume it on the way out. The owner comes from the objects' own Flux labels,
# not a hardcoded name, so a rename does not silently turn this into a no-op.
# Is CNPG even installed? Asked once, explicitly, so that everywhere else a
# failing enumeration can be treated as what it is — an unanswered question, not
# an empty answer. Without this the `|| true` on those queries turned an
# apiserver blip into "no databases to protect", and the roll drained into live
# budgets.
# "Is CNPG installed?" must not answer no because the apiserver was busy: that
# would make the roll skip every database gate and drain blind. A genuine
# NotFound is no; anything else is fatal.
cnpg_installed() {
  local err
  err="$("${KCTL[@]}" get crd clusters.postgresql.cnpg.io 2>&1 >/dev/null)" && return 0
  case "$err" in
    *NotFound* | *"not found"* | *"doesn't have a resource type"*) return 1 ;;
    *) die "cannot tell whether the CNPG CRD exists: ${err%%$'\n'*}" ;;
  esac
}

# The Flux Kustomization(s) owning the CNPG clusters, one "namespace name" per
# line. Dies rather than hand back an empty guess.
# Every Kustomization in the ANCESTRY of the CNPG Cluster objects, not just the
# one that owns them directly.
#
# A Kustomization is itself an object Flux manages, and it carries the same
# ownership labels. Suspending only the immediate owner therefore has a
# reconcile-interval half-life: measured on Scaleway 2026-08-16, `cnpg` carries
# kustomize.toolkit.fluxcd.io/name=openaether-platform, and about ten minutes
# into a forty-minute roll the parent reconciled `cnpg` back to suspend=false,
# `cnpg` then reverted enablePDB to true, the primaries' budgets reappeared, and
# the next drain spent its full 900s being refused. Last session's fix — "suspend
# the owning Kustomization" — was right about the mechanism and one level short.
cnpg_flux_owners() {
  local seeds seen="" queue ns name parent pns pname
  seeds="$("${KCTL[@]}" get clusters.postgresql.cnpg.io -A -o jsonpath='{range .items[*]}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/namespace}{" "}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}{end}' 2>/dev/null)" ||
    die "the CNPG CRD exists but its clusters could not be listed — refusing to roll blind."
  queue="$(sort -u <<<"$seeds")"
  while [[ -n "${queue//[[:space:]]/}" ]]; do
    local next=""
    while read -r ns name; do
      [[ -n "$ns" && -n "$name" ]] || continue
      grep -qxF "$ns $name" <<<"$seen" && continue
      seen+="${ns} ${name}"$'\n'
      # A Kustomization with no owner label is the root — stop there. Only one
      # that is gone ends the chain too: any other failed read would cut the walk
      # short and hide an ancestor, so it dies like the listing above. The value
      # is the last line, in case kubectl printed a warning before it.
      if ! parent="$("${KCTL[@]}" -n "$ns" get kustomizations.kustomize.toolkit.fluxcd.io "$name" \
        -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/namespace}{" "}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}' 2>&1)"; then
        case "$parent" in
          *NotFound* | *"not found"*) continue ;;
          *) die "cannot read the owner of Kustomization ${ns}/${name}: ${parent%%$'\n'*}" ;;
        esac
      fi
      read -r pns pname <<<"${parent##*$'\n'}"
      [[ -n "$pns" && -n "$pname" ]] || continue
      [[ "$pns $pname" == "$ns $name" ]] && continue   # self-owned root
      next+="${pns} ${pname}"$'\n'
    done <<<"$queue"
    queue="$next"
  done
  printf '%s' "$seen"
}

# The CNPG clusters themselves, one "namespace name" per line. Same rule.
cnpg_clusters() {
  "${KCTL[@]}" get clusters.postgresql.cnpg.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null ||
    die "the CNPG CRD exists but its clusters could not be listed — refusing to roll blind."
}

cnpg_flux_suspend() { # <true|false>
  local suspend="$1" ns name order
  cnpg_installed || return 0
  # cnpg_flux_owners lists child first, then its ancestors. Suspend the ANCESTOR
  # first, or the parent can reconcile the child back to suspend=false in the
  # window between the two patches — the very race this walk exists to close.
  # Restore in the other direction, so the parent is the last thing let go.
  [[ "$suspend" == "true" ]] && order="tac" || order="cat"
  cnpg_flux_owners |
    "$order" |
    while read -r ns name; do
      [[ -n "$ns" && -n "$name" ]] || continue
      if "${KCTL[@]}" -n "$ns" patch kustomizations.kustomize.toolkit.fluxcd.io "$name" \
        --type merge -p "{\"spec\":{\"suspend\":${suspend}}}" >/dev/null 2>&1; then
        info "Flux ${ns}/${name}: suspend=${suspend}"
      else
        warn "could not set suspend=${suspend} on Kustomization ${ns}/${name}"
      fi
    done
}

cnpg_maintenance() { # <true|false>
  local on="$1" ns name pdb
  # enablePDB is the INVERSE of "maintenance in progress": budgets off while we
  # roll, back on when we are done.
  [[ "$on" == "true" ]] && pdb=false || pdb=true
  # A cluster without the CNPG CRD is a normal cluster and there is nothing to do.
  cnpg_installed || return 0
  # Suspend BEFORE patching, so there is no window for Flux to undo it.
  [[ "$on" == "true" ]] && cnpg_flux_suspend true
  # `done < <(...)` and not `cnpg_clusters | while`: a pipeline puts the loop in a
  # subshell, where `die` kills only the subshell and the caller sails on.
  local list attempt err
  if ! list="$(cnpg_clusters)"; then
    die "could not list the CNPG clusters to put into maintenance"
  fi
  while read -r ns name; do
    [[ -n "$ns" && -n "$name" ]] || continue
    # RETRY, and keep the reason. This patch goes through CNPG's validating
    # webhook, whose pod has just been evicted by the control-plane roll — so
    # the first attempt of the worker roll can be rejected while the operator is
    # still coming back (Scaleway, 2026-08-16: grafana-db patched, zitadel-db
    # refused, one warning, and a confirmation below that could then only fail).
    # The old code discarded stderr, so the warning named no cause at all.
    for attempt in 1 2 3 4 5 6; do
      if err="$("${KCTL[@]}" -n "$ns" patch clusters.postgresql.cnpg.io "$name" --type merge \
        -p "{\"spec\":{\"enablePDB\":${pdb},\"nodeMaintenanceWindow\":{\"inProgress\":${on},\"reusePVC\":true}}}" 2>&1 >/dev/null)"; then
        info "CNPG ${ns}/${name}: enablePDB=${pdb}, nodeMaintenanceWindow.inProgress=${on}$([[ $attempt -gt 1 ]] && printf ' (attempt %s)' "$attempt")"
        continue 2
      fi
      sleep 5
    done
    # On the way IN this is fatal: the confirmation below cannot pass, so warning
    # and continuing only buys 120 more seconds before the same conclusion. On
    # the way OUT we are already unwinding — say it loudly and finish restoring
    # the other clusters.
    if [[ "$on" == "true" ]]; then
      die "could not set enablePDB=false on ${ns}/${name} after 6 tries: ${err%%$'\n'*}
  The CNPG webhook rejects or cannot be reached. Its operator lives in
  cnpg-system and may still be rescheduling after the control-plane roll."
    fi
    warn "could not restore enablePDB on ${ns}/${name}: ${err%%$'\n'*}"
  done <<<"$list"
  # Resume AFTER restoring, so Flux finds the objects already back where git
  # wants them. assert_restored, from the EXIT trap, checks the resume took.
  [[ "$on" == "true" ]] || cnpg_flux_suspend false

  # ⚠️ The patch returning 0 is not the setting taking effect. On OVH
  # 2026-08-15 both clusters logged enablePDB=false and their budgets were still
  # there ten minutes later, carrying their deploy-time creation timestamp — so
  # they had never been deleted, the roll drained on an assumption that had
  # silently failed, and it cost 900s of eviction retries to find out. The same
  # patch applied by hand afterwards removed them in under thirty seconds, so the
  # mechanism is right and only the confirmation was missing.
  #
  # Confirm on the way IN only; the way out is assert_restored's.
  [[ "$on" == "true" ]] || return 0
  local waited=0 left rc
  while [[ $waited -lt 120 ]]; do
    # ⚠️ The query FAILING is not the budgets being gone. Written with
    # `2>/dev/null || true` first time round, this passed on Scaleway
    # 2026-08-15 right after the control-plane roll — when the apiserver was
    # still settling — and the worker roll then drained into budgets that had
    # never been deleted, 167 refused evictions and a 900s timeout later.
    # Third time today that a swallowed error read as a pass. Keep the exit
    # status: only an ANSWER of "none" counts as none.
    # `if !` and not `x=$(...); rc=$?`: under `set -e` a failing substitution
    # exits the shell AT the assignment, so the rc branch below was dead code —
    # the very defect this block was added to fix, one layer down. Only a
    # compound command's failure is exempt from `set -e`.
    if ! left="$(cnpg_budgets)"; then
      rc=1
    else
      rc=0
    fi
    if [[ $rc -eq 0 && -z "$left" ]]; then
      ok "CNPG budgets are gone — the node can lose a primary"
      return 0
    fi
    [[ $rc -eq 0 ]] || left="(apiserver did not answer)"
    sleep 5; waited=$((waited + 5))
  done
  die "CNPG budgets survived enablePDB=false after 120s: ${left}
  The patch reported success and the operator did not act on it. Draining now
  would retry evictions for ${DRAIN_TIMEOUT} and fail — see docs/upgrade.md
  § 'What actually blocks a drain'. Check the operator in cnpg-system."
}

# The one budget query: the way in (gone?) and the way out (back?) read the same.
cnpg_budgets() {
  "${KCTL[@]}" get pdb -A -l cnpg.io/cluster \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null
}

# What the roll left undone, one problem per line. 2 = no CNPG, nothing to check.
# Scoped to what this script suspends and removes: the owner chain and each
# cluster's -primary budget. A read that fails is a problem, never a pass.
cnpg_unrestored() {
  local owners clusters budgets ns name s rc=0
  cnpg_installed || return 2
  owners="$(cnpg_flux_owners)" && clusters="$(cnpg_clusters)" && budgets="$(cnpg_budgets)" ||
    { echo "the restore could not be read back from the apiserver"; return 1; }
  while read -r ns name; do
    [[ -n "$ns" && -n "$name" ]] || continue
    if ! s="$("${KCTL[@]}" -n "$ns" get kustomizations.kustomize.toolkit.fluxcd.io "$name" \
      -o jsonpath='{.spec.suspend}' 2>/dev/null)"; then
      echo "Kustomization ${ns}/${name} could not be read"; rc=1
    elif [[ "$s" == "true" ]]; then
      echo "Kustomization ${ns}/${name} is still suspended"; rc=1
    fi
  done <<<"$owners"
  while read -r ns name; do
    [[ -n "$ns" && -n "$name" ]] || continue
    [[ " $budgets" == *" ${ns}/${name}-primary "* ]] || { echo "budget ${ns}/${name}-primary is missing"; rc=1; }
  done <<<"$clusters"
  return "$rc"
}

# Polls on the clock, not a count of sleeps: the operator recreates the budgets
# asynchronously, and a read that hangs must not stretch the wait.
assert_restored() {
  local deadline=$((SECONDS + ${RESTORE_TIMEOUT:-120})) out rc line
  while :; do
    # `$(...)`: a die ends only that subshell and reads as a problem. 2>&1 keeps
    # its message with the answer, so a reason repeated by every poll prints once.
    if out="$(cnpg_unrestored 2>&1)"; then rc=0; else rc=$?; fi
    [[ $rc -eq 2 ]] && return 0
    [[ $rc -eq 0 ]] && { ok "CNPG budgets and Flux Kustomizations are restored"; return 0; }
    [[ -n "$out" ]] || out="the restore could not be read back from the apiserver"
    (( SECONDS >= deadline )) && break
    sleep "${RESTORE_POLL:-5}"
  done
  while read -r line; do warn "${line#✗ }"; done <<<"$out"
  return 1
}

# EXIT trap. The restore runs in a subshell so a die in it (apiserver blip) cannot
# end the trap before the check reads what is left; the roll's own status is kept.
# Nothing runs after it, so KCTL can be bounded here: a down apiserver must not
# hold the exit for client-go's own dial timeout on every read.
# Signals: ignored during the restore (a subshell dies on one and abandons it),
# and ending the wait, which runs minutes, instead of queueing behind it.
finish_roll() {
  local rc=$? stopped=$STOP_REQUESTED
  KCTL+=(--request-timeout="${RESTORE_REQUEST_TIMEOUT:-10s}")
  trap '' INT TERM
  # RETRIED until the apiserver reads it back as restored. After a node is destroyed the API load balancer still sends a share
  # of the calls to it, so the one attempt this used to make timed out (lab 27, F-STOCK: "context deadline exceeded") and left
  # Flux suspended and every budget gone, for an operator to find. Every attempt is idempotent; the count and the wait are bounded.
  local try=1 tries="${RESTORE_TRIES:-6}"
  while :; do
    ( cnpg_maintenance false ) || warn "the CNPG/Flux restore did not complete (attempt ${try} of ${tries})"
    # A subshell: cnpg_installed dies on an unanswered CRD lookup, and that must read as "not restored yet", not end the trap.
    ( cnpg_unrestored ) >/dev/null 2>&1 && break
    [[ $? -ne 2 ]] || break
    (( try < tries )) || break
    try=$((try + 1))
    trap 'warn "interrupted: the restore is NOT verified; check the Flux Kustomizations and the CNPG budgets by hand"; exit 130' INT TERM
    sleep "${RESTORE_RETRY_WAIT:-15}"
    trap '' INT TERM
  done
  trap 'warn "interrupted: the restore is NOT verified; check the Flux Kustomizations and the CNPG budgets by hand"; exit 130' INT TERM
  if assert_restored; then
    if [[ $rc -ne 0 ]]; then :
    elif (( stopped )); then
      warn "Stop requested: the roll is not reported complete. A 'stopping before' line above says what is left."
    else
      ok "${ROLL_DONE_MSG:-Rolling replacement complete. Run a state backup:  scripts/ops/backup-state.sh}"
    fi
  elif [[ $rc -eq 0 ]]; then
    rc=1
    if (( stopped )); then
      warn "The roll stopped on request and the restore did not complete. Fix what is named by hand, then"
      warn "re-run to continue; only --upgrade skips the nodes already done."
    else
      warn "The roll itself finished; only the restore did not. Fix what is named by hand; do NOT re-run"
      warn "replacement mode (it replaces every node again). Then run scripts/ops/backup-state.sh, which"
      warn "task cluster-roll skips after a non-zero exit."
    fi
  fi
  exit "$rc"
}

# The CNPG primary used to be switched off the node here, with `kubectl cnpg
# promote`. Removed on 2026-08-15, for two measured reasons:
#
#   * it never ran. Both of its readbacks used `kubectl get cluster`, and on a
#     cluster carrying CAPI that name resolves to clusters.cluster.x-k8s.io, not
#     clusters.postgresql.cnpg.io. The confirmation compared an empty string to
#     the old primary, found them different and declared the primary moved
#     within a second; the "wait until the cluster is whole again" loop could
#     never see a number and always ran its full 600s. The roll then drained a
#     node whose primary had not moved.
#   * the promote itself does nothing here. `kubectl-cnpg promote` (plugin
#     1.23.6, operator 1.23.1) exits 0 and prints "will be promoted", and
#     `status.targetPrimary` does not change. Unexplained; backlog.
#
# `spec.enablePDB: false` in cnpg_maintenance above removes the budget that made
# the primary unevictable, which is what the switchover was for. Nothing here
# needs the plugin any more.

# Wait until every CNPG cluster is whole again before touching the next node.
#
# With the budgets off for the roll, a drain evicts a primary and CNPG fails over
# — normal, and finished in a minute when it is left alone. Arriving at the next
# node before it finishes is what is not: on 2026-08-15 the roll drained a second
# worker while zitadel-db was still electing, and the cluster deadlocked with the
# demoted primary waiting for a switchover and the target replica waiting for WAL
# only a running primary would produce. It cost a hand-deleted pod, twice.
#
# --- the one deadlock CNPG does not get out of by itself -----------------------
#
# Seen FOUR times on 2026-08-15, always the same, always after the node holding a
# primary was drained:
#
#   status.currentPrimary  -> a pod that NO LONGER EXISTS (evicted; its
#                             local-path-retain PVC pins it to the drained node)
#   status.targetPrimary   -> a pod that exists and never becomes ready
#                             (it wants WAL that only a running primary produces)
#   a third instance       -> ready, healthy, ignored
#
# CNPG will not recreate the missing primary while a switchover is pending, and
# the switchover cannot finish without a primary. Restarting the operator does
# nothing. Deleting the TARGET's pod forces a re-evaluation and it resolves in
# about a minute — four times out of four.
#
# So the roll does that itself rather than leaving a human to. The four
# conditions below are ALL required: a narrow unstick, not a "delete pods when
# stuck". It fires once per cluster per roll and says exactly what it did.
CNPG_UNSTICK_AFTER="${CNPG_UNSTICK_AFTER:-180}"   # seconds of no progress first

# "absent" only for a genuine NotFound. An unanswered query is "unknown", which
# must NOT read as "the primary is gone" — that is the premise of the whole test.
cnpg_pod_state() { # <ns> <pod> -> ready | notready | absent | unknown
  local ns="$1" pod="$2" out err
  if err="$("${KCTL[@]}" -n "$ns" get pod "$pod" \
       -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1 >/dev/null)"; then
    out="$("${KCTL[@]}" -n "$ns" get pod "$pod" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ "$out" == "True" ]] && echo ready || echo notready
    return 0
  fi
  case "$err" in
    *NotFound* | *"not found"*) echo absent ;;
    *) echo unknown ;;
  esac
}

# Echoes "<ns> <cluster> <targetPod>" for every cluster in the known deadlock.
cnpg_deadlocked() {
  local ns name cur tgt
  while read -r ns name cur tgt; do
    [[ -n "$ns" && -n "$name" && -n "$cur" && -n "$tgt" ]] || continue
    [[ "$cur" != "$tgt" ]] || continue                              # 1. a switchover is pending
    [[ "$(cnpg_pod_state "$ns" "$cur")" == absent ]] || continue    # 2. the primary pod is gone
    [[ "$(cnpg_pod_state "$ns" "$tgt")" == notready ]] || continue  # 3. the target exists, not ready
    # 4. something else is ready, or there is nothing to elect and deleting the
    #    target would only make it worse.
    #    Listed then filtered in the shell, NOT with a nested jsonpath filter:
    #    kubectl cannot parse `items[?(@.status.conditions[?(...)]...)]` and
    #    answers "unterminated filter", so the first version of this line always
    #    returned empty and the whole unstick could never fire. Found on a live
    #    deadlock 2026-08-15, after the unit tests passed it — a stub answers the
    #    query it is asked, it does not tell you the query is malformed.
    [[ -n "$("${KCTL[@]}" -n "$ns" get pods -l "cnpg.io/cluster=${name}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null |
        awk '$2 == "True" { print $1 }')" ]] || continue
    echo "$ns $name $tgt $cur"
  done < <("${KCTL[@]}" get clusters.postgresql.cnpg.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.currentPrimary}{" "}{.status.targetPrimary}{"\n"}{end}' 2>/dev/null)
}

# The qualified resource name is not optional — see the note above.
CNPG_TIMEOUT="${CNPG_TIMEOUT:-600}"   # seconds

# Every CNPG cluster that is NOT whole, as "<ns>/<name>(ready/instances)" tokens;
# empty output means every one of them is. A non-zero return is a DIFFERENT
# answer — the query failed. Written with `|| true` first time round, a blip
# while the apiserver settles after a control-plane roll emptied the list and
# waved the next drain through.
cnpg_pending() {
  local answer ns name inst ready pending=""
  answer="$("${KCTL[@]}" get clusters.postgresql.cnpg.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.instances}{" "}{.status.readyInstances}{"\n"}{end}' 2>/dev/null)" || return 1
  while read -r ns name inst ready; do
    [[ -n "$ns" && -n "$name" ]] || continue
    # A status that has not been populated must not read as "whole": require
    # real numbers, the way the 0/0 check that used to pass here did not.
    [[ "$inst" =~ ^[1-9][0-9]*$ && "$ready" == "$inst" ]] || pending+="${ns}/${name}(${ready:-?}/${inst:-?}) "
  done <<<"$answer"
  printf '%s' "$pending"
}

wait_cnpg_whole() {
  local waited=0 pending unstuck=0 d
  # The guard its two siblings have and this one did not: on a cluster that
  # never picked the cnpg brick, the query below fails, and under `set -e` the
  # roll dies inside the first cordon_drain having cordoned nothing.
  cnpg_installed || return 0
  while [[ $waited -lt $CNPG_TIMEOUT ]]; do
    pending="$(cnpg_pending)" || pending="(apiserver did not answer)"
    [[ -z "$pending" ]] && { [[ $waited -gt 0 ]] && ok "every CNPG cluster is whole again"; return 0; }
    [[ $waited -eq 0 ]] && info "Waiting for CNPG to finish electing: ${pending}"

    # Give it CNPG_UNSTICK_AFTER to sort itself out first — most failovers are
    # done inside a minute and this must not race a healthy election.
    if [[ $waited -ge $CNPG_UNSTICK_AFTER && $unstuck -eq 0 ]]; then
      while read -r d; do
        [[ -n "$d" ]] || continue
        set -- $d
        warn "CNPG ${1}/${2} is in the known deadlock: primary ${4} pod gone, target ${3} stuck."
        warn "  Deleting ${3} to force a re-election — see docs/upgrade.md."
        if "${KCTL[@]}" -n "$1" delete pod "$3" >/dev/null 2>&1; then
          ok "deleted ${1}/${3}; waiting for the cluster to elect"
          unstuck=1
        else
          warn "could not delete ${1}/${3} — the wait continues and will time out"
        fi
      done < <(cnpg_deadlocked)
    fi

    sleep 10; waited=$((waited + 10))
  done
  warn "after ${CNPG_TIMEOUT}s these CNPG clusters are still not whole: ${pending}"
  warn "  draining the next node now is what deadlocked one on 2026-08-15 —"
  warn "  see docs/upgrade.md § 'A database left \"Failing over\" after the roll'."
}

# The budgets that allow nothing AND can still recover, one
# "<ns>\t<name>\t<healthy>/<expected>\t<selector>" per line.
#
# `currentHealthy < expectedPods` is the whole discriminator, measured on a live
# cluster 2026-08-14. Some budgets sit at zero BY DESIGN and waiting on them
# never ends: a CNPG `*-primary` guards the one pod that must not be evicted, and
# Longhorn mints one `instance-manager-*` per node with minAvailable 1. Those
# read 1/1/1 — as healthy as they will ever be. The ones worth waiting for read
# short: openbao 2 of 3, grafana 0 of 2, vmselect 1 of 2.
#
# Non-zero return = the query failed, which is not "no budget is short". This
# used to be `|| echo '{"items":[]}'`, i.e. an apiserver blip read as headroom.
# The budgets pdb_short deliberately does NOT return: they allow nothing AND are
# not missing a pod, so waiting cannot change them. CNPG's <cluster>-primary is
# one, and it is what cost a full 900s drain on Scaleway 2026-08-16.
#
# DIAGNOSTIC ONLY — do not gate on this. Longhorn keeps a per-node
# instance-manager budget at exactly 1/1 allowing 0, and clears it in RESPONSE to
# the node being cordoned; wait_pdb_headroom runs BEFORE the cordon, so refusing
# on this list would refuse every roll that works today (measured live: it named
# worker-0's instance-manager alongside the real culprit, and worker-0 had just
# drained cleanly). The budget the roll is entitled to demand is gone is a CNPG
# one, and cnpg_maintenance is what asserts that — per node, now.
pdb_hard() {
  local out
  out="$("${KCTL[@]}" get pdb -A -o json 2>/dev/null)" || return 1
  jq -r '.items[]
         | select((.status.disruptionsAllowed // 0) == 0)
         | select((.status.expectedPods // 0) > 0)
         | select((.status.currentHealthy // 0) >= (.status.expectedPods // 0))
         | [ .metadata.namespace, .metadata.name,
             "\(.status.currentHealthy // 0)/\(.status.expectedPods // 0)",
             ((.spec.selector.matchLabels // {}) | to_entries
              | map("\(.key)=\(.value)") | join(",")) ] | @tsv' <<<"$out"
}

pdb_short() {
  local out
  out="$("${KCTL[@]}" get pdb -A -o json 2>/dev/null)" || return 1
  jq -r '.items[]
         | select((.status.disruptionsAllowed // 0) == 0)
         | select((.status.currentHealthy // 0) < (.status.expectedPods // 0))
         | [ .metadata.namespace, .metadata.name,
             "\(.status.currentHealthy // 0)/\(.status.expectedPods // 0)",
             ((.spec.selector.matchLabels // {}) | to_entries
              | map("\(.key)=\(.value)") | join(",")) ] | @tsv' <<<"$out"
}

# Wait until the cluster says it can afford to lose a pod on this node.
#
# Between nodes the roll gates on etcd and Longhorn and on NOTHING else, so it
# arrived at the next node while the previous one's quorum workloads were still
# rejoining — and their budgets correctly refused the eviction. Three runs, three
# different pods, one shape: CNPG replicas and kube-state-metrics (run 8),
# `openbao-1` on a raft budget wanting 2 of 3 (run 9), with no CNPG primary
# involved at all. Fixing them one at a time was chasing symptoms.
#
# `disruptionsAllowed` is the cluster stating the thing directly. Only budgets
# that actually cover a pod ON THIS NODE matter: one stuck elsewhere is not our
# business and waiting on it would be a hang with no cause.
PDB_TIMEOUT="${PDB_TIMEOUT:-600}"   # seconds
wait_pdb_headroom() { # <node_name>
  local node="$1" waited=0 blocked short ns name state sel
  info "Waiting for every budget covering ${node} to allow a disruption…"
  while [[ $waited -lt $PDB_TIMEOUT ]]; do
    blocked=""
    if ! short="$(pdb_short)"; then
      blocked="(apiserver did not answer)"
    else
      while IFS=$'\t' read -r ns name state sel; do
        [[ -n "$ns" && -n "$name" ]] || continue
        # Empty means matchLabels was absent — a matchExpressions-only budget,
        # which none of ours uses. Skip rather than guess; the drain is the judge.
        [[ -n "$sel" ]] || continue
        # A query that FAILED is not "no pod of this budget lives here". Read it
        # as blocking: waiting is recoverable, draining on a wrong answer is not.
        # Same rule as pdb_short above — this was the last line in the file still
        # written the other way, and it is defect #2 of the sweep verbatim.
        #
        # `[*]` and NOT `[0]`: on an empty list kubectl answers "array index out
        # of bounds: index 0, length 0" and exits 1, so `[0]` makes the ORDINARY
        # case — this budget has no pod on this node — indistinguishable from an
        # apiserver failure. With the fail-closed branch above, that is a gate
        # that can never pass: OVH cp-2, 2026-08-16, 600s of
        # "zitadel-db(unreadable)" for a budget whose pods were all on workers.
        # Read it as blocking AND make it unreadable only when it truly is.
        if ! on_node="$("${KCTL[@]}" -n "$ns" get pods -l "$sel" \
              --field-selector "spec.nodeName=${node}" \
              -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"; then
          blocked+="${ns}/${name}(unreadable) "
        elif [[ -n "$on_node" ]]; then
          blocked+="${ns}/${name}(${state}) "
        fi
      done <<<"$short"
    fi
    if [[ -z "$blocked" ]]; then
      ok "every budget covering ${node} allows a disruption"
      return 0
    fi
    sleep 10; waited=$((waited + 10))
  done
  # Fatal, unattended. This used to warn and drain anyway, on the reasoning that
  # the drain names the pods. It does — after another ${DRAIN_TIMEOUT}. On OVH
  # 2026-08-15 that meant 600s of "these budgets allow nothing" followed by 900s
  # of eviction retries against the same budgets, and the same answer at the end.
  # Every budget this gate waits on reads currentHealthy < expectedPods, so a pod
  # is MISSING: draining cannot supply it, and time cannot either.
  warn "after ${PDB_TIMEOUT}s these budgets still allow nothing on ${node}: ${blocked}"
  if [[ $ASSUME_YES -eq 1 ]]; then
    die "refusing to drain ${node} into budgets that already said no.
  Each one above is short of a pod (currentHealthy < expectedPods), so the drain
  would retry evictions for ${DRAIN_TIMEOUT} and reach the same conclusion.
  Fix what is missing, then re-run — nodes already upgraded are skipped."
  fi
  read -rp "Drain ${node} anyway? [y/N] " a; [[ "$a" == [yY] ]] || die "aborted by operator"
}

# Every worker's CPU requests, "<node> <percent>" per line, out of the Allocated
# resources table `kubectl describe node` prints. The percentage is of that
# node's OWN allocatable, so the sum below only means anything while the workers
# share a flavour — which is how every provider module here builds them.
# Non-zero return = the description failed; no worker is a different answer.
worker_cpu_requests() {
  local out
  out="$("${KCTL[@]}" describe nodes -l '!node-role.kubernetes.io/control-plane' 2>/dev/null)" || return 1
  awk '/^Name:/            { n = $2 }
       /^  cpu +[0-9]/     { p = $3; gsub(/[()%]/, "", p); print n, p }' <<<"$out"
}

# ==============================================================================
# Pre-roll survey — everything knowable before the first node is touched
# ==============================================================================
# The per-node gates each block for their own timeout before saying anything, so
# a cluster that could not be rolled at all took wait_cnpg_whole + wait_pdb_
# headroom + the drain to say so — 2100s on OVH 2026-08-15, to be told the three
# workers sat at 78/99/100% of CPU requests, which was true before the roll
# started. The same three questions have answers now. Ask them once, print every
# finding, die once.
#
# Runs AFTER cnpg_maintenance: the CNPG budgets are deliberately gone by then, so
# surveying earlier would report `<cluster>-primary` at zero and refuse a roll
# that is fine.
preflight_roll() {
  local fatal=0 cap nodes=0 total=0 room node pct short ns name state sel pending
  hr
  info "Pre-roll survey: capacity, budgets, databases — all of it, once."

  # 1. Capacity. A drain moves pods; if they have nowhere to go they stay
  # Pending, the budgets they belong to never recover, and the drain waits out
  # its timeout with no eviction error to show for it.
  if ! cap="$(worker_cpu_requests)"; then
    warn "capacity: the workers could not be described — refusing to roll blind."
    fatal=1
  else
    while read -r node pct; do
      [[ -n "$node" && "$pct" =~ ^[0-9]+$ ]] || continue
      info "  ${node}: ${pct}% of CPU requested"
      nodes=$((nodes + 1)); total=$((total + pct))
    done <<<"$cap"
    room=$(( (nodes - 1) * 100 ))
    if [[ $nodes -eq 0 ]]; then
      warn "capacity: no worker answered — is this the cluster the state describes?"
      fatal=1
    elif [[ $nodes -eq 1 ]]; then
      warn "capacity: a single worker, so rolling it takes its workloads down with it."
    elif [[ $total -gt $room ]]; then
      warn "capacity: the ${nodes} workers request ${total}%, and any ${nodes} minus one of them hold ${room}%."
      # Fatal only when this run will actually drain a worker. A --cp-only roll
      # evacuates control planes, whose pods are a small fraction (13-17% of a CP
      # on the clusters measured), and blocking it on worker headroom denies an
      # upgrade the cluster can perfectly well take: Outscale 2026-08-16 could not
      # roll its workers at 99/98/98%, and was refused its CONTROL PLANES for the
      # same reason. Still printed, because a worker roll is what comes next.
      # Defaulted, and defaulted to the FATAL side: the unit harness extracts this
      # function without the globals, and a gate that softens itself because a
      # variable happens to be unset is not a gate.
      if [[ "${SCOPE:-all}" == cp ]]; then
        warn "capacity: not fatal for --cp-only — no worker is drained by this run, but the worker roll will be refused until this changes."
      else
        fatal=1
      fi
    else
      ok "capacity: ${total}% requested, ${room}% available without one worker"
    fi
  fi

  # 2. Budgets, on the same discriminator wait_pdb_headroom waits on. Nothing has
  # been evicted yet, so a budget already short of a pod is a pod already
  # missing: neither the drain nor time can supply it.
  if ! short="$(pdb_short)"; then
    warn "budgets: the apiserver did not answer — an unanswered query is not an empty list."
    fatal=1
  else
    while IFS=$'\t' read -r ns name state sel; do
      [[ -n "$ns" && -n "$name" ]] || continue
      warn "budgets: ${ns}/${name} allows no disruption and is short of a pod (${state})."
      fatal=1
    done <<<"$short"
    [[ -n "$short" ]] || ok "budgets: every budget that could recover allows a disruption"
  fi

  # 3. Databases. One short an instance now is one the first cordon_drain spends
  # its whole CNPG timeout on, and then drains into anyway.
  if ! cnpg_installed; then
    info "  no CNPG CRD — no database to gate on"
  elif ! pending="$(cnpg_pending)"; then
    warn "databases: the CNPG clusters could not be listed — refusing to roll blind."
    fatal=1
  elif [[ -n "$pending" ]]; then
    warn "databases: not whole (ready/instances): ${pending}"
    fatal=1
  else
    ok "databases: every CNPG cluster is whole"
  fi

  [[ $fatal -eq 0 ]] || die "the pre-roll survey found blocking conditions, listed above, and none
  of them gets better by starting: left to the per-node gates each costs
  ${CNPG_TIMEOUT}s + ${PDB_TIMEOUT}s + ${DRAIN_TIMEOUT} of waiting, per node, for the same answer.
  Capacity is a prerequisite — add a worker or a bigger flavour (docs/upgrade.md
  § 'The cluster has to be able to lose a node'). A short budget or a database
  missing an instance means waiting for it to come back, then re-running."
  ok "Pre-roll survey clean"
}

# --- Longhorn RWX: never reboot a node that still holds a share-manager --------
#
# Lab 12 (Scaleway, Longhorn 1.12, Talos 1.14, apps #124): a worker hosting BOTH
# the share-manager pod of an RWX volume and a pod mounting that volume did not
# finish a graceful `talosctl reboot`. Talos stayed in unmountPodMounts, the
# kernel repeating "nfs: server ... not responding" every 30 s, for more than
# 12 minutes (twice; a provider hard reset was needed). The NFS server dies with
# the node's pods, and the client unmount then waits on a server that is gone.
# A drain is the cure only if it has really finished: the share-manager and its
# clients must be OFF the node before anything reboots it. `kubectl drain`
# returns when the evictions are accepted, and a pod stuck terminating on that
# unmount is still "on the node", so this gate looks at what is left.
RWX_CLEAR_TIMEOUT="${RWX_CLEAR_TIMEOUT:-300}"   # seconds
RWX_POLL="${RWX_POLL:-5}"

# "<ns>/<pod>\t<why>" per line: what still sits on <node> that an RWX volume
# ties to it. Dies when it cannot ask: an unanswered query is not an empty list.
rwx_node_residue() { # <node_name>
  local node="$1" pvs pods
  pvs="$("${KCTL[@]}" get persistentvolumes -o json 2>/dev/null)" ||
    die "cannot list the PersistentVolumes to look for Longhorn RWX volumes on ${node} — refusing to reboot blind."
  # --slurpfile, not --argjson: a node's pod list is hundreds of KB and an argv entry over 128 KB fails with
  # "Argument list too long" (lab 13), which would refuse every real reboot.
  pods="$("${KCTL[@]}" get pods -A --field-selector "spec.nodeName=${node}" -o json 2>/dev/null)" ||
    die "cannot list the pods on ${node} to look for Longhorn RWX users — refusing to reboot blind."
  jq -r --slurpfile pods <(printf '%s' "$pods") '
    ([.items[]
      | select(.spec.csi.driver == "driver.longhorn.io"
               and ((.spec.accessModes // []) | index("ReadWriteMany")))
      | "\(.spec.claimRef.namespace)/\(.spec.claimRef.name)"]) as $rwx
    | $pods[0].items[]
    | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(((.metadata.ownerReferences // []) | map(.kind) | index("DaemonSet")) | not)
    | . as $p
    | if (.metadata.labels["longhorn.io/component"] // "") == "share-manager"
      then "\(.metadata.namespace)/\(.metadata.name)\tLonghorn share-manager (the NFS server of an RWX volume)"
      else ([.spec.volumes[]? | .persistentVolumeClaim.claimName // empty
             | select(. as $c | ($rwx | index("\($p.metadata.namespace)/\($c)")))] | .[0]) as $c
           | select($c != null)
           | "\(.metadata.namespace)/\(.metadata.name)\tmounts the RWX claim \($c)"
      end' <<<"$pvs"
}

# Waits for rwx_node_residue to come back empty. Returns 1 on timeout, the
# remaining list on stderr.
wait_rwx_clear() { # <node_name>
  local node="$1" deadline left
  deadline=$((SECONDS + RWX_CLEAR_TIMEOUT))
  while :; do
    left="$(rwx_node_residue "$node")" || return 1
    [[ -z "$left" ]] && return 0
    if (( SECONDS >= deadline )); then
      printf '%s\n' "$left" | sed 's/^/    /' >&2
      return 1
    fi
    sleep "$RWX_POLL"
  done
}

# --- A node that is already dead (task cluster-replace-node) ------------------------------------------------------
# A drain cannot move pods off a machine that does not answer, and the roll's pre-flight demands every node Ready. For a
# dead node the questions are different: can the SURVIVORS carry on while it is rebuilt, and is exactly one node down?
# Fatal: another node NotReady, or (control plane) fewer healthy etcd members than a quorum without this one. Not fatal,
# only printed: the CPU requests, because the pods of the dead node are already Pending somewhere or nowhere, and the
# replacement is what gives them room back.
dead_node_survey() { # <cp|worker> <index> <node_name>
  local t="$1" idx="$2" node="$3" fatal=0 raw others k ep ip healthy=0 need cap name pct total=0 nodes=0
  hr
  info "Survey before replacing the dead node ${node}: the survivors, once."
  if ! raw="$("${KCTL[@]}" get nodes --no-headers 2>/dev/null)" || [[ -z "$raw" ]]; then
    die "the Kubernetes API did not answer - refusing to replace a node blind."
  fi
  others="$(awk -v n="$node" '$1 != n && $2 !~ /^Ready/ {printf "%s ", $1}' <<<"$raw")"
  if [[ -n "$others" ]]; then
    warn "another node is not Ready: ${others}- one node at a time; fix or replace that one first, or this is a zone loss (task failure-domain-check)."
    fatal=1
  else
    ok "every other node is Ready"
  fi
  if [[ "$t" == cp ]]; then
    for k in "${!CP_IPS[@]}"; do
      [[ "$k" == "$idx" ]] && continue
      ep="$(talos_ep cp "$k")"; ip="${CP_IPS[$k]}"
      talosctl -e "$ep" -n "$ip" service etcd 2>/dev/null | grep -qE 'HEALTH[[:space:]]+OK' && healthy=$((healthy + 1))
    done
    need=$(( ${#CP_IPS[@]} / 2 + 1 ))
    if (( healthy >= need )); then
      ok "etcd: ${healthy} healthy member(s) besides ${node}, quorum is ${need}"
    else
      warn "etcd: only ${healthy} healthy member(s) besides ${node}, quorum is ${need}. Replacing a member without a quorum cannot work: this is the etcd disaster-recovery case (task dr-restore-plan), not a replacement."
      fatal=1
    fi
  fi
  if cap="$(worker_cpu_requests)" && [[ -n "$cap" ]]; then
    while read -r name pct; do
      [[ "$pct" =~ ^[0-9]+$ ]] || continue
      info "  ${name}: ${pct}% of CPU requested"
      nodes=$((nodes + 1)); total=$((total + pct))
    done <<<"$cap"
    if (( nodes > 1 && total > (nodes - 1) * 100 )); then
      warn "capacity: the ${nodes} workers request ${total}% and ${nodes} minus one hold $(( (nodes - 1) * 100 ))%: pods of the dead node stay Pending until its replacement is Ready (docs/capacity.md)."
    fi
  fi
  (( fatal == 0 )) || die "the survey found blocking conditions, listed above. Nothing was changed."
  ok "Survey clean - ${node} is the only node down"
}

# Cordon what cannot be drained; the Node object is deleted separately (delete_dead_node_object), AFTER the etcd member of a
# control plane is gone.
cordon_dead() { # <node_name>
  "${KCTL[@]}" cordon "$1" >/dev/null 2>&1 || warn "could not cordon ${1} (it may already be gone) - continuing"
}

# Deleting the Node object of a machine that is gone frees its pods at once (the pod garbage collector removes pods bound to
# a node that no longer exists) instead of after the 5 minute toleration. The new machine registers under the same name.
# A pod on a local-path volume stays Pending until then: its data was on the dead disk.
delete_dead_node_object() { # <node_name>
  if "${KCTL[@]}" get node "$1" >/dev/null 2>&1; then
    "${KCTL[@]}" delete node "$1" --wait=false >/dev/null \
      && ok "Node object ${1} deleted - its pods are freed" || warn "could not delete the Node object ${1}"
  else
    ok "Node object ${1} already gone"
  fi
}

cordon_drain() { # <node_name>
  local node="$1"
  # RE-ASSERT, once per node. cnpg_maintenance ran once for the whole roll, and a
  # roll is forty minutes that reboots every worker: on Scaleway 2026-08-16 the
  # budgets were confirmed gone, worker-0 rebooted, CNPG rebuilt the instances it
  # had lost ("grafana-db(1/2) zitadel-db(1/3)"), and by the time worker-1 was
  # drained its primaries were protected again — 900s of refused evictions. What
  # put them back matters less than the fact that a setting asserted once at the
  # start of a long, disruptive operation is not a setting that holds.
  cnpg_maintenance true
  wait_cnpg_whole
  wait_pdb_headroom "$node"
  info "Cordon + drain ${node}…"
  "${KCTL[@]}" cordon "$node" || die "cordon failed for ${node}"
  if ! "${KCTL[@]}" drain "$node" \
        --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT"; then
    warn "drain did not complete (kubectl's own reason is printed just above; the timeout is ${DRAIN_TIMEOUT}); some pods may be stuck (PDBs?) or refused (a pod without a controller)."
    # Name them instead of asking. Every one of these forbids its last disruption
    # while missing nothing, so it is the drain's answer, and "(PDBs?)" made the
    # operator go and find by hand what the cluster already knew.
    local hard on_node ns name state sel
    if hard="$(pdb_hard)"; then
      while IFS=$'\t' read -r ns name state sel; do
        [[ -n "$ns" && -n "$name" && -n "$sel" ]] || continue
        on_node="$("${KCTL[@]}" -n "$ns" get pods -l "$sel" \
          --field-selector "spec.nodeName=${node}" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" || continue
        [[ -n "$on_node" ]] && warn "  ${ns}/${name} (${state}) allows 0 and is short nothing — blocks ${on_node}"
      done <<<"$hard"
    fi
    # Unattended, this used to answer its own question and carry on. Rebooting a
    # node whose pods REFUSED to move is how a database gets cut off mid-write;
    # a half-rolled cluster is recoverable (this script skips nodes already on
    # the target version), a corrupted one is not. Fail, and name what blocked.
    if [[ $ASSUME_YES -eq 1 ]]; then
      "${KCTL[@]}" get pods --field-selector "spec.nodeName=${node}" -A \
        -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | head -20 >&2 || true
      # Give the node back before dying. Leaving it cordoned blocks the very
      # recovery the message below asks for: the pods this drain evicted are
      # pinned to it by node-local volumes, so while it is unschedulable they
      # stay Pending, their databases stay degraded, and the re-run meets the
      # same refusal. Measured on Scaleway 2026-08-15 — both CNPG clusters were
      # still short an instance an hour later, waiting for a cordon nobody lifted.
      "${KCTL[@]}" uncordon "$node" >&2 || warn "could not uncordon ${node} — do it by hand before re-running"
      # The two causes seen for real, in the order worth checking. Capacity is
      # first because it is the one nothing else reports: on OVH 2026-08-15 the
      # three workers sat at 78/99/100% of CPU requests, so an evicted pod had
      # nowhere to go, its budget never recovered, and the drain waited out its
      # full 900s with no eviction error to show for it.
      worker_cpu_requests >&2 || true
      die "${node} could not be drained (timeout ${DRAIN_TIMEOUT}) — refusing to reboot it under workloads that would not move.
  0. kubectl refused at once: \"cannot delete Pods that declare no controller\" (a bare pod, e.g. left by a test or
     kubectl run) is named in kubectl's message above; delete it, or move it under a Deployment, and re-run.
  1. Capacity: the CPU requests above are per worker. If the others are near
     100%, the evicted pods cannot be rescheduled, so their budgets never
     recover. A rolling upgrade needs one node's worth of spare capacity.
  2. A budget that can never allow a disruption — see docs/upgrade.md
     § 'What actually blocks a drain, and the two gates that clear it'.
  Then re-run this same command: nodes already on the target version are skipped."
    fi
    read -rp "Continue with ${node} anyway? [y/N] " a; [[ "$a" == [yY] ]] || die "aborted by operator"
  fi
  # The drain returned. Is the node really free of Longhorn RWX servers and their
  # clients? Rebooting one that is not is the 12-minute shutdown hang of apps #124.
  info "Checking ${node} holds no Longhorn RWX share-manager or client (up to ${RWX_CLEAR_TIMEOUT}s)…"
  if ! wait_rwx_clear "$node"; then
    "${KCTL[@]}" uncordon "$node" >&2 || warn "could not uncordon ${node} — do it by hand before re-running"
    die "${node} still hosts a Longhorn RWX share-manager or a pod mounting an RWX volume (listed above).
  Rebooting it now hangs Talos in unmountPodMounts on an NFS server that went away with the node
  (lab 12, apps #124: > 12 minutes, a provider hard reset needed). Find why they did not move
  (kubectl -n longhorn-system get pods -o wide | grep share-manager; a PodDisruptionBudget, a
  terminating pod stuck on the mount), fix it, then re-run this same command."
  fi
  ok "${node}: no RWX share-manager or client left"
}

etcd_remove_member() { # <node_name> <node_ip> <exclude_index>
  local node="$1" node_ip="$2" excl="$3" peer ep ip mid
  peer="$(healthy_peer_cp "$excl")" || die "no healthy peer CP to evict etcd member ${node} — refusing to proceed (quorum risk)"
  read -r ep ip <<<"$peer"
  # Match the peer URL first, the hostname only as a fallback. An etcd member
  # keeps the name it joined under, so a node renamed since does not match by
  # name — and the lookup would report "already absent" for a member that is
  # still there, leaving it to be destroyed without ever being evicted.
  mid="$(talosctl -e "$ep" -n "$ip" etcd members 2>/dev/null \
         | awk -v mip="$node_ip" -v h="$node" \
               'index($4, "//" mip ":") > 0 || $3 == h {print $2; exit}')"
  if [[ -z "$mid" ]]; then
    ok "etcd member ${node} already absent (nothing to evict)"; return 0
  fi
  info "Evicting stale etcd member ${node} (ID ${mid}) via cp-${excl}'s peer (${ip})…"
  talosctl -e "$ep" -n "$ip" etcd remove-member "$mid" 2>/dev/null \
    && ok "etcd member ${node} (${mid}) removed" \
    || die "etcd remove-member ${mid} failed — STOP (manual: talosctl -n <healthy-cp> etcd remove-member ${mid})"
}

# --- stop a control plane gracefully BEFORE it is rolled or replaced -------------------------------------------------
#
# Lab 27 sitting 3 (Scaleway, 3 CP + 5 W, ONE lab): at every control-plane replacement of the shipped path 4 or 5 of the
# 5 workers stopped renewing their Lease for 46-91 s, and healthy workers went NotReady. A cordon + drain, then a graceful
# `talosctl shutdown`, then the same replacement gave stalls of 8-9 s and 0 flaps in 2 of 2 replacements, at the price of
# about 4 more minutes per control plane (676-699 s against 434-491 s). docs/resilience.md, "Control-plane flap".
#
# Gates, all of which must hold or the stop is SKIPPED (a warning, and the replacement goes on by its current path, which
# has its own etcd-peer check): at least 3 control planes in the state, EVERY one of them with a healthy etcd, the node
# itself answering, a healthy peer to drive etcd afterwards. A stop never makes a cluster that is not whole smaller.
#
# A failure of the stop never ends the run and never leaves anything behind that the replacement does not already
# handle: the node was cordoned and drained by cordon_drain before this is called, it stays so exactly as in a replacement
# without the stop, and the caller's later steps (etcd member removal, the two applies, uncordon) are unchanged. If the
# shutdown is refused the node is untouched; if it does not stop in time it is on its way to be destroyed anyway.
GRACEFUL_STOP_TIMEOUT="${GRACEFUL_STOP_TIMEOUT:-300}"   # seconds to wait for the node to stop answering
GRACEFUL_STOP_POLL="${GRACEFUL_STOP_POLL:-5}"

# Prints why the stop must not happen and returns 1; returns 0 when every gate holds.
cp_graceful_stop_refusal() { # <index>
  local idx="$1" total="${#CP_IPS[@]}" k ep ip healthy=0
  if (( total < 3 )); then
    echo "only ${total} control plane(s) in the state: with fewer than 3 there is no quorum to protect and nothing for the workers to fall back on"
    return 1
  fi
  for k in "${!CP_IPS[@]}"; do
    ep="$(talos_ep cp "$k")"; ip="${CP_IPS[$k]}"
    if talosctl -e "$ep" -n "$ip" service etcd 2>/dev/null | grep -qE 'HEALTH[[:space:]]+OK'; then
      healthy=$((healthy + 1))
    elif [[ "$k" == "$idx" ]]; then
      echo "the node itself does not report a healthy etcd, so it is not the live control plane this stop is for"
      return 1
    fi
  done
  if (( healthy < total )); then
    echo "only ${healthy} of ${total} control planes report a healthy etcd: stopping one more would leave no margin on etcd quorum"
    return 1
  fi
  return 0
}

# Shut the (already cordoned and drained) control plane down with Talos' own graceful shutdown and wait until it stops
# answering. Always returns 0: see above.
stop_cp_gracefully() { # <node_name> <node_ip> <index>
  local node="$1" node_ip="$2" idx="$3" ep reason deadline gone=0 peer pep
  ep="$(talos_ep cp "$idx")"
  if ! reason="$(cp_graceful_stop_refusal "$idx")"; then
    warn "graceful stop of ${node} SKIPPED: ${reason}. The replacement goes on by its current path (workers may flap while it runs)."
    return 0
  fi
  peer="$(healthy_peer_cp "$idx")" || { warn "graceful stop of ${node} SKIPPED: no healthy peer control plane answers. Continuing by the current path."; return 0; }
  info "Stopping ${node} gracefully (talosctl shutdown): its apiserver closes its connections, so the workers re-dial at once instead of after 46 s…"
  # --force: the node was drained above; Talos's own drain is all-or-nothing and would refuse on a PDB we already judged.
  # --wait=false: the client cannot watch a node that goes away through an SSH tunnel; the wait below asks the endpoint.
  if ! talosctl shutdown -e "$ep" -n "$node_ip" --force --wait=false >/dev/null 2>&1; then
    warn "talosctl shutdown was refused for ${node}: the node is untouched. Continuing by the current path (it stays cordoned until the replacement ends)."
    return 0
  fi
  deadline=$(( SECONDS + GRACEFUL_STOP_TIMEOUT ))
  while (( SECONDS < deadline )); do
    # Stopped = the TLS handshake fails on the node's endpoint while a peer's still answers (tunnels are up).
    if ! oa_talos_endpoint_ok "${ep%%:*}" "${ep##*:}" && [[ -n "$peer" ]]; then
      read -r pep _ <<<"$peer"
      if oa_talos_endpoint_ok "${pep%%:*}" "${pep##*:}"; then gone=1; break; fi
    fi
    sleep "$GRACEFUL_STOP_POLL"
  done
  if (( gone == 1 )); then
    ok "${node} stopped"
  else
    warn "${node} still answers ${GRACEFUL_STOP_TIMEOUT}s after the shutdown order (or no peer answers to prove the tunnels are up). Continuing: the next steps destroy it anyway; it stays cordoned until the replacement ends."
  fi
  return 0
}

# etcd must report all CP members present AND healthy before we touch the next CP.
# Queries each CP in turn until one answers — robust to the CP currently rebooting
# (talosctl -e <tunnel> connects, -n <real-ip> is the node identity apid validates).
# Each member row carries exactly one peer URL on :2380, so that count == members.
# --- etcd leadership, and the order that spares it ----------------------------
#
# Taking a control plane away while it carries the etcd leader forces an
# election, and during an election EVERY apiserver fails — which is what a run
# of consecutive probe failures looks like, as opposed to the intermittent ones
# a single missing backend would cause. Measured 2026-08-20 on a cluster that
# had been bootstrapped once and rolled once: RAFT TERM 13.
#
# So: roll the followers first (the leader is never disturbed, quorum holds at
# 2/3), then hand leadership over deliberately to a peer that is ALREADY
# upgraded, then roll the former leader. One chosen transition instead of three
# suffered.
#
# `talosctl etcd status` has no --output json, and its columns contain spaces
# ("DB SIZE", "IN USE"), so positional parsing is fragile. The two etcd ids are
# the only 16-hex-character fields in the row: the first is this node's own
# MEMBER, the second the cluster's LEADER. VERIFIED against a live cluster.
etcd_member_and_leader() { # <endpoint> <ip> → "<member> <leader>", or empty
  talosctl -e "$1" -n "$2" etcd status 2>/dev/null |
    awk 'NR>1 { o=""; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{16}$/) o = o $i " ";
                if (o != "") { print o; exit } }'
}

etcd_leader_index() { # → index of the CP carrying the leader, or empty
  local k ep ip m l
  for k in "${!CP_IPS[@]}"; do
    ep="$(talos_ep cp "$k")"; ip="${CP_IPS[$k]}"
    read -r m l <<<"$(etcd_member_and_leader "$ep" "$ip")"
    [ -n "${m:-}" ] && [ "$m" = "${l:-}" ] && { printf '%s' "$k"; return 0; }
  done
  return 1
}

cp_roll_order() { # → CP indices, the etcd leader LAST
  local lead k
  lead="$(etcd_leader_index)" || {
    # No leader answered. Say so and keep the declared order rather than
    # inventing one: an unreadable cluster is not a reordering problem.
    warn "could not identify the etcd leader — rolling control planes in index order"
    printf '%s
' "${!CP_IPS[@]}"; return 0; }
  for k in "${!CP_IPS[@]}"; do [ "$k" = "$lead" ] || printf '%s
' "$k"; done
  printf '%s
' "$lead"
}

forfeit_leadership() { # <index> — hand etcd leadership to a peer, and check it moved
  local k="$1" ep ip deadline m l
  ep="$(talos_ep cp "$k")"; ip="${CP_IPS[$k]}"
  info "Handing etcd leadership off ${NODE_PREFIX}-cp-${k} before taking it down…"
  talosctl -e "$ep" -n "$ip" etcd forfeit-leadership >/dev/null 2>&1 || {
    warn "forfeit-leadership was refused — continuing, the election will happen on its own"; return 0; }
  deadline=$(( SECONDS + 30 ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    read -r m l <<<"$(etcd_member_and_leader "$ep" "$ip")"
    [ -n "${m:-}" ] && [ "$m" != "${l:-}" ] && { ok "etcd leadership moved off cp-${k}"; return 0; }
    sleep 2
  done
  # Not fatal: the roll is still correct, it just costs the election we were
  # trying to avoid. Saying so beats pretending the hand-off worked.
  warn "etcd leadership did not move off cp-${k} within 30s — proceeding, expect an election"
}

wait_etcd_healthy() { # <expected_members>
  local want="$1" deadline=$(( SECONDS + ETCD_TIMEOUT ))
  info "Waiting for etcd ${want}/${want} members healthy…"
  while (( SECONDS < deadline )); do
    local k ep ip n
    for k in "${!CP_IPS[@]}"; do
      ep="$(talos_ep cp "$k")"; ip="${CP_IPS[$k]}"
      n="$(talosctl -e "$ep" -n "$ip" etcd members 2>/dev/null | grep -cE ':2380' || true)"
      if [[ "$n" == "$want" ]] \
         && talosctl -e "$ep" -n "$ip" service etcd 2>/dev/null | grep -qE 'HEALTH[[:space:]]+OK'; then
        ok "etcd ${want}/${want} healthy (via cp-${k})"; return 0
      fi
    done
    sleep "$POLL"
  done
  return 1
}

# The API blip of a control-plane roll (#42): etcd 3/3 and a Ready node do not say that THIS node's kube-apiserver
# serves. The load balancer checks TCP 6443 only, so it sends requests to a control plane whose apiserver is not ready
# for up to 75 s (5 checks x 15 s); the next control plane must not be taken down before the one just rebooted serves,
# or two apiservers are out together. These gates ask the cluster, not the node: the kube-apiserver static pod's own
# Ready condition (its readinessProbe is /readyz) and /readyz through the kubeconfig's endpoint, N polls in a row.
apiserver_pod_state() { # <node_name> → ready | notready | absent | unknown
  local r
  if r="$("${KCTL[@]}" -n kube-system get pod "kube-apiserver-$1" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1)"; then
    [[ "$r" == True ]] && echo ready || echo notready
    return 0
  fi
  case "$r" in
    *NotFound* | *"not found"*) echo absent ;;
    *) echo unknown ;;   # an unanswered question is not an absent pod
  esac
}

wait_apiserver_ready() { # <node_name> — the apiserver of this control plane serves, API_STABLE_POLLS polls in a row
  local node="$1" need="${API_STABLE_POLLS:-3}" got=0 deadline=$(( SECONDS + ${API_TIMEOUT:-300} )) st
  info "Waiting for kube-apiserver on ${node} to serve (${need} Ready polls in a row)…"
  while (( SECONDS < deadline )); do
    st="$(apiserver_pod_state "$node")"
    if [[ "$st" == ready ]] && "${KCTL[@]}" get --raw=/readyz >/dev/null 2>&1; then
      got=$(( got + 1 ))
      if (( got >= need )); then ok "kube-apiserver on ${node} serves"; return 0; fi
    else
      got=0
    fi
    sleep "$POLL"
  done
  return 1
}

wait_apiservers_all_ready() { # <expected_control_planes> — before a control plane is touched, every apiserver serves
  local want="$1" need="${API_STABLE_POLLS:-3}" got=0 deadline=$(( SECONDS + ${API_TIMEOUT:-300} )) raw n
  info "Waiting for ${want}/${want} kube-apiservers to serve…"
  while (( SECONDS < deadline )); do
    if raw="$("${KCTL[@]}" -n kube-system get pods -o json 2>/dev/null)"; then
      n="$(jq -r '[.items[] | select(.metadata.name | startswith("kube-apiserver-"))
                   | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$raw" 2>/dev/null)" || n=0
    else
      n=0
    fi
    if [[ "${n:-0}" == "$want" ]]; then
      got=$(( got + 1 ))
      if (( got >= need )); then ok "${want}/${want} kube-apiservers serve"; return 0; fi
    else
      got=0
    fi
    sleep "$POLL"
  done
  return 1
}

# Is the upgrade CONFIRMED, or merely apparent?
#
# "The node reports the new version and is Ready" is not "Talos accepted the
# upgrade". Talos boots the new system with a META `Upgrade` tag (key 6) naming
# the partition to fall back to, and deletes it only once the node reaches
# Stage=Running — drop_upgrade_fallback.go requires `Stage == MachineStageRunning
# && Status.Ready`. While that tag is set, THE NEXT REBOOT REVERTS THE NODE.
#
# Measured 2026-08-19 on OVH: six nodes healthy, Ready, reporting v1.13.8, every
# one stuck at Stage=Booting because a system extension never started, and five
# still carrying Upgrade=A. One rebooted and came back on the old version. The
# roll had called all six done.
#
# So this asks for the STAGE, not for readiness, and names the service holding
# the boot sequence when it is not running.
assert_upgrade_confirmed() { # <endpoint> <node_ip> <node_name>
  local ep="$1" ip="$2" name="$3" stage="" tag="" deadline=$(( SECONDS + UPGRADE_CONFIRM_TIMEOUT ))
  while (( SECONDS < deadline )); do
    stage="$(talosctl get machinestatus -e "$ep" -n "$ip" -o json 2>/dev/null | jq -r '.spec.stage // empty')" || stage=""
    [[ "$stage" == "running" ]] && break
    sleep "$POLL"
  done
  if [[ "$stage" != "running" ]]; then
    warn "${name} is Ready and reports the new version, but its Talos stage is '${stage:-unknown}', not 'running'."
    warn "  Talos drops the upgrade fallback only at stage=running, so THIS NODE WILL REVERT on its next reboot."
    warn "  The boot sequence is blocked. Services not up:"
    talosctl services -e "$ep" -n "$ip" 2>/dev/null | awk 'NR>1 && $3 != "Running" {print "      " $2 "  " $3}' >&2 || true
    die "refusing to continue: ${name}'s upgrade is not confirmed.
  Every later node would be rolled on the same false signal. A system extension
  that never starts blocks startAllServices — fix that, then re-run."
  fi
  tag="$(talosctl get metakeys -e "$ep" -n "$ip" -o json 2>/dev/null | jq -s -r '.[] | select(.metadata.id == 6) | .spec.value')" || tag=""
  if [[ -n "$tag" ]]; then
    warn "${name} reached stage=running but still carries META Upgrade=${tag} — do not trust it across a reboot."
  else
    ok "${name}: upgrade confirmed by Talos (stage=running, fallback dropped)"
  fi
}

wait_node_ready() { # <node_name>
  local node="$1" deadline=$(( SECONDS + NODE_READY_TIMEOUT ))
  info "Waiting for node ${node} Ready…"
  while (( SECONDS < deadline )); do
    if "${KCTL[@]}" get node "$node" >/dev/null 2>&1; then
      local st
      st="$("${KCTL[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
      [[ "$st" == "True" ]] && { ok "node ${node} Ready"; return 0; }
    fi
    sleep "$POLL"
  done
  return 1
}

# No Longhorn volume may be stuck faulted; degraded is tolerated transiently but
# must clear before we proceed (rebuild finished).
wait_longhorn_healthy() {
  local deadline=$(( SECONDS + LONGHORN_TIMEOUT ))
  # Longhorn CRD absent (e.g. before storage layer) → nothing to gate on.
  "${KCTL[@]}" get crd volumes.longhorn.io >/dev/null 2>&1 || { ok "Longhorn not present — skipping volume gate"; return 0; }
  info "Waiting for Longhorn volumes to leave degraded/faulted…"
  while (( SECONDS < deadline )); do
    local faulted bad
    faulted="$("${KCTL[@]}" get volumes.longhorn.io -n longhorn-system -o json 2>/dev/null \
      | jq -r '[.items[] | select(.status.robustness=="faulted")] | length' 2>/dev/null || echo 0)"
    bad="$("${KCTL[@]}" get volumes.longhorn.io -n longhorn-system -o json 2>/dev/null \
      | jq -r '[.items[] | select(.status.robustness=="degraded")] | length' 2>/dev/null || echo 0)"
    [[ "$faulted" -gt 0 ]] && die "Longhorn has ${faulted} FAULTED volume(s) — aborting (manual recovery needed)"
    if [[ "$bad" == "0" ]]; then ok "Longhorn volumes healthy"; return 0; fi
    sleep "$POLL"
  done
  warn "Longhorn still has degraded volumes after ${LONGHORN_TIMEOUT}s"
  return 1
}

# ==============================================================================
# Per-node replacement
# ==============================================================================

# All state resources of THIS node under module.<mod>[0]: the VM/instance and its
# NIC/port (named exactly <tf_t>[i]) plus, for workers, the volume attach/link
# resources (named worker_data["w<i>-d<k>"]) — but NOT the data volumes themselves, which
# must survive the replacement.
node_targets() { # <tf_t> <index>
  tofu state list 2>/dev/null | grep -F "module.${MOD}[0]." | awk -v t="$1" -v i="$2" '
    $0 ~ ("\\." t "\\[" i "\\]$") { print; next }
    t == "worker" && $0 ~ ("\\.worker_data\\[\"w" i "-d[0-9]+\"\\]$") \
      && $0 !~ /(scaleway_block_volume|openstack_blockstorage_volume_v3|outscale_volume)\./ { print }
  '
}

# How many of these state addresses tofu holds as TAINTED: a create that failed halfway, e.g. a provider out of stock for the
# instance type after the old VM was destroyed (lab 27, F-STOCK). `tofu state show` opens with "# <address>: (tainted)".
# The next plan then deletes that leftover as well as the resource it was asked to replace, which the destroy guard counts.
tainted_count() { # <state address>...
  local a first n=0
  for a in "$@"; do
    first="$(tofu state show -no-color "$a" 2>/dev/null | sed -n 1p)" || first=""
    [[ "$first" == *"(tainted)"* ]] && n=$((n + 1))
  done
  echo "$n"
}

# Node-scoped resources (cp/worker, by name) of any node but <t> <i> that a plan
# changes. `-target` pulls in dependencies, and a pending in-place update of the
# other nodes rides along: raising instance_type and rolling `--workers-only`
# resized all three control planes at once (Scaleway, 2026-10-02, API down 56 s).
# The destroy count cannot see it: a resize destroys nothing.
foreign_changes() { # <planfile> <t: cp|worker> <i>
  tofu show -json "$1" 2>/dev/null | jq -r --arg t "$2" --argjson i "$3" '
    def cls: if test("(^|_)(cp|control_plane)(_|$)") then "cp"
             elif test("(^|_)worker(_|$)") then "worker" else empty end;
    # A data volume is keyed "w<worker>-d<disk>": it belongs to that worker.
    def node: if (.index | type) == "string"
              then ((.index | capture("^w(?<n>[0-9]+)-d[0-9]+$").n | tonumber) // -1)
              else (.index // -1) end;
    .resource_changes[]?
    | select(.mode == "managed" and (.change.actions | any(. != "no-op")))
    | select(((.name // "") | cls) as $c | $c != $t or node != $i)
    | .address' 2>/dev/null
}

# Plan to a file, count what THAT file destroys, refuse a change to any other
# node, apply THAT file. An `apply -auto-approve` re-plans, so the count guarded
# a plan nobody applied, and OpenTofu cannot refuse a plan whose state moved
# unless it is handed the file. `check` plans and judges only, applying nothing.
saved_plan_apply() { # <label> <t> <i> <max-destroy> <on-apply-failure> <apply|check> <tofu plan args…>
  local label="$1" t="$2" i="$3" max="$4" fail="$5" mode="$6"; shift 6
  local dir pf doomed foreign
  dir="$(mktemp -d)"; pf="${dir}/${label}.tfplan"   # 0700: a plan holds secrets
  # `if !`, not `x="$(…)" || …` alone: under set -e a failed plan must reach die.
  if ! tofu plan -out="$pf" "$@" -var-file="$TFVARS" -var talos_bootstrap=true \
       -no-color >/dev/null 2>&1; then
    rm -rf "$dir"; die "could not plan ${label} — refusing to apply blind"
  fi
  doomed="$(tofu show -json "$pf" 2>/dev/null \
    | jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' 2>/dev/null)" \
    || doomed=""
  if [[ ! "$doomed" =~ ^[0-9]+$ ]]; then
    rm -rf "$dir"; die "could not read the saved plan for ${label} — refusing to apply blind"
  fi
  if (( doomed > max )); then
    rm -rf "$dir"
    die "plan ${label} destroys ${doomed} resources (at most ${max} expected) — refusing.
  Something outside this node is being pulled in; a module-level depends_on has
  done exactly that before. Inspect with:
    tofu plan $* -var-file='${TFVARS}' -var talos_bootstrap=true"
  fi
  foreign="$(foreign_changes "$pf" "$t" "$i")" \
    || { rm -rf "$dir"; die "could not read which nodes the saved plan for ${label} changes — refusing to apply blind"; }
  if [[ -n "$foreign" ]]; then
    rm -rf "$dir"
    die "plan ${label} also changes other nodes — refusing, nothing applied:
$(sed 's/^/    /' <<<"$foreign")
  A pending in-place change (an instance_type raised in the tfvars) rides along
  with the targeted apply and would hit those nodes all at once. Put the tfvars
  back as the cluster runs, or change one node at a time (docs/upgrade.md)."
  fi
  # A caller that knows the exact set it expects (the shrink) can say so: the plan path is its argument.
  if [[ -n "${PLAN_ASSERT:-}" ]] && ! "$PLAN_ASSERT" "$pf"; then
    rm -rf "$dir"; die "plan ${label} is not the plan this step expects — nothing applied"
  fi
  if [[ "$mode" == check ]]; then
    rm -rf "$dir"; ok "plan ${label} stays inside ${t}[${i}]"; return 0
  fi
  ok "plan ${label} destroys ${doomed} resource(s), at most ${max} expected — applying that plan"
  tofu apply "$pf" || { rm -rf "$dir"; die "$fail"; }
  rm -rf "$dir"
}
