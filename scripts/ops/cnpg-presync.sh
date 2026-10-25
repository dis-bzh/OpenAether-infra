#!/usr/bin/env bash
# ==============================================================================
# cnpg-presync.sh enables the 0.4.0 synchronous replication on the LIVE CloudNativePG Clusters of a 0.3.x platform, BEFORE the
# apps ref moves to 0.4.0 (study LAB-B2, 2026-10-24; docs/upgrade.md "From 0.3.x to 0.4.0").
#
# WHY IT EXISTS. The 0.4.0 apps content changes the pod spec of a Cluster (Barman Cloud plugin sidecar, ObjectStore archive) AND its
# PostgreSQL configuration (`synchronous`) in ONE Flux apply. On a reduced lab (single k3s node per VM, no Flux, no Talos) that
# combination stuck zitadel-db and grafana-db for good: the operator waits, without a timeout, for every pod to report the same
# configuration hash and one pod's reload is lost (cloudnative-pg#11627); a plugin entry then freezes every pod that predates the
# sidecar. Enabling `synchronous` FIRST, as a separate step that only needs a configuration reload, leaves the ref move changing
# pods but not the PostgreSQL configuration. Measured twice on that reduced lab: 54-57 s, no write gap; then the ref move, both
# Clusters healthy 95-100 s later, write gap 17.7-21.8 s, 0 acknowledged commits lost, WAL archive contiguous. Rung here: the
# script is MOCKED offline; the full platform (Flux, Talos, Cilium, zones, real load) has NOT re-proven it.
#
# WHICH CLUSTERS. Every postgresql.cnpg.io Cluster that carries the label openaether.io/managed=true in the platform namespaces
# (OA_CNPG_NAMESPACES, default foundation-databases), except the Clusters of a database profile (label openaether.io/db-profile:
# they are created by the 0.4.0 content itself, with their own durability) and the restore-test copies (rt-*). No Cluster is named
# here: what is selected is what the content manages.
#
# WHAT IT DOES. The target is the 0.4.0 block spec.postgresql.synchronous = {method any, number 1, dataDurability required,
# failoverQuorum true}. Dry run (default): reads each Cluster's live block and prints the difference; writes nothing.
# --apply: merge-patches ONLY spec.postgresql.synchronous and spec.smartShutdownTimeout (and instances with --scale) of the differing Clusters, then waits per Cluster for: phase healthy,
# readyInstances = spec.instances, `show synchronous_standby_names` not empty on the primary, every replica `quorum`/`sync` in
# pg_stat_replication. Not converged after OA_PRESYNC_KICK_AFTER (120 s): `select pg_reload_conf()` on every instance (break-glass
# R1, cloudnative-pg#11627), then waits again. Not converged at OA_PRESYNC_TIMEOUT (300 s): fails and PRINTS the break-glass R2 steps.
# It never deletes a pod, never forces anything, never promotes or switches over. No secret is read or printed (the SQL asked is
# `show synchronous_standby_names`, `select application_name, sync_state from pg_stat_replication`, `select pg_reload_conf()`).
#
# INSTANCES. With dataDurability required and ANY 1, a Cluster of fewer than 3 instances blocks every write when its only replica is
# lost, so the 0.4.0 content declares 3 (grafana-db-cluster.yaml: instances 3; a 0.3.x grafana-db has 2). Without --scale the script
# refuses (exit 2) and names the command. --scale patches `instances: 3` in the SAME patch as the study and lab 27 measured (lab 27:
# 2 min 22 s, healthy, sync names set; the order "scale, wait, then synchronous" was never measured). `cluster-up` passes --scale
# under APPROVE=auto (and after the typed yes): the head declares 3, and the stop it replaced was worse than the scale (lab 27, FA:
# Flux reverted the presync while the run was stopped). --scale touches only Clusters below 3; every other refusal stays.
#
# SMART SHUTDOWN (lab 27, FI). The same patch sets spec.smartShutdownTimeout (OA_PRESYNC_SMART_SHUTDOWN, default 5 s) BEFORE the move.
# The in-place restart of the primary that the plugin sidecar forces waited out the 180 s default with the Zitadel pool connected
# (206 s write gap). The instance manager reads the value from its cached Cluster object at shutdown (CNPG pkg/management/postgres/
# instance.go, TryShuttingDownSmartFast), so no restart is needed to apply it: the patch reaches the instance manager at its next
# Cluster reconcile, seconds before the ref moves. UNVERIFIED on a cluster until the next lab.
#
# PRECONDITIONS (checked on --apply, reported on the dry run; any one refuses with exit 2):
#   - every selected Cluster is healthy with readyInstances = instances;
#   - a completed Backup of each differing Cluster is younger than OA_PRESYNC_BACKUP_MAX_AGE (86400 s): else take one
#     (kubectl cnpg backup <name> -n <ns> --method barmanObjectStore) and run `task backup-verify`;
#   - no Talos or Kubernetes roll is pending or under way (oa_roll_gate, the gate of cluster-bootstrap-sync);
#   - no pod predates the plugin sidecar while a plugin is enabled in the Cluster spec: such a pod cannot act on a promote or a
#     switchover (the study's E3/E4/E5 dead-locks); the advice is R1/R2, never a promote.
#
# Usage: cnpg-presync.sh --tfvars FILE [--apply] [--scale]
#   exit 0  nothing to do: no CNPG Cluster is managed here (a new cluster), or every one already has the block (or it was applied and converged)
#   exit 3  dry run found a difference (nothing written)
#   exit 2  refused by a precondition (nothing written)
#   exit 1  any other failure (API unreachable, no kubeconfig, patch refused, not converged at the timeout: break-glass printed)
# Env: OA_CNPG_NAMESPACES, OA_PRESYNC_BACKUP_MAX_AGE, OA_PRESYNC_KICK_AFTER, OA_PRESYNC_TIMEOUT, OA_PRESYNC_POLL, OA_NOW (tests).
# KUBECONFIG is the cluster directory's, never the caller's.
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
NAMESPACES="${OA_CNPG_NAMESPACES:-foundation-databases}"
BACKUP_MAX_AGE="${OA_PRESYNC_BACKUP_MAX_AGE:-86400}"
KICK_AFTER="${OA_PRESYNC_KICK_AFTER:-120}"
TIMEOUT="${OA_PRESYNC_TIMEOUT:-300}"
POLL="${OA_PRESYNC_POLL:-5}"
NOW="${OA_NOW:-$(date +%s)}"
MIN_INSTANCES=3
# The planned-shutdown bound (lab 27, FI): PostgreSQL gets this many seconds of smart shutdown, then a fast one. The 0.4.0 Cluster
# specs declare the same number (apps/components/cnpg-bounded-shutdown); keep the two equal.
SHUTDOWN="${OA_PRESYNC_SMART_SHUTDOWN:-5}"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=../lib/pins.sh
source "$ROOT/scripts/lib/pins.sh"

APPLY=0; SCALE=0; TFVARS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --scale) SCALE=1 ;;
    --tfvars) shift; TFVARS="${1:-}" ;;
    -h|--help) sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown argument: $1 (usage: cnpg-presync.sh --tfvars FILE [--apply] [--scale])" >&2; exit 1 ;;
  esac
  shift
done
fail() { echo "✗ $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -n "$TFVARS" ] || fail "--tfvars FILE is required"
for v in BACKUP_MAX_AGE KICK_AFTER TIMEOUT NOW SHUTDOWN; do
  case "${!v}" in *[!0-9]*|"") fail "$v must be whole seconds" ;; esac
done
export KUBECONFIG="$CLUSTER_DIR/kubeconfig"
[ -s "$KUBECONFIG" ] || fail "no kubeconfig at infrastructure/opentofu/cluster/kubeconfig (task kubeconfig PROVIDER=… ROLE=…)"

WANT='{"method":"any","number":1,"dataDurability":"required","failoverQuorum":true}'
ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT

# --- the Clusters this content manages ---------------------------------------------------------------------------------------
declare -a C_NS=() C_NAME=() C_JSON=()
for ns in $NAMESPACES; do
  if ! out="$(kubectl -n "$ns" get clusters.postgresql.cnpg.io -l openaether.io/managed=true -o json 2>"$ERR")"; then
    # No CRD yet: a cluster whose CNPG operator is not installed has nothing to presync. Anything else is not an answer.
    if grep -qiE "doesn't have a resource type|no matches for kind|could not find the requested resource" "$ERR"; then continue; fi
    fail "cannot list the CNPG Clusters of $ns: $(head -c 300 "$ERR")"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    C_NS+=("$ns"); C_NAME+=("$(jq -r '.metadata.name' <<<"$line")"); C_JSON+=("$line")
  done < <(jq -c '.items[] | select(((.metadata.labels["openaether.io/db-profile"] // "") == "") and (.metadata.name | startswith("rt-") | not))' <<<"$out")
done
[ "${#C_NAME[@]}" -gt 0 ] || exit 0

has_block() { # <cluster json> — does the live Cluster hold the four 0.4.0 values AND the bounded smart shutdown
  jq -e --argjson w "$WANT" --argjson t "$SHUTDOWN" '(.spec.postgresql.synchronous // {}) as $s | all($w | to_entries[]; $s[.key] == .value) and (.spec.smartShutdownTimeout == $t)' <<<"$1" >/dev/null
}
healthy() { # <cluster json>
  jq -e '.status.phase == "Cluster in healthy state" and (.status.readyInstances // 0) == (.spec.instances // 1)' <<<"$1" >/dev/null
}

# --- the difference ------------------------------------------------------------------------------------------------------------
declare -a DIFFERS=()
echo "CNPG Clusters of the platform (label openaether.io/managed, namespaces: $NAMESPACES) against the 0.4.0 synchronous block:"
for i in "${!C_NAME[@]}"; do
  n="${C_NS[$i]}/${C_NAME[$i]}"; inst="$(jq -r '.spec.instances // 1' <<<"${C_JSON[$i]}")"
  if has_block "${C_JSON[$i]}"; then
    printf '  = %s: synchronous block present, %s instance(s)\n' "$n" "$inst"
  else
    live="$(jq -c '.spec.postgresql.synchronous // "(none)"' <<<"${C_JSON[$i]}")"
    printf '  ~ %s: synchronous is %s, want %s; smartShutdownTimeout is %s, want %s; %s instance(s)\n' "$n" "$live" "$WANT" \
      "$(jq -r '.spec.smartShutdownTimeout // "(default 180)"' <<<"${C_JSON[$i]}")" "$SHUTDOWN" "$inst"
    DIFFERS+=("$i")
  fi
done
if [ "${#DIFFERS[@]}" -eq 0 ]; then
  echo "✓ every managed Cluster already has the synchronous block: nothing to presync."
  exit 0
fi

# --- preconditions: collected, so the dry run says what an apply would meet --------------------------------------------------------
REASONS=""
add() { REASONS="${REASONS}${REASONS:+$'\n'}$*"; }
roll="$(oa_roll_gate "$CLUSTER_DIR" "$TFVARS")"
[ -z "$roll" ] || while IFS= read -r l; do add "a Talos or Kubernetes roll may be under way: $l"; done <<<"$roll"
for i in "${!C_NAME[@]}"; do
  ns="${C_NS[$i]}"; name="${C_NAME[$i]}"; j="${C_JSON[$i]}"
  healthy "$j" || add "$ns/$name is not healthy ($(jq -r '(.status.phase // "no phase") + ", ready " + ((.status.readyInstances // 0) | tostring) + "/" + ((.spec.instances // 1) | tostring)' <<<"$j")): never change a Cluster that is not"
  # A plugin in the spec and a pod without its sidecar: that pod cannot reload, demote or act on a switchover.
  if jq -e '(.spec.plugins // []) | length > 0' <<<"$j" >/dev/null; then
    if ! pods="$(kubectl -n "$ns" get pods -l "cnpg.io/cluster=$name" -o json 2>"$ERR")"; then
      add "$ns/$name: the pods cannot be read, whether one predates the plugin sidecar is UNKNOWN"
    else
      old="$(jq -r '[.items[] | select(([.spec.containers[].name] | index("plugin-barman-cloud")) == null) | .metadata.name] | join(" ")' <<<"$pods")"
      [ -z "$old" ] || add "$ns/$name: pod(s) $old predate the plugin sidecar while the plugin is enabled: they cannot act on a promote or a switchover; do NOT promote or switch over, use the break-glass steps (docs/upgrade.md)"
    fi
  fi
done
for i in "${DIFFERS[@]}"; do
  ns="${C_NS[$i]}"; name="${C_NAME[$i]}"
  inst="$(jq -r '.spec.instances // 1' <<<"${C_JSON[$i]}")"
  if [ "$inst" -lt "$MIN_INSTANCES" ] && [ "$SCALE" -ne 1 ]; then
    add "$ns/$name has $inst instance(s): with dataDurability required, losing the only replica would block every write. The 0.4.0 content declares $MIN_INSTANCES. Not scaled here on a guess; scale and sync in the one patch the study measured: task cnpg-presync PROVIDER=… ROLE=… APPLY=1 SCALE=1"
  fi
  if ! bk="$(kubectl -n "$ns" get backups.postgresql.cnpg.io -o json 2>"$ERR")"; then
    add "$ns/$name: the Backups cannot be read ($(head -c 200 "$ERR")): whether a recent one exists is UNKNOWN"
  else
    recent="$(jq -r --arg c "$name" --argjson now "$NOW" --argjson max "$BACKUP_MAX_AGE" '
      [.items[] | select(.spec.cluster.name == $c and .status.phase == "completed" and (.status.stoppedAt // "") != "")
       | (.status.stoppedAt | fromdateiso8601) | select(($now - .) <= $max)] | length' <<<"$bk")"
    [ "${recent:-0}" -gt 0 ] || add "$ns/$name has no completed Backup younger than ${BACKUP_MAX_AGE} s. Take one: kubectl cnpg backup $name -n $ns --method barmanObjectStore, then run: task backup-verify"
  fi
done

if [ "$APPLY" -ne 1 ]; then
  [ -z "$REASONS" ] || printf 'An apply would be REFUSED:\n%s\n' "$(sed 's/^/  - /' <<<"$REASONS")"
  echo "✗ ${#DIFFERS[@]} Cluster(s) run without the 0.4.0 synchronous settings. NOTHING was written (dry run)." >&2
  echo "  Enable them BEFORE the apps ref moves: task cnpg-presync PROVIDER=… ROLE=… APPLY=1" >&2
  exit 3
fi
if [ -n "$REASONS" ]; then
  printf '✗ Not applied. Refused:\n%s\n' "$(sed 's/^/  - /' <<<"$REASONS")" >&2
  exit 2
fi

# --- apply ---------------------------------------------------------------------------------------------------------------------
patch_for() { # <cluster json>
  if [ "$(jq -r '.spec.instances // 1' <<<"$1")" -lt "$MIN_INSTANCES" ]; then
    jq -nc --argjson w "$WANT" --argjson n "$MIN_INSTANCES" --argjson t "$SHUTDOWN" '{spec: {instances: $n, smartShutdownTimeout: $t, postgresql: {synchronous: $w}}}'
  else
    jq -nc --argjson w "$WANT" --argjson t "$SHUTDOWN" '{spec: {smartShutdownTimeout: $t, postgresql: {synchronous: $w}}}'
  fi
}
for i in "${DIFFERS[@]}"; do
  ns="${C_NS[$i]}"; name="${C_NAME[$i]}"
  kubectl -n "$ns" patch clusters.postgresql.cnpg.io "$name" --type merge -p "$(patch_for "${C_JSON[$i]}")" >/dev/null 2>"$ERR" \
    || fail "patch of $ns/$name refused: $(head -c 300 "$ERR")"
  echo "▶ $ns/$name: spec.postgresql.synchronous and spec.smartShutdownTimeout=$SHUTDOWN patched (only those$([ "$(jq -r '.spec.instances // 1' <<<"${C_JSON[$i]}")" -lt "$MIN_INSTANCES" ] && echo " and instances $MIN_INSTANCES (--scale)"))"
done

psql_on() { # <ns> <pod> <sql>
  timeout 60 kubectl -n "$1" exec "$2" -c postgres -- psql -U postgres -Atc "$3" 2>/dev/null
}
converged() { # <ns> <name> — prints why not on stdout and returns 1
  local ns="$1" name="$2" j prim sn st want
  j="$(timeout 60 kubectl -n "$ns" get clusters.postgresql.cnpg.io "$name" -o json 2>/dev/null)" || { echo "the Cluster cannot be read"; return 1; }
  has_block "$j" || { echo "the synchronous block is not on the Cluster"; return 1; }
  healthy "$j" || { echo "$(jq -r '(.status.phase // "no phase") + ", ready " + ((.status.readyInstances // 0) | tostring) + "/" + ((.spec.instances // 1) | tostring)' <<<"$j")"; return 1; }
  prim="$(jq -r '.status.currentPrimary // ""' <<<"$j")"; [ -n "$prim" ] || { echo "no current primary"; return 1; }
  sn="$(psql_on "$ns" "$prim" "show synchronous_standby_names")" || { echo "cannot ask the primary $prim"; return 1; }
  [ -n "$sn" ] || { echo "synchronous_standby_names is empty on $prim"; return 1; }
  st="$(psql_on "$ns" "$prim" "select application_name, sync_state from pg_stat_replication")" || { echo "cannot read pg_stat_replication on $prim"; return 1; }
  want=$(( $(jq -r '.spec.instances // 1' <<<"$j") - 1 ))
  [ "$(grep -cE '\|(quorum|sync)$' <<<"$st" || true)" -ge "$want" ] || { echo "fewer than $want replica(s) quorum/sync in pg_stat_replication"; return 1; }
  return 0
}
reload_all() { # <ns> <name> — R1
  local ns="$1" name="$2" j p
  j="$(timeout 60 kubectl -n "$ns" get clusters.postgresql.cnpg.io "$name" -o json 2>/dev/null)" || return 0
  for p in $(jq -r '.status.instanceNames[]? // empty' <<<"$j"); do
    psql_on "$ns" "$p" "select pg_reload_conf()" >/dev/null || echo "  ⚠ reload on $p failed" >&2
  done
}
break_glass() { # <ns> <name>
  local ns="$1" name="$2" j prim reps
  j="$(timeout 60 kubectl -n "$ns" get clusters.postgresql.cnpg.io "$name" -o json 2>/dev/null || echo '{}')"
  prim="$(jq -r '.status.currentPrimary // "<primary>"' <<<"$j")"
  reps="$(jq -r --arg p "$prim" '[.status.instanceNames[]? | select(. != $p)] | join(" ")' <<<"$j")"
  cat >&2 <<EOF
  Break-glass for $ns/$name (R1 was already run on every instance). By hand, with the plan read; NOTHING below is automated:
    1. Read why: kubectl cnpg status $name -n $ns   (and kubectl -n $ns logs <primary> -c postgres | tail)
    2. R1 again, on EVERY instance:  kubectl -n $ns exec <pod> -c postgres -- psql -U postgres -Atc "select pg_reload_conf()"
    3. R2, if R1 is not enough: delete the OLD replica pods ONE AT A TIME (${reps:-none listed}); the operator recreates each from the
       new spec; wait for the Cluster to be healthy in between. Then delete the old primary pod ($prim) GRACEFULLY, once.
       NEVER add --force to a primary of a Cluster that is not yet synchronous: that is a failover with possible loss.
    4. Do NOT run kubectl cnpg promote nor a switchover while any pod predates the plugin sidecar: it cannot act on it.
EOF
}

declare -a PENDING=("${DIFFERS[@]}")
declare -A KICKED=()
t0=$SECONDS
while [ "${#PENDING[@]}" -gt 0 ]; do
  declare -a STILL=()
  for i in "${PENDING[@]}"; do
    ns="${C_NS[$i]}"; name="${C_NAME[$i]}"
    if why="$(converged "$ns" "$name")"; then
      echo "✓ $ns/$name: healthy, all instances ready, synchronous_standby_names set, replicas in the quorum ($((SECONDS - t0)) s)."
    else
      STILL+=("$i")
      if [ $((SECONDS - t0)) -ge "$KICK_AFTER" ] && [ -z "${KICKED[$i]:-}" ]; then
        KICKED[$i]=1
        echo "~ $ns/$name not converged after ${KICK_AFTER} s ($why): reloading the configuration on every instance (R1, cloudnative-pg#11627)."
        reload_all "$ns" "$name"
      fi
    fi
  done
  PENDING=("${STILL[@]}"); unset STILL
  [ "${#PENDING[@]}" -eq 0 ] && break
  if [ $((SECONDS - t0)) -ge "$TIMEOUT" ]; then
    for i in "${PENDING[@]}"; do
      echo "✗ ${C_NS[$i]}/${C_NAME[$i]} did not converge within ${TIMEOUT} s." >&2
      break_glass "${C_NS[$i]}" "${C_NAME[$i]}"
    done
    exit 1
  fi
  sleep "$POLL"
done
echo "✓ synchronous replication is on, the Clusters converged. Next: task cluster-apps-ref PROVIDER=… ROLE=… REF=refs/tags/<apps tag> APPLY=1"
exit 0
