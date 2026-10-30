#!/usr/bin/env bash
# ==============================================================================
# cluster-coredns-ha.sh (lab 27, FB): the CoreDNS Deployment of a live cluster is made the declared shape, idempotently, with a dry
# run that writes nothing. The real script runs in a throwaway copy of the layout; kubectl is one stub that serves a Deployment and
# a node list, applies a merge patch with jq and logs every call. What a real rollout does is NOT reproduced (lab 27: 6 s, 0 failed
# lookups at 1 Hz). Offline, no cluster.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"; FX="$W/fx"
mkdir -p "$C/envs" "$W/scripts/ops" "$W/scripts/lib" "$W/bin" "$FX"
cp scripts/ops/cluster-coredns-ha.sh scripts/ops/coredns-ha-patch.json scripts/ops/cilium-operator-ha-patch.json "$W/scripts/ops/"; cp scripts/lib/common.sh "$W/scripts/lib/"
echo "apiVersion: v1" >"$C/kubeconfig"
echo 'cluster_name = "x"' >"$C/envs/management-stub.tfvars"
S="$W/scripts/ops/cluster-coredns-ha.sh"

cat >"$W/stub" <<STUB
#!/usr/bin/env bash
echo "kubectl \$*" >>"$W/calls.log"
case "\$*" in
  "get nodes -o json") jq -Rn '[inputs | split(" ") | {metadata: {name: .[0], labels: (if length > 2 then {"topology.kubernetes.io/zone": .[2]} else {} end)}}] | {items: .}' "$FX/nodes" ;;
  "-n kube-system get deployment coredns -o json") [ -f "$FX/absent" ] && { echo 'Error from server (NotFound): deployments.apps "coredns" not found' >&2; exit 1; }; cat "$FX/dep.json" ;;
  "-n kube-system patch deployment coredns --type merge -p "*)
    jq -c --argjson p "\$9" '. * \$p' "$FX/dep.json" >"$FX/x" && mv "$FX/x" "$FX/dep.json" ;;
  "-n kube-system get deployment cilium-operator -o json") [ -f "$FX/op.absent" ] && { echo 'Error from server (NotFound): deployments.apps "cilium-operator" not found' >&2; exit 1; }; cat "$FX/op.json" ;;
  "-n kube-system get deployment cilium-operator -o jsonpath={.spec.replicas}") jq -r '.spec.replicas' "$FX/op.json" ;;
  "-n kube-system patch deployment cilium-operator --type merge -p "*)
    jq -c --argjson p "\$9" '. * \$p' "$FX/op.json" >"$FX/x" && mv "$FX/x" "$FX/op.json" ;;
  "-n kube-system rollout status deployment cilium-operator --timeout="*) exit "\$(cat "$FX/op.rollout.rc" 2>/dev/null || echo 0)" ;;
  "-n kube-system rollout status deployment coredns --timeout="*) exit "\$(cat "$FX/rollout.rc" 2>/dev/null || echo 0)" ;;
  *) echo "UNEXPECTED \$*" >>"$W/calls.log"; exit 99 ;;
esac
STUB
chmod +x "$W/stub"; ln -s "$W/stub" "$W/bin/kubectl"

fixture() { # <nodes> <replicas> <hard 0|1> [operator replicas, default 2]; ZONES=<n> labels the nodes with n zones (0: none), UNLABELED=1 leaves the last
  # node without a label, ZC=none|soft|hard is the zone term the Deployment carries (soft: ScheduleAnyway; hard: the 3-zone shape)
  : >"$W/calls.log"; rm -f "$FX/absent" "$FX/rollout.rc" "$FX/op.absent" "$FX/op.rollout.rc"
  jq -nc --argjson r "${4:-2}" '{spec: {replicas: $r, template: {spec: {}}}}' >"$FX/op.json"
  for i in $(seq 1 "$1"); do
    if [ "${ZONES:-0}" -gt 0 ] && ! { [ -n "${UNLABELED:-}" ] && [ "$i" = "$1" ]; }; then echo "node-$i Ready z$(( (i - 1) % ZONES + 1 ))"; else echo "node-$i Ready"; fi
  done >"$FX/nodes"
  jq -nc --argjson r "$2" --argjson h "$3" --arg zc "${ZC:-none}" '{spec: {replicas: $r, template: {spec: {topologySpreadConstraints:
    ((if $h == 1 then [{maxSkew: 1, minDomains: 3, topologyKey: "kubernetes.io/hostname", whenUnsatisfiable: "DoNotSchedule"}] else [] end)
     + (if $zc == "hard" then [{maxSkew: 1, minDomains: 3, topologyKey: "topology.kubernetes.io/zone", whenUnsatisfiable: "DoNotSchedule", nodeTaintsPolicy: "Honor"}]
        elif $zc == "soft" then [{maxSkew: 1, topologyKey: "topology.kubernetes.io/zone", whenUnsatisfiable: "ScheduleAnyway"}] else [] end))}}}}' >"$FX/dep.json"
}
run() { PATH="$W/bin:$PATH" "$S" --tfvars envs/management-stub.tfvars "$@" >"$W/out" 2>&1; }
writes() { grep -c ' patch ' "$W/calls.log"; }

echo "--- dry run ---"
fixture 8 2 0; run; rc=$?
{ [ "$rc" = 3 ] && [ "$(writes)" = 0 ] && grep -q 'task cluster-coredns-ha' "$W/out"; } && ok "2 replicas, no spread: exit 3, nothing written, the command named" || bad "rc $rc: $(tail -3 "$W/out")"
fixture 8 3 0; run; rc=$?
[ "$rc" = 3 ] && ok "3 replicas but no hard spread: still a difference" || bad "rc $rc"
fixture 8 3 1; run; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 0 ]; } && ok "in the declared shape: exit 0, nothing written" || bad "rc $rc"
fixture 8 5 1; run; rc=$?
[ "$rc" = 3 ] && ok "AHEAD of the declaration (5 replicas on 8 nodes) is a difference too, as cluster-verify says" || bad "rc $rc"

echo "--- apply ---"
fixture 8 2 0; run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 1 ] && jq -e '.spec.replicas == 3 and ([.spec.template.spec.topologySpreadConstraints[] | select(.whenUnsatisfiable == "DoNotSchedule")] | length) == 1' "$FX/dep.json" >/dev/null; } \
  && ok "patched once with the file's shape (3 replicas, hard spread), rollout awaited, read back" || bad "rc $rc, writes $(writes): $(tail -3 "$W/out")"
grep -q 'rollout status' "$W/calls.log" && ok "the rollout is waited for" || bad "no rollout wait"
run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 1 ]; } && ok "idempotent: a second apply writes nothing" || bad "second apply: rc $rc, writes $(writes)"
fixture 2 2 0; run --apply; rc=$?
jq -e '.spec.replicas == 2 and ([.spec.template.spec.topologySpreadConstraints[] | select(.minDomains != null) | .minDomains] == [2])' "$FX/dep.json" >/dev/null \
  && ok "2 nodes: replicas and minDomains follow min(3, nodes), so no pod waits for ever" || bad "2 nodes: $(jq -c . "$FX/dep.json")"
fixture 8 2 0; echo 1 >"$FX/rollout.rc"; run --apply; rc=$?
[ "$rc" = 1 ] && ok "a rollout that does not finish fails the step" || bad "rc $rc"

echo "--- the Cilium operator (critical-path audit: a cluster built before 0.4.0 keeps ONE replica) ---"
fixture 8 3 1 1; run; rc=$?
{ [ "$rc" = 3 ] && [ "$(writes)" = 0 ] && grep -q 'Cilium operator differs' "$W/out"; } && ok "CoreDNS in sync, operator at 1 replica: exit 3, nothing written" || bad "rc $rc: $(tail -3 "$W/out")"
fixture 8 3 1 1; run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 1 ] && jq -e '.spec.replicas == 2' "$FX/op.json" >/dev/null && ! grep -q 'patch deployment coredns' "$W/calls.log"; } \
  && ok "apply patches the operator to 2 replicas and leaves a CoreDNS already in shape alone" || bad "rc $rc, writes $(writes): $(tail -3 "$W/out")"
grep -q 'rollout status deployment cilium-operator' "$W/calls.log" && ok "the operator rollout is waited for" || bad "no operator rollout wait"
run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 1 ]; } && ok "idempotent: a second apply writes nothing" || bad "second apply: rc $rc, writes $(writes)"
fixture 8 2 0 1; run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 2 ] && jq -e '.spec.replicas == 2' "$FX/op.json" >/dev/null; } && ok "both differ: both patched in one run" || bad "rc $rc, writes $(writes)"
fixture 8 2 0 2; run; rc=$?
{ [ "$rc" = 3 ] && grep -q 'CoreDNS differs' "$W/out" && ! grep -q 'Cilium operator differs' "$W/out"; } && ok "only CoreDNS differs: only CoreDNS is reported" || bad "rc $rc"
fixture 1 1 1 1; run; rc=$?
[ "$rc" = 0 ] && ok "one node: the declared operator is 1 replica, nothing to do" || bad "one node: rc $rc: $(tail -2 "$W/out")"
fixture 8 3 1 5; run; rc=$?
[ "$rc" = 3 ] && ok "AHEAD (5 operator replicas) is a difference too" || bad "rc $rc"
fixture 8 3 1 1; echo 1 >"$FX/op.rollout.rc"; run --apply; rc=$?
[ "$rc" = 1 ] && ok "an operator rollout that does not finish fails the step" || bad "rc $rc"
fixture 8 3 1; touch "$FX/op.absent"; run; rc=$?
[ "$rc" = 0 ] && ok "no cilium-operator Deployment: nothing to converge for it" || bad "rc $rc"
fixture 8 3 1 1; echo 'coredns_ha = false' >"$C/envs/management-stub.tfvars"; run; rc=$?
{ [ "$rc" = 3 ] && ! grep -q 'deployment coredns' "$W/calls.log"; } && ok "coredns_ha = false does not hide the operator" || bad "rc $rc"
echo 'cluster_name = "x"' >"$C/envs/management-stub.tfvars"

echo "--- the zone term (lab 28, I2: all three replicas landed in one zone at install) ---"
zone_of() { jq -c '[.spec.template.spec.topologySpreadConstraints[] | select(.topologyKey == "topology.kubernetes.io/zone")] | first' "$FX/dep.json"; }
ZONES=3 ZC=soft fixture 8 3 1; run; rc=$?
{ [ "$rc" = 3 ] && [ "$(writes)" = 0 ] && grep -q 'zone' "$W/out" && grep -q 'task cluster-coredns-ha' "$W/out"; } \
  && ok "3 zones, hostname spread required but the zone term only a preference: a difference (exit 3), nothing written, the command named" || bad "rc $rc: $(tail -3 "$W/out")"
ZONES=3 ZC=soft fixture 8 3 1; run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 1 ] && [ "$(zone_of | jq -r '[.whenUnsatisfiable, .minDomains, .nodeTaintsPolicy] | join(" ")')" = "DoNotSchedule 3 Honor" ] \
  && jq -e '[.spec.template.spec.topologySpreadConstraints[] | select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule" and .minDomains == 3)] | length == 1' "$FX/dep.json" >/dev/null; } \
  && ok "apply: the zone term becomes required (DoNotSchedule, minDomains 3, nodeTaintsPolicy Honor), the hostname term stays" || bad "rc $rc, writes $(writes): $(zone_of)"
run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 1 ]; } && ok "idempotent: a second apply writes nothing" || bad "second apply: rc $rc, writes $(writes)"
ZONES=3 ZC=hard fixture 8 3 1; run; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 0 ]; } && ok "3 zones and the required zone term already there: in sync" || bad "rc $rc: $(tail -3 "$W/out")"
ZONES=3 ZC=none fixture 8 2 0; run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(zone_of | jq -r .whenUnsatisfiable)" = DoNotSchedule ] && jq -e '.spec.replicas == 3' "$FX/dep.json" >/dev/null; } \
  && ok "a Deployment from before 0.4.0 (2 replicas, no spread) on 3 zones gets the whole shape, zone term included, in one patch" || bad "rc $rc: $(jq -c . "$FX/dep.json")"
ZONES=2 ZC=soft fixture 8 3 1; run; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 0 ]; } && ok "2 zones: a preference is the declared zone term, nothing to do (a required one would leave a replica Pending)" || bad "rc $rc: $(tail -3 "$W/out")"
ZONES=2 ZC=none fixture 8 2 0; run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(zone_of | jq -r .whenUnsatisfiable)" = ScheduleAnyway ] && [ "$(zone_of | jq -r 'has("minDomains")')" = false ]; } \
  && ok "2 zones: the patch keeps the zone term a preference and drops its minDomains (the API refuses minDomains with ScheduleAnyway)" || bad "rc $rc: $(zone_of)"
ZONES=3 UNLABELED=1 ZC=none fixture 8 2 0; run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(zone_of | jq -r .whenUnsatisfiable)" = ScheduleAnyway ]; } && ok "3 zones but one node without a zone label: the zone term stays a preference (that node could never take a pod under a required rule)" || bad "rc $rc: $(zone_of)"
ZONES=0 ZC=none fixture 8 3 1; run; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 0 ]; } && ok "no zone label anywhere (local, Proxmox): the shape of before, nothing to do" || bad "rc $rc: $(tail -3 "$W/out")"
ZONES=3 ZC=none fixture 3 3 1; run --apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(zone_of | jq -r .minDomains)" = 3 ]; } && ok "3 nodes in 3 zones: required, minDomains 3 (one replica per node and per zone)" || bad "rc $rc: $(zone_of)"
ZONES=0 ZC=none; unset ZONES ZC UNLABELED

echo "--- not applicable ---"
fixture 8 2 0; touch "$FX/absent"; run; rc=$?
[ "$rc" = 0 ] && ok "no coredns Deployment: nothing to converge" || bad "rc $rc"
fixture 8 2 0; echo 'coredns_ha = false' >"$C/envs/management-stub.tfvars"; run --apply; rc=$?
{ [ "$rc" = 0 ] && ! grep -q 'deployment coredns' "$W/calls.log"; } && ok "coredns_ha = false: Talos owns the Deployment, CoreDNS is not even asked" || bad "rc $rc, calls: $(cat "$W/calls.log")"

echo; printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
