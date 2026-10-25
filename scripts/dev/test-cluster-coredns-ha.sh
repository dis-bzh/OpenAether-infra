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
cp scripts/ops/cluster-coredns-ha.sh scripts/ops/coredns-ha-patch.json "$W/scripts/ops/"; cp scripts/lib/common.sh "$W/scripts/lib/"
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
  "-n kube-system rollout status deployment coredns --timeout="*) exit "\$(cat "$FX/rollout.rc" 2>/dev/null || echo 0)" ;;
  *) echo "UNEXPECTED \$*" >>"$W/calls.log"; exit 99 ;;
esac
STUB
chmod +x "$W/stub"; ln -s "$W/stub" "$W/bin/kubectl"

fixture() { # <nodes> <replicas> <hard 0|1>
  : >"$W/calls.log"; rm -f "$FX/absent" "$FX/rollout.rc"
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

echo "--- not applicable ---"
fixture 8 2 0; touch "$FX/absent"; run; rc=$?
[ "$rc" = 0 ] && ok "no coredns Deployment: nothing to converge" || bad "rc $rc"
fixture 8 2 0; echo 'coredns_ha = false' >"$C/envs/management-stub.tfvars"; run --apply; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$W/calls.log" ]; } && ok "coredns_ha = false: Talos owns the Deployment, the cluster is not even asked" || bad "rc $rc, calls: $(cat "$W/calls.log")"

echo; printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
