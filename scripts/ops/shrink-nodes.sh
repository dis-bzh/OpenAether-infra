#!/usr/bin/env bash
# OpenAether — remove nodes from a bootstrapped cluster, gracefully
#
# Lowering a count in the tfvars destroys the highest-index machine and its data volumes with no
# drain, no etcd leave and no Node delete, so cluster-up refuses it (refuse-node-deletes.sh). This is
# the way to do it, in two steps like destroy. Lower the count in the tfvars, then:
#   shrink-nodes.sh <provider> [--role=R] [--allow-below-ha] --plan           read-only: what goes, can the cluster lose it
#   shrink-nodes.sh <provider> [--role=R] [--allow-below-ha] --apply=<file>   re-derive, refuse if it moved, then remove
# One control plane per run; a worker run may take several, highest index first, one at a time.
#   worker:        Longhorn eviction → drain → power off → delete the Node → targeted destroy of its bundle
#   control plane: etcd snapshot → hand off leadership → drain → etcd leave → power off → delete the Node → destroy
# Run from infrastructure/opentofu/cluster with the backend inited and the Talos tunnels open.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROVIDER="${1:-}"; shift || true
ROLE=management MODE="" PLAN_FILE="" ALLOW_BELOW_HA=0
for arg in "$@"; do
  case "$arg" in
    --role=*)         ROLE="${arg#--role=}" ;;
    --plan)           MODE=plan ;;
    --apply=*)        MODE=apply; PLAN_FILE="${arg#--apply=}" ;;
    --allow-below-ha) ALLOW_BELOW_HA=1 ;;
    *) echo "✗ unknown flag: $arg" >&2; exit 2 ;;
  esac
done
[ -n "$PROVIDER" ] && [ -n "$MODE" ] && [ -n "$ROLE" ] \
  || { echo "usage: shrink-nodes.sh <provider> [--role=R] [--allow-below-ha] --plan | --apply=<file>" >&2; exit 2; }
[ "$MODE" = plan ] || [ -f "$PLAN_FILE" ] \
  || { echo "✗ no scope file '${PLAN_FILE}' — run --plan first and read it." >&2; exit 2; }
case "$PROVIDER" in
  scaleway) MOD=scw ;; ovh) MOD=ovh ;; outscale) MOD=outscale ;; proxmox) MOD=proxmox ;;
  *) echo "✗ unknown provider: $PROVIDER (expected scaleway|ovh|outscale|proxmox)" >&2; exit 2 ;;
esac

TFVARS="envs/${ROLE}-${PROVIDER}.tfvars"
export TALOSCONFIG="${TALOSCONFIG:-./talosconfig}"
KUBECONFIG_FILE="${KUBECONFIG:-./kubeconfig}"
KCTL=(kubectl --kubeconfig "$KUBECONFIG_FILE")
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-900s}"
NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-600}"
ETCD_TIMEOUT="${ETCD_TIMEOUT:-300}"
LONGHORN_TIMEOUT="${LONGHORN_TIMEOUT:-600}"
EVICT_TIMEOUT="${EVICT_TIMEOUT:-1800}"   # a replica rebuild can outlast the roll's gate
POWEROFF_TIMEOUT="${POWEROFF_TIMEOUT:-300}"
POLL="${POLL:-10}"
ASSUME_YES=1   # cordon_drain: a drain that cannot finish uncordons and dies, it never asks
STOP_REQUESTED=0
SCOPE=all
unset PLAN_ASSERT   # set per call below; one inherited from the environment must not run
# The same helpers as the roll (drain, CNPG, PDB, etcd, saved plans), not a copy of them.
source "$HERE/../lib/roll-gates.sh"

for bin in tofu jq talosctl kubectl; do command -v "$bin" >/dev/null 2>&1 || die "$bin is required"; done
for f in "$TFVARS" "$TALOSCONFIG" "$KUBECONFIG_FILE"; do [[ -f "$f" ]] || die "not found: $f (run from infrastructure/opentofu/cluster)"; done
TB="$("$HERE/../internal/bootstrap-in-state.sh")" || exit 1
[ "$TB" = true ] || die "the state has no Talos bootstrap: nothing to drain. Lower the count and run cluster-up."

OUTPUTS="$(tofu output -json 2>/dev/null || echo '{}')"
CN="$(tfv "$TFVARS" cluster_name)"; ENVN="$(tfv "$TFVARS" environment)"
[[ -n "$ENVN" ]] || die "no environment in $TFVARS"
NODE_PREFIX="${CN:-openaether}-${ENVN}"   # cluster_name defaults to openaether in variables.tf
mapfile -t CP_IPS < <(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$OUTPUTS")
mapfile -t WK_IPS < <(jq -r '.worker_private_ips.value[]? // empty' <<<"$OUTPUTS")
[[ ${#CP_IPS[@]} -gt 0 ]] || die "no control_plane_private_ips in tofu output — is the infra deployed?"
TUNNEL_OFFSET="$(oa_tunnel_offset)" || exit 1
STATE="$(tofu state list 2>/dev/null)" || die "could not read the state"

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
VARS=(-input=false -no-color -var-file="$TFVARS" -var talos_bootstrap=true)

# --- reading a plan ----------------------------------------------------------------
# A node's own resources carry cp/control_plane/worker in their name (data volumes are keyed
# "w<worker>-d<disk>"); OVH's load balancer members are named for the pool, so they go by type.
MACHINE_TYPES='scaleway_instance_server|openstack_compute_instance_v2|outscale_vm|proxmox_virtual_environment_vm'
JQ_DEFS='
  def cls: if (.name | test("(^|_)(cp|control_plane)(_|$)")) then "cp"
           elif (.name | test("(^|_)worker(_|$)")) then "worker"
           elif .type == "openstack_lb_member_v2" and .name == "k8s_api" then "cp"
           elif .type == "openstack_lb_member_v2" and (.name == "http" or .name == "https") then "worker"
           else null end;
  def node: if (.index | type) == "string"
            then ((.index | capture("^w(?<n>[0-9]+)-d[0-9]+$").n | tonumber)? // null) else .index end;
  # What a lowered count may ALSO change: every remaining node gets an in-place config apply, the
  # load balancer drops the member, and the talosconfig and the state backup are rewritten.
  def allowed: (.actions | join(",")) as $a
    | ($a == "update" and ((.address | startswith("module.talos.talos_machine_configuration_apply."))
                           or (.type | IN("scaleway_lb_backend", "outscale_load_balancer_vms", "openstack_lb_member_v2"))))
      or (.address == "local_file.talosconfig" and ($a == "delete,create" or $a == "update"))
      or ((.address | startswith("terraform_data.backup")) and ($a == "delete,create" or $a == "update"));
  # tofu says WHY it deletes; absent on an older tofu, in which case only the shape above decides.
  def pure_delete: .actions == ["delete"] and .cls != null
    and (.reason == null or .reason == "delete_because_count_index" or .reason == "delete_because_each_key");'
JQ_CHANGES='[.resource_changes[]? | select(.mode == "managed" and (.change.actions | . != ["no-op"] and . != ["read"]))
  | {address, type, name: (.name // ""), actions: .change.actions, index, reason: .action_reason} | . + {cls: cls, node: node}]'
plan_changes() { tofu show -json "$1" 2>/dev/null | jq -c "${JQ_DEFS}${JQ_CHANGES}"; } # <planfile>

# The scope is what the saved plan deletes, never a guess from the tfvars. Sets SC_CLASS, SC_IDX (sorted),
# SC_ADDRS (sorted), SC_NODE_OF (address → node index) and SC_JSON; returns 1 when the plan deletes no node.
declare -A SC_NODE_OF
derive_scope() { # <planfile>
  local ch dels bad stray classes old n k want got res i inplan instate a nd
  ch="$(plan_changes "$1")" || die "could not read the plan $1"
  dels="$(jq -c "${JQ_DEFS}"'[.[] | select(pure_delete)]' <<<"$ch")"
  if [[ "$(jq 'length' <<<"$dels")" -eq 0 ]]; then
    # No lowered count; but a node resource tofu deletes for another reason is not "nothing to remove".
    stray="$(jq -r "${JQ_DEFS}"'.[] | select(.actions == ["delete"] and .cls != null) | "    \(.address) \(.reason // "")"' <<<"$ch")"
    [[ -z "$stray" ]] || die "the plan deletes node resources that are not a lowered count — refusing, nothing applied:
${stray}"
    return 1
  fi
  bad="$(jq -r "${JQ_DEFS}"'.[] | select((pure_delete or allowed) | not) | "    \(.actions | join(",")) \(.address) \(.reason // "")"' <<<"$ch")"
  [[ -z "$bad" ]] || die "the plan changes more than the removal — refusing, nothing applied:
${bad}
  Apply the other edits first (task cluster-up), then lower the count alone."
  classes="$(jq -r '[.[].cls] | unique | join(",")' <<<"$dels")"
  [[ "$classes" == cp || "$classes" == worker ]] || die "the plan deletes control planes and workers together (${classes}) — lower one count per run."
  [[ "$(jq '[.[] | select(.node == null)] | length' <<<"$dels")" -eq 0 ]] || die "a deleted node resource has no index — refusing to guess which node goes."
  SC_CLASS="$classes"; res=worker; [[ $SC_CLASS == cp ]] && res='(control_plane|cp)'
  mapfile -t SC_IDX < <(jq -r '[.[].node] | unique | .[]' <<<"$dels")
  mapfile -t SC_ADDRS < <(jq -r '[.[].address] | sort | .[]' <<<"$dels")
  SC_NODE_OF=()
  while IFS=$'\t' read -r a nd; do SC_NODE_OF["$a"]="$nd"; done < <(jq -r '.[] | "\(.address)\t\(.node)"' <<<"$dels")
  # The machines the state holds, not every resource named worker[N]: a Scaleway node is three of those.
  n="$(grep -E "^module\.${MOD}\[0\]\.(${MACHINE_TYPES})\.${res}\[[0-9]+\]\$" <<<"$STATE" | sed -E 's/.*\[([0-9]+)\]$/\1/' | sort -un | wc -l)"
  old=$(( n > SC_IDX[-1] ? n : SC_IDX[-1] + 1 )); k=${#SC_IDX[@]}   # a machine already gone from the state still counts
  want="$(seq $((old - k)) $((old - 1)) | tr '\n' ' ')"; got="${SC_IDX[*]} "
  [[ "$want" == "$got" ]] || die "the plan deletes ${SC_CLASS} ${got% } of ${old}: only the highest indexes can go (${want% }) — OpenTofu removes from the top."
  # Deleting a disk or a port of a node that stays is an edit, not a removal: its machine must go too,
  # unless an earlier run already destroyed it.
  for i in "${SC_IDX[@]}"; do
    inplan="$(jq --argjson i "$i" --arg t "^(${MACHINE_TYPES})\$" "${JQ_DEFS}"'[.[] | select(pure_delete and .node == $i and (.type | test($t)))] | length' <<<"$dels")"
    instate="$(grep -cE "^module\.${MOD}\[0\]\.(${MACHINE_TYPES})\.${res}\[${i}\]\$" <<<"$STATE" || true)"
    (( inplan > 0 || instate == 0 )) || die "the plan deletes some resources of ${SC_CLASS} ${i} but not its machine (a disk count edited?): that is not a removal."
  done
  SC_OLD=$old; SC_NEW=$((old - k))
  SC_JSON="$(jq -n --arg role "$ROLE" --arg provider "$PROVIDER" --arg cls "$SC_CLASS" --argjson old "$old" --argjson new "$((old - k))" \
    --argjson idx "$(printf '%s\n' "${SC_IDX[@]}" | jq -sc .)" --argjson addrs "$(printf '%s\n' "${SC_ADDRS[@]}" | jq -R . | jq -sc .)" \
    '{role: $role, provider: $provider, class: $cls, old: $old, new: $new, indices: $idx, addresses: $addrs}')"
}

# Floors. A control plane below 3 is not HA, and 2 members tolerate no failure at all.
check_policy() {
  if [[ $SC_CLASS == cp ]]; then
    (( ${#SC_IDX[@]} == 1 )) || die "one control plane per run: this plan removes ${#SC_IDX[@]} (${SC_IDX[*]}). Lower control_planes by one."
    (( SC_NEW >= 1 )) || die "a cluster keeps at least one control plane."
    if (( SC_NEW < 3 )) && (( ALLOW_BELOW_HA == 0 )); then
      die "${SC_NEW} control plane(s) is below HA: add --allow-below-ha to accept that."
    fi
    (( SC_NEW != 2 )) || warn "2 etcd members tolerate no failure: go to 1 or back to 3 soon."
  else
    (( SC_NEW >= 1 )) || die "a cluster keeps at least one worker: tear it down instead (task cluster-down-plan)."
    (( SC_NEW >= 2 )) || warn "one worker left: a node roll will take its workloads down with it."
  fi
}

# --- asking the cluster ---------------------------------------------------------------
node_ip() { if [[ $SC_CLASS == cp ]]; then echo "${CP_IPS[$1]:-}"; else echo "${WK_IPS[$1]:-}"; fi; } # <idx>
peer_skip() { if [[ $SC_CLASS == cp ]]; then echo "$1"; else echo -1; fi; }                           # <idx> → the control plane not to ask through

# kubectl says "not found" in words; anything else is a question that was not answered, not an absence.
crd_present() { # <crd>: 0 present, 1 absent, dies on any other failure
  local err
  err="$("${KCTL[@]}" get crd "$1" 2>&1 >/dev/null)" && return 0
  case "$err" in
    *NotFound* | *"not found"* | *"doesn't have a resource type"*) return 1 ;;
    *) die "cannot tell whether the CRD $1 exists: ${err%%$'\n'*}" ;;
  esac
}

# The Node with this InternalIP: its name, or nothing when the cluster ANSWERED and has none. A failed
# question dies: reading it as "gone" would skip the drain and the data checks on the irreversible path.
node_of_ip() { # <ip>
  local j
  j="$("${KCTL[@]}" get nodes -o json 2>"$D/k.err")" || die "cannot ask the cluster which Node has IP $1 ($(tail -n 1 "$D/k.err")) — nothing changed."
  jq -r --arg ip "$1" '[.items[] | select(any(.status.addresses[]?; .type == "InternalIP" and .address == $ip)) | .metadata.name] | .[0] // empty' <<<"$j"
}

# Is nothing answering at <ip>? Asked through a control plane other than <skip> (its own tunnel is not
# a witness: a dropped ssh forward fails like a dead machine), and only when that peer answers.
machine_silent() { # <ip> <skip-cp-index>
  local peer pep k
  for k in 1 2; do
    peer="$(healthy_peer_cp "$2")" || return 1
    read -r pep _ <<<"$peer"
    ! talosctl -e "$pep" -n "$1" version >/dev/null 2>&1 || return 1
    sleep "$POLL"
  done
}

# Volumes that live on the node and nowhere else: removing it destroys the data, and no drain moves it.
pinned_pvs() { # <node>
  "${KCTL[@]}" get pv -o json | jq -r --arg n "$1" '.items[]
    | select([.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?.values[]?] | index($n))
    | "\(.metadata.name) (\(.spec.claimRef.namespace // "-")/\(.spec.claimRef.name // "-"))"'
}

# Longhorn rebuilds a replica elsewhere only if there is an elsewhere: the lines of volumes that want more
# replicas than the schedulable nodes left once ALL of <node>... are gone.
longhorn_room() { # <node>...
  crd_present volumes.longhorn.io || return 0
  local left
  left="$("${KCTL[@]}" -n longhorn-system get nodes.longhorn.io -o json | jq --argjson gone "$(printf '%s\n' "$@" | jq -R . | jq -sc .)" \
    '[.items[] | select((.metadata.name as $n | $gone | index($n)) == null and .spec.allowScheduling == true)] | length')"
  "${KCTL[@]}" -n longhorn-system get volumes.longhorn.io -o json | jq -r --argjson left "$left" \
    '.items[] | select(.spec.numberOfReplicas > $left) | "\(.metadata.name) wants \(.spec.numberOfReplicas) replicas, \($left) node(s) would remain"'
}

SC_NODES=()
survey_removal() { # read-only: refuse before any mutation. Tolerates a resumed run: a node already gone, an etcd already left.
  local nj i ip node pvs lh cap pct w nodes=0 total=0 leaving=0 notready peer pep pip mt m want tip skip
  nj="$("${KCTL[@]}" get nodes -o json 2>"$D/k.err")" || die "kubectl cannot reach the API ($(tail -n 1 "$D/k.err"))"
  SC_NODES=()
  for i in "${SC_IDX[@]}"; do
    ip="$(node_ip "$i")"; [[ -n "$ip" ]] || die "no private IP for ${SC_CLASS} ${i} in the outputs — refresh them (task cluster-up) first."
    node="$(node_of_ip "$ip")" || exit 1
    if [[ -n "$node" ]]; then
      # Presence, not value: Talos sets the role label with an empty value.
      [[ "$(jq -r --arg n "$node" '.items[] | select(.metadata.name == $n) | .metadata.labels | has("node-role.kubernetes.io/control-plane")' <<<"$nj")" == "$([[ $SC_CLASS == cp ]] && echo true || echo false)" ]] \
        || die "${node} (${ip}) is not a ${SC_CLASS} node by its labels — the outputs and the cluster disagree, refusing."
      SC_NODES+=("$node")
    else
      machine_silent "$ip" "$(peer_skip "$i")" \
        || die "no Node has IP ${ip} and the machine does not read as down — the outputs and the cluster disagree, refusing."
      warn "no Node has IP ${ip}: ${SC_CLASS} ${i} is already out of Kubernetes and down (a resumed run)."
    fi
  done
  # etcd: every control plane is a member, minus the one being removed if an earlier run already took it out.
  skip="$(peer_skip "${SC_IDX[0]}")"
  peer="$(healthy_peer_cp "$skip")" || die "no control plane reports a healthy etcd — stabilize the cluster first."
  read -r pep pip <<<"$peer"
  mt="$(talosctl -e "$pep" -n "$pip" etcd members 2>/dev/null)" || die "could not read the etcd members"
  m="$(grep -c ':2380' <<<"$mt" || true)"; want=${#CP_IPS[@]}
  if [[ $SC_CLASS == cp ]]; then
    tip="$(node_ip "${SC_IDX[0]}")"; grep -q "//${tip}:" <<<"$mt" || want=$((want - 1))
  fi
  [[ "$m" == "$want" ]] || die "etcd has ${m} members and ${want} are expected — stabilize the cluster first."
  notready="$(jq -r --argjson skip "$(printf '%s\n' "${SC_NODES[@]:-}" | jq -R . | jq -sc .)" '.items[]
    | select((.metadata.name as $n | $skip | index($n)) | not)
    | select(([.status.conditions[]? | select(.type == "Ready")][0].status) != "True") | .metadata.name' <<<"$nj" | tr '\n' ' ')"
  [[ -z "$notready" ]] || die "not Ready: ${notready}— stabilize the cluster first."
  for node in "${SC_NODES[@]}"; do
    pvs="$(pinned_pvs "$node")" || die "could not list the volumes"
    [[ -z "$pvs" ]] || die "${node} holds node-local volumes, which removal destroys:
$(sed 's/^/    /' <<<"$pvs")
  Move that data off the node first (CNPG: switch over, scale the instance elsewhere)."
  done
  if (( ${#SC_NODES[@]} > 0 )); then
    lh="$(longhorn_room "${SC_NODES[@]}")" || die "could not read Longhorn"
    [[ -z "$lh" ]] || die "Longhorn cannot keep its replicas without ${SC_NODES[*]}:
$(sed 's/^/    /' <<<"$lh")
  Lower the volumes' numberOfReplicas, or keep the node."
  fi
  if [[ $SC_CLASS == worker ]]; then # the workers that stay must carry what the leaving ones request
    cap="$(worker_cpu_requests)" || die "the workers could not be described — refusing to remove blind."
    while read -r w pct; do
      [[ "$pct" =~ ^[0-9]+$ ]] || continue; nodes=$((nodes + 1)); total=$((total + pct))
      printf '%s\n' "${SC_NODES[@]:-}" | grep -qxF "$w" && leaving=$((leaving + 1))
    done <<<"$cap"
    (( nodes - leaving >= 1 && total <= (nodes - leaving) * 100 )) \
      || die "the ${nodes} workers request ${total}% of one worker's CPU; the $((nodes - leaving)) that stay hold $(( (nodes - leaving) * 100 ))%. Add capacity or keep the node."
  fi
  ok "the cluster can lose ${SC_CLASS} ${SC_IDX[*]}"
}

# --- removing one node ---------------------------------------------------------------
UNDO_NODE="" UNDO_LH=""
undo_pending() { # before the machine is off: give the node back
  [[ -z "$UNDO_NODE" ]] || "${KCTL[@]}" uncordon "$UNDO_NODE" >&2 || warn "could not uncordon ${UNDO_NODE} — do it by hand"
  [[ -z "$UNDO_LH" ]] || "${KCTL[@]}" -n longhorn-system patch nodes.longhorn.io "$UNDO_LH" --type merge \
    -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}' >&2 || warn "could not clear the Longhorn eviction on ${UNDO_LH}"
}
shrink_exit() { # EXIT: undo what is reversible, then finish_roll restores CNPG/Flux and exits with this status
  local rc=$?
  set +e   # errexit is still on inside a trap: the (exit) below would end this handler before finish_roll
  trap '' INT TERM
  rm -rf "$D"
  KCTL+=(--request-timeout="${RESTORE_REQUEST_TIMEOUT:-10s}")
  (( rc == 0 )) || { undo_pending; warn "stopped part-way: fix what is named and re-run --plan then --apply (done steps are skipped), or put the count back and run cluster-up."; }
  (exit "$rc"); finish_roll
}

longhorn_evict() { # <node>
  crd_present nodes.longhorn.io || return 0
  local err deadline left
  if ! err="$("${KCTL[@]}" -n longhorn-system get nodes.longhorn.io "$1" 2>&1 >/dev/null)"; then
    case "$err" in *NotFound* | *"not found"*) return 0 ;; *) die "cannot read the Longhorn node $1: ${err%%$'\n'*}" ;; esac
  fi
  UNDO_LH="$1"; info "Longhorn: evicting the replicas of $1…"
  "${KCTL[@]}" -n longhorn-system patch nodes.longhorn.io "$1" --type merge \
    -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' >/dev/null || die "could not ask Longhorn to evict $1"
  deadline=$(( SECONDS + EVICT_TIMEOUT ))
  while (( SECONDS < deadline )); do
    left="$("${KCTL[@]}" -n longhorn-system get replicas.longhorn.io -o json | jq --arg n "$1" '[.items[] | select(.spec.nodeID == $n)] | length')" || left=1
    if [[ "$left" == 0 ]]; then wait_longhorn_healthy && { ok "Longhorn holds no replica on $1"; return 0; }; fi
    sleep "$POLL"
  done
  die "Longhorn still holds replicas on $1 after ${EVICT_TIMEOUT}s — not removing it."
}

node_not_ready() { # <node>: Ready False or Unknown; a question that fails is "not yet"
  local s
  s="$("${KCTL[@]}" get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || return 1
  [[ "$s" == False || "$s" == Unknown ]]
}

# Down means: Talos accepted the shutdown, a control plane that is not the target no longer reaches the
# machine, twice, and the Node reads NotReady. Silence on the node's own tunnel proves nothing.
power_off() { # <endpoint> <ip> <label> <node-or-empty> <skip-cp-index>
  local ep="$1" ip="$2" label="$3" node="$4" skip="$5" deadline=$(( SECONDS + POWEROFF_TIMEOUT ))
  if [[ -n "$node" ]]; then
    info "Powering off ${label}…"
    talosctl -e "$ep" -n "$ip" shutdown --force >/dev/null 2>&1 \
      || die "Talos did not accept the shutdown of ${label} — nothing destroyed (the tunnels must be open: cluster-shrink-plan opens them)."
  fi
  until machine_silent "$ip" "$skip" && { [[ -z "$node" ]] || node_not_ready "$node"; }; do
    (( SECONDS < deadline )) || die "${label} does not read as down ${POWEROFF_TIMEOUT}s after shutdown — not destroying a node that may be up."
    sleep "$POLL"
  done
  UNDO_NODE="" UNDO_LH=""   # the machine is off: nothing left to give back
  ok "${label} is down"
}

REMOVED=()
forget_node() { # <node>: through the load balancer, which may still send a call to the node just powered off
  local n
  for n in 1 2 3 4 5 6; do
    "${KCTL[@]}" delete node "$1" --ignore-not-found --wait=false >/dev/null 2>&1 && { REMOVED+=("$1"); ok "Node $1 deleted"; return 0; }
    sleep "$POLL"
  done
  die "could not delete the Node $1 — delete it by hand, then re-run --plan and --apply."
}

# The destroy is exactly the bundle the plan named: no more, no fewer, nothing created, and only the
# load balancer's membership updated beside it.
BUNDLE=()
assert_bundle() { # <planfile>
  local ch dels extra want
  ch="$(plan_changes "$1")" || return 1
  dels="$(jq -r '[.[] | select(.actions == ["delete"]) | .address] | sort | .[]' <<<"$ch" | LC_ALL=C sort)"
  want="$(printf '%s\n' "${BUNDLE[@]}" | LC_ALL=C sort)"
  [[ "$dels" == "$want" ]] || { warn "the destroy plan deletes a different set than the one read:"; diff <(echo "$want") <(echo "$dels") >&2 || true; return 1; }
  extra="$(jq -r '.[] | select(.actions != ["delete"] and (.actions != ["update"] or (.type | IN("scaleway_lb_backend", "outscale_load_balancer_vms", "openstack_lb_member_v2") | not))) | "\(.actions | join(",")) \(.address)"' <<<"$ch")"
  [[ -z "$extra" ]] || { warn "the destroy plan also changes:"; sed 's/^/    /' <<<"$extra" >&2; return 1; }
}

destroy_bundle() { # <idx>: the irreversible step; data volumes go with the machine
  local i="$1" a
  BUNDLE=()
  for a in "${SC_ADDRS[@]}"; do [[ "${SC_NODE_OF[$a]}" == "$i" ]] && BUNDLE+=("$a"); done
  (( ${#BUNDLE[@]} > 0 )) || die "the scope names nothing for ${SC_CLASS} ${i}"
  local -a targets=(); for a in "${BUNDLE[@]}"; do targets+=("-target=${a}"); done
  PLAN_ASSERT=assert_bundle saved_plan_apply "shrink-${SC_CLASS}-${i}" "$SC_CLASS" "$i" "${#BUNDLE[@]}" \
    "the targeted destroy of ${SC_CLASS} ${i} failed — the node is powered off and out of the cluster: re-run --plan and --apply, or start the VM by hand" \
    apply -var skip_health_check=true "${targets[@]}"
}

remove_worker() { # <idx>
  local i="$1" ip ep node pvs
  ip="$(node_ip "$i")"; ep="$(talos_ep worker "$i")"
  node="$(node_of_ip "$ip")" || exit 1
  if [[ -n "$node" ]]; then
    UNDO_NODE="$node"; longhorn_evict "$node"; cordon_drain "$node"
    pvs="$(pinned_pvs "$node")" || die "could not re-list the volumes after the drain — not removing ${node}."
    [[ -z "$pvs" ]] || die "${node} gained a node-local volume while draining — not removing it."
  fi
  power_off "$ep" "$ip" "worker ${i}" "$node" -1
  if [[ -n "$node" ]]; then
    forget_node "$node"
    "${KCTL[@]}" -n longhorn-system delete nodes.longhorn.io "$node" --ignore-not-found >/dev/null 2>&1 || true
  fi
  destroy_bundle "$i"
}

remove_cp() { # <idx>
  local i="$1" ip ep node n peer pep pip mt member=0
  ip="$(node_ip "$i")"; ep="$(talos_ep cp "$i")"; n="${#CP_IPS[@]}"
  # Membership is asked of a peer: the node being removed is the one whose etcd may be broken.
  peer="$(healthy_peer_cp "$i")" || die "no other control plane reports a healthy etcd — refusing."
  read -r pep pip <<<"$peer"
  mt="$(talosctl -e "$pep" -n "$pip" etcd members 2>/dev/null)" || die "could not read the etcd members"
  grep -q "//${ip}:" <<<"$mt" && member=1
  if (( member )); then
    "$HERE/etcd-snapshot.sh" || die "no etcd snapshot — refusing to touch etcd without one (a failed leave is only recoverable from it)."
  else
    warn "cp-${i} is not an etcd member any more (a resumed run): no snapshot, no leave."
  fi
  [[ "$i" != "$(etcd_leader_index || true)" ]] || forfeit_leadership "$i"
  node="$(node_of_ip "$ip")" || exit 1
  if [[ -n "$node" ]]; then UNDO_NODE="$node"; cordon_drain "$node"; fi
  if (( member )); then
    info "etcd leave on cp-${i}…"
    talosctl -e "$ep" -n "$ip" etcd leave || die "etcd leave failed on cp-${i} — nothing destroyed; fix it or put the count back."
    UNDO_NODE=""   # past here the member cannot rejoin without a wipe
  fi
  unset 'CP_IPS[i]'
  wait_etcd_healthy $((n - 1)) || die "etcd is not $((n - 1))/$((n - 1)) healthy after cp-${i} left — STOP; restore from the snapshot if quorum is lost. To finish by hand: power off cp-${i}, delete its Node, then re-run --plan and --apply."
  power_off "$ep" "$ip" "control plane ${i}" "$node" "$i"
  [[ -z "$node" ]] || forget_node "$node"
  destroy_bundle "$i"
}

# Outputs and tunnels first: a targeted apply leaves the root outputs the tunnel script reads stale.
refresh_outputs() {
  tofu plan "${VARS[@]}" -var skip_health_check=true -refresh-only -out="$D/refresh.tfplan" >/dev/null 2>&1 || die "could not refresh the outputs"
  tofu apply -input=false -no-color "$D/refresh.tfplan" >/dev/null 2>&1 || die "refreshing the outputs failed"
  "$HERE/../bootstrap/talos-tunnels.sh" open . || die "could not reopen the Talos tunnels"
}

wait_pods_placed() { # evicted pods that stay Pending mean the nodes left cannot hold them; said, not fatal
  local deadline=$(( SECONDS + ${PLACED_TIMEOUT:-180} )) p
  while :; do
    p="$("${KCTL[@]}" get pods -A --field-selector status.phase=Pending --no-headers 2>/dev/null | awk '{print $1 "/" $2}' | tr '\n' ' ')" || p=""
    [[ -z "$p" ]] && { ok "no pod is Pending"; return 0; }
    (( SECONDS < deadline )) || { warn "still Pending: ${p}— the nodes left may not hold what the removed one carried"; return 0; }
    sleep "$POLL"
  done
}

# --- run ---------------------------------------------------------------------------
info "Cluster: ${NODE_PREFIX} on ${PROVIDER}  (${#CP_IPS[@]} CP, ${#WK_IPS[@]} workers)"
info "Planning with the lowered counts…"
tofu plan "${VARS[@]}" -var skip_health_check=true -out="$D/scope.tfplan" >"$D/plan.log" 2>&1 \
  || { tail -n 15 "$D/plan.log" >&2; die "could not plan the lowered counts"; }
if ! derive_scope "$D/scope.tfplan"; then
  [[ "$MODE" == plan ]] || die "the plan no longer deletes a node (the count was put back, or the removal already finished) — nothing to apply. If a run stopped after its destroy, task cluster-up converges what is left."
  echo "✓ nothing to remove: the plan deletes no node. If a removal stopped after its destroy, task cluster-up converges what is left."
  exit 0
fi
check_policy
echo "▶ ${SC_CLASS} ${SC_IDX[*]} of ${SC_OLD} would be removed (${SC_NEW} left); OpenTofu will delete:"
printf '    %s\n' "${SC_ADDRS[@]}"
survey_removal

if [[ "$MODE" == plan ]]; then
  OUT="shrink-${ROLE}-${PROVIDER}.json"; printf '%s\n' "$SC_JSON" >"$OUT"
  echo "✓ scope written to ${OUT}. Nothing has been removed. Read it, then:"
  echo "    task cluster-shrink PROVIDER=${PROVIDER} ROLE=${ROLE} PLAN=${OUT}$([[ $ALLOW_BELOW_HA == 1 ]] && echo ' -- --allow-below-ha')"
  exit 0
fi

[[ "$(jq -S . "$PLAN_FILE")" == "$(jq -S . <<<"$SC_JSON")" ]] \
  || die "the plan moved since ${PLAN_FILE} was written (counts, state or tfvars) — run --plan again and read it."
SNAP="$("${KCTL[@]}" get nodes -o json | jq -c '[.items[] | {name: .metadata.name, t: .metadata.creationTimestamp}]')" || die "could not list the nodes"
trap shrink_exit EXIT
ROLL_DONE_MSG="Removal complete. A state backup follows."
cnpg_maintenance true
[[ $SC_CLASS == worker ]] || SCOPE=cp
preflight_roll
for ((j = ${#SC_IDX[@]} - 1; j >= 0; j--)); do
  if [[ $SC_CLASS == worker ]]; then remove_worker "${SC_IDX[$j]}"; else remove_cp "${SC_IDX[$j]}"; fi
  refresh_outputs
done

# --- closing: the remaining nodes' config follows the new counts, one at a time -----------
info "Closing: converging what the lowered counts changed on the remaining nodes…"
tofu plan "${VARS[@]}" -out="$D/close.tfplan" >"$D/close.log" 2>&1 || { tail -n 15 "$D/close.log" >&2; die "could not plan the closing step"; }
CH="$(plan_changes "$D/close.tfplan")" || die "could not read the closing plan"
BAD="$(jq -r "${JQ_DEFS}"'.[] | select(allowed | not) | "    \(.actions | join(",")) \(.address)"' <<<"$CH")"
[[ -z "$BAD" ]] || die "the closing plan changes more than the nodes' config — nothing applied:
${BAD}"
tofu apply -parallelism=1 "$D/close.tfplan" || die "the closing apply failed — run cluster-up to converge"
rc=0; tofu plan "${VARS[@]}" -detailed-exitcode >"$D/final.log" 2>&1 || rc=$?
case "$rc" in
  0) ;;
  2) die "the plan after the removal is not empty — run cluster-up to converge, then cluster-verify" ;;
  *) tail -n 15 "$D/final.log" >&2; die "could not plan after the removal — run cluster-up to converge, then cluster-verify" ;;
esac
wait_etcd_healthy "${#CP_IPS[@]}" || die "etcd is not ${#CP_IPS[@]}/${#CP_IPS[@]} healthy after the removal"
LEFT="$("${KCTL[@]}" get nodes -o json | jq -c '[.items[] | {name: .metadata.name, t: .metadata.creationTimestamp}]')" || die "could not list the nodes left"
jq -en --argjson a "$SNAP" --argjson b "$LEFT" --argjson gone "$(printf '%s\n' "${REMOVED[@]:-}" | jq -R . | jq -sc .)" \
  '($a | map(select(.name as $n | ($gone | index($n)) | not))) == $b' >/dev/null \
  || die "the nodes left are not exactly the ones that were there minus the ones removed (names or creation times differ)"
wait_cnpg_whole
[[ $SC_CLASS != worker ]] || wait_pods_placed
rm -f "$PLAN_FILE"
ok "removed ${SC_CLASS} ${SC_IDX[*]}"
