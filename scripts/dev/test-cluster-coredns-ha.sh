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
  "get nodes --no-headers") cat "$FX/nodes" ;;
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

fixture() { # <nodes> <replicas> <hard 0|1> [operator replicas, default 2]
  : >"$W/calls.log"; rm -f "$FX/absent" "$FX/rollout.rc" "$FX/op.absent" "$FX/op.rollout.rc"
  jq -nc --argjson r "${4:-2}" '{spec: {replicas: $r, template: {spec: {}}}}' >"$FX/op.json"
  for i in $(seq 1 "$1"); do echo "node-$i Ready"; done >"$FX/nodes"
  jq -nc --argjson r "$2" --argjson h "$3" '{spec: {replicas: $r, template: {spec: {topologySpreadConstraints:
    (if $h == 1 then [{maxSkew: 1, minDomains: 3, topologyKey: "kubernetes.io/hostname", whenUnsatisfiable: "DoNotSchedule"}] else [] end)}}}}' >"$FX/dep.json"
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

echo "--- not applicable ---"
fixture 8 2 0; touch "$FX/absent"; run; rc=$?
[ "$rc" = 0 ] && ok "no coredns Deployment: nothing to converge" || bad "rc $rc"
fixture 8 2 0; echo 'coredns_ha = false' >"$C/envs/management-stub.tfvars"; run --apply; rc=$?
{ [ "$rc" = 0 ] && ! grep -q 'deployment coredns' "$W/calls.log"; } && ok "coredns_ha = false: Talos owns the Deployment, CoreDNS is not even asked" || bad "rc $rc, calls: $(cat "$W/calls.log")"

echo; printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
