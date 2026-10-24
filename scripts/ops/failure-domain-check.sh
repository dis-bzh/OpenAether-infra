#!/usr/bin/env bash
# OpenAether - what would losing ONE failure domain (zone, AZ, subregion, hypervisor host) cost? (0.4.0 M4, `task failure-domain-check`)
#
# READ-ONLY. For every domain that holds a node it answers "if this one went away now", from the placement the state
# records (control_plane_zones, worker_zones: where the provider PUT the nodes, not a measurement) and from the cluster:
#
#   control planes   enough of them stay for an etcd quorum
#   workers          at least two stay, and the CPU requests of all workers fit on the ones that stay
#   OpenBao          the raft quorum survives (pods are mapped to their node's domain)
#   databases        every CNPG cluster keeps an instance outside the domain
#   volumes          every Longhorn volume keeps a replica outside the domain
#   gateway          at least one Gateway pod stays
#
# Exit 1 when some domain's loss would stop something, 0 when every loss is survivable; what could not be read is UNCHECKED,
# printed, and fatal only with --strict. The drill that proves it on a cloud (power off every node of a domain through the
# provider API) is in docs/resilience.md.
# Usage: failure-domain-check.sh <provider> [--role=management] [--strict]
# Needs: tofu init done, ./kubeconfig, run from infrastructure/opentofu/cluster.
set -euo pipefail

PROVIDER="${1:-}"; shift || true
ROLE="management"; STRICT=0
for arg in "$@"; do
  case "$arg" in
    --role=*) ROLE="${arg#--role=}" ;;
    --strict) STRICT=1 ;;
    *) echo "✗ unknown flag: $arg" >&2; exit 2 ;;
  esac
done
[[ -n "$PROVIDER" ]] || { echo "usage: $0 <provider> [--role=R] [--strict]" >&2; exit 2; }
for bin in tofu jq kubectl; do command -v "$bin" >/dev/null 2>&1 || { echo "✗ $bin is required" >&2; exit 1; }; done
KCTL=(kubectl --kubeconfig "${KUBECONFIG:-./kubeconfig}" --request-timeout=30s)

OUT="$(tofu output -json 2>/dev/null || echo '{}')"
mapfile -t CP_IPS < <(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$OUT")
mapfile -t WK_IPS < <(jq -r '.worker_private_ips.value[]? // empty' <<<"$OUT")
mapfile -t CP_Z < <(jq -r '.control_plane_zones.value[]? // empty' <<<"$OUT")
mapfile -t WK_Z < <(jq -r '.worker_zones.value[]? // empty' <<<"$OUT")
[[ ${#CP_IPS[@]} -gt 0 ]] || { echo "✗ no control_plane_private_ips in the state: is the infra deployed?" >&2; exit 1; }

bad=0; unk=0
okl()  { printf '    \033[32m✓\033[0m %s\n' "$*"; }
badl() { printf '    \033[31m✗\033[0m %s\n' "$*"; bad=$((bad + 1)); }
unkl() { printf '    ? UNCHECKED: %s\n' "$*"; unk=$((unk + 1)); }

# --- node name -> zone, through the private address (the identity all providers agree on) ---
declare -A ZONE_OF_NODE=()
if NODES_JSON="$("${KCTL[@]}" get nodes -o json 2>/dev/null)"; then
  while IFS=$'\t' read -r name ip; do
    for i in "${!CP_IPS[@]}"; do if [[ "${CP_IPS[$i]}" == "$ip" ]]; then ZONE_OF_NODE[$name]="${CP_Z[$i]:-}"; fi; done
    for i in "${!WK_IPS[@]}"; do if [[ "${WK_IPS[$i]}" == "$ip" ]]; then ZONE_OF_NODE[$name]="${WK_Z[$i]:-}"; fi; done
  done < <(jq -r '.items[] | [.metadata.name, ([.status.addresses[] | select(.type=="InternalIP") | .address][0] // "")] | @tsv' <<<"$NODES_JSON")
else
  echo "✗ the Kubernetes API did not answer: nothing can be checked." >&2; exit 1
fi

zone_of() { printf '%s' "${ZONE_OF_NODE[$1]:-}"; }
domains="$( { printf '%s\n' "${CP_Z[@]}" "${WK_Z[@]}"; } | awk 'NF' | sort -u)"

echo "Failure domains of ${PROVIDER} (${ROLE}): $(wc -l <<<"$domains") holding ${#CP_IPS[@]} control plane(s) and ${#WK_IPS[@]} worker(s)"
if [[ ${#CP_Z[@]} -ne ${#CP_IPS[@]} ]]; then
  unkl "control_plane_zones is not in the state (a state older than this output needs one apply): the placement is unknown"
  exit "$STRICT"
fi
[[ ${#WK_IPS[@]} -eq 0 || ${#WK_Z[@]} -eq ${#WK_IPS[@]} ]] || unkl "worker_zones is not in the state: worker placement is unknown (one apply of this release records it)"

# CPU request % per worker (describe nodes), as roll-gates.sh reads it
declare -A REQ_PCT=()
if DESC="$("${KCTL[@]}" describe nodes -l '!node-role.kubernetes.io/control-plane' 2>/dev/null)"; then
  while read -r n p; do REQ_PCT[$n]="$p"; done < <(awk '/^Name:/{n=$2} /^  cpu +[0-9]/{p=$3; gsub(/[()%]/,"",p); print n, p}' <<<"$DESC")
fi
PODS_VAULT="$("${KCTL[@]}" -n foundation-vault get pods -l app=openbao -o json 2>/dev/null || echo '')"
PODS_DB="$("${KCTL[@]}" get pods -A -l cnpg.io/cluster -o json 2>/dev/null || echo '')"
PODS_GW="$("${KCTL[@]}" -n services-gateway get pods -l gateway.networking.k8s.io/gateway-name -o json 2>/dev/null || echo '')"
REPLICAS="$("${KCTL[@]}" -n longhorn-system get replicas.longhorn.io -o json 2>/dev/null || echo '')"

node_map_json() { # {"node": "zone"} for jq
  local k first=1; printf '{'
  for k in "${!ZONE_OF_NODE[@]}"; do [[ $first -eq 1 ]] || printf ','; first=0; printf '%s:%s' "$(jq -Rn --arg s "$k" '$s')" "$(jq -Rn --arg s "${ZONE_OF_NODE[$k]}" '$s')"; done
  printf '}'
}
NODEMAP="$(node_map_json)"

while IFS= read -r Z; do
  [[ -n "$Z" ]] || continue
  echo
  echo "  If ${Z} is lost:"
  # control planes
  cp_n=${#CP_IPS[@]}; cp_in=0
  for z in "${CP_Z[@]}"; do if [[ "$z" == "$Z" ]]; then cp_in=$((cp_in + 1)); fi; done
  cp_left=$((cp_n - cp_in)); need=$((cp_n / 2 + 1))
  if (( cp_n < 3 )); then badl "${cp_n} control plane(s): not an HA control plane, the loss of any one stops it"
  elif (( cp_left >= need )); then okl "control planes: ${cp_left} of ${cp_n} stay, etcd quorum is ${need}"
  else badl "control planes: only ${cp_left} of ${cp_n} stay, etcd quorum is ${need} - the cluster stops (task dr-restore-plan is the way back)"; fi
  # workers
  if [[ ${#WK_Z[@]} -eq ${#WK_IPS[@]} && ${#WK_IPS[@]} -gt 0 ]]; then
    wk_in=0; for z in "${WK_Z[@]}"; do if [[ "$z" == "$Z" ]]; then wk_in=$((wk_in + 1)); fi; done
    wk_left=$(( ${#WK_IPS[@]} - wk_in ))
    if (( wk_left < 2 )); then badl "workers: ${wk_left} of ${#WK_IPS[@]} stay - replicated services lose their second copy"
    else
      total=0; seen=0
      for n in "${!REQ_PCT[@]}"; do total=$((total + REQ_PCT[$n])); seen=$((seen + 1)); done
      if (( seen == 0 )); then unkl "workers: CPU requests could not be read"
      elif (( total > wk_left * 100 )); then badl "workers: ${wk_left} stay, but the workers request ${total}% of a node and ${wk_left} hold $((wk_left * 100))%: pods stay Pending (docs/capacity.md)"
      else okl "workers: ${wk_left} of ${#WK_IPS[@]} stay, requests ${total}% fit in $((wk_left * 100))%"; fi
    fi
  fi
  # OpenBao
  if [[ -n "$PODS_VAULT" ]] && [[ "$(jq '.items | length' <<<"$PODS_VAULT")" -gt 0 ]]; then
    tot="$(jq '.items | length' <<<"$PODS_VAULT")"
    lost="$(jq --arg z "$Z" --argjson m "$NODEMAP" '[.items[] | select($m[.spec.nodeName] == $z)] | length' <<<"$PODS_VAULT")"
    q=$((tot / 2 + 1))
    (( tot - lost >= q )) && okl "OpenBao: ${lost} of ${tot} raft members there, $((tot - lost)) stay, quorum ${q}" \
                          || badl "OpenBao: ${lost} of ${tot} raft members there, quorum ${q} is lost (no secret reads, no certificate issued)"
  else unkl "OpenBao pods could not be listed"; fi
  # databases
  if [[ -n "$PODS_DB" ]]; then
    lines="$(jq -r --arg z "$Z" --argjson m "$NODEMAP" '[.items[] | {c: .metadata.labels["cnpg.io/cluster"], zone: $m[.spec.nodeName]}] | group_by(.c)[]
              | [.[0].c, length, (map(select(.zone != $z)) | length)] | @tsv' <<<"$PODS_DB")"
    while IFS=$'\t' read -r c total_i out_i; do
      [[ -n "$c" ]] || continue
      (( out_i >= 1 )) && okl "database ${c}: ${out_i} of ${total_i} instance(s) stay" || badl "database ${c}: no instance outside ${Z} - the data on its local disks is gone with it (restore from backup)"
    done <<<"$lines"
  else unkl "CNPG pods could not be listed"; fi
  # Longhorn volumes
  if [[ -n "$REPLICAS" ]] && [[ "$(jq '.items | length' <<<"$REPLICAS")" -gt 0 ]]; then
    allin="$(jq -r --arg z "$Z" --argjson m "$NODEMAP" '[.items[] | {v: .spec.volumeName, zone: $m[.spec.nodeID]}] | group_by(.v)[]
              | select(all(.[]; .zone == $z)) | .[0].v' <<<"$REPLICAS")"
    if [[ -z "$allin" ]]; then okl "volumes: every Longhorn volume keeps a replica outside ${Z}"
    else while IFS= read -r v; do badl "volume ${v}: every replica is in ${Z} - restore from backup"; done <<<"$allin"; fi
  elif [[ -n "$REPLICAS" ]] && jq -e '.items | type == "array"' <<<"$REPLICAS" >/dev/null 2>&1; then
    okl "volumes: no Longhorn volume exists, nothing to lose there (lab 23: this was reported as UNCHECKED)"
  else unkl "Longhorn replicas could not be listed (no Longhorn, or no access)"; fi
  # gateway
  if [[ -n "$PODS_GW" ]] && [[ "$(jq '.items | length' <<<"$PODS_GW")" -gt 0 ]]; then
    stay="$(jq --arg z "$Z" --argjson m "$NODEMAP" '[.items[] | select($m[.spec.nodeName] != $z)] | length' <<<"$PODS_GW")"
    (( stay >= 1 )) && okl "gateway: ${stay} pod(s) stay" || badl "gateway: every pod is in ${Z} - all customer traffic stops until they are rescheduled"
  else unkl "Gateway pods could not be listed"; fi
done <<<"$domains"

echo
if (( bad > 0 )); then
  echo "✗ ${bad} loss(es) would stop something. Fix the placement (spread the nodes over more domains: docs/resilience.md) before relying on zone-loss survival."
  exit 1
fi
if (( unk > 0 && STRICT == 1 )); then echo "✗ ${unk} item(s) UNCHECKED and --strict"; exit 1; fi
note=""; if (( unk > 0 )); then note=" (${unk} item(s) UNCHECKED)"; fi
echo "✓ losing any ONE failure domain is survivable on what could be read${note}."
