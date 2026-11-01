#!/usr/bin/env bash
# ==============================================================================
# cluster-bootstrap-sync.sh (infra #408): Cilium and Flux controller versions of a live cluster against the pinned artifacts.
#
# The real script runs in a throwaway copy of the layout, against the REAL committed artifacts and lock. kubectl is a stub: the
# running versions are fixture files rendered to the JSON a Deployment / DaemonSet list would give; `apply --server-side` (not
# dry-run) moves the Flux fixture to the artifact's versions, so "applied" is judged by the re-read and not by the call. What a
# real server does with the manifest (conflicts, rollout time, CRD conversion) is not measured. Offline, no cluster.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

SCRIPT=scripts/ops/cluster-bootstrap-sync.sh
[ -f "$SCRIPT" ] || { echo "✗ $SCRIPT does not exist — nothing was checked" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }
BASH_BIN="$(command -v bash)"
# shellcheck source=../lib/common.sh
source scripts/lib/common.sh; source scripts/lib/pins.sh
REAL_M=infrastructure/opentofu/cluster/bootstrap-manifests

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"; FX="$W/fx"; M="$C/bootstrap-manifests"
mkdir -p "$C/envs" "$M" "$W/scripts/ops" "$W/scripts/lib" "$W/bin" "$FX"
cp "$SCRIPT" "$W/scripts/ops/"; cp scripts/lib/common.sh scripts/lib/pins.sh "$W/scripts/lib/"
cp "$REAL_M"/{cilium.yaml,cilium-hubble-drops.yaml,flux-install.yaml,upstream-artifacts.lock} "$M/"
A="$W/scripts/ops/cluster-bootstrap-sync.sh"
echo "apiVersion: v1" >"$C/kubeconfig"
TFV="$C/envs/management-stub.tfvars"
printf 'variable "talos_version" {\n  default = "v1.14.4"\n}\nvariable "kubernetes_version" {\n  default = "v1.37.1"\n}\n' >"$C/variables.tf"

oa_artifact_pins flux "$M/flux-install.yaml" >"$W/flux.target"
oa_artifact_pins cilium "$M/cilium.yaml" >"$W/cilium.target"
oa_artifact_pins cilium "$M/cilium-hubble-drops.yaml" >"$W/hubble.target"
[ "$(wc -l <"$W/flux.target")" = 7 ] && [ "$(wc -l <"$W/cilium.target")" = 2 ] || { echo "✗ the committed artifacts do not give 7 + 2 pins" >&2; exit 1; }

cat >"$W/stub" <<STUB
#!/usr/bin/env bash
echo "kubectl \$*" >>"$W/calls.log"
echo "\$KUBECONFIG" >>"$W/kubeconfig.seen"
[ -f "$FX/api.rc" ] && { echo "Unable to connect to the server" >&2; exit 1; }
render() { # <pins file> <kind-of-object>
  while read -r _ n t; do
    case "\$2" in
      deploy) jq -nc --arg n "\$n" --arg i "ghcr.io/fluxcd/\$n:\$t" '{metadata:{name:\$n},spec:{template:{spec:{containers:[{image:\$i}]}}}}' ;;
      ds) jq -nc --arg n "\$n" --arg i "quay.io/cilium/\$n:\$t@sha256:abc" '{metadata:{name:\$n},spec:{template:{spec:{containers:[{image:\$i}]}}}}' ;;
    esac
  done <"\$1" | jq -s '{items: .}'
}
case "\$*" in
  "get namespace "*) [ -f "$FX/no-ns" ] && { echo 'Error from server (NotFound)' >&2; exit 1; }; echo ok ;;
  "-n flux-system get deployments -o json") render "$FX/flux.live" deploy ;;
  "-n kube-system get daemonsets,deployments -o json") render "$FX/cilium.live" ds ;;
  "get nodes -o json") cat "$FX/nodes.json" ;;
  *"custom-columns=V:.status.nodeInfo.osImage"*) while read -r v; do echo "Talos (\$v)"; done <"$FX/talos.live" ;;
  *"custom-columns=V:.status.nodeInfo.kubeletVersion"*) cat "$FX/k8s.live" ;;
  "apply --server-side --force-conflicts --field-manager=openaether-bootstrap --dry-run=server "*) echo "x serverside-applied (server dry run)"; echo "y serverside-applied (server dry run)" ;;
  "apply --server-side --force-conflicts --field-manager=openaether-bootstrap -f "*)
    [ -f "$FX/apply.rc" ] && { echo "conflict" >&2; exit 1; }
    [ -f "$FX/noop-apply" ] || cp "$W/flux.target" "$FX/flux.live" ;;
  "-n flux-system rollout status "*) [ -f "$FX/rollout.rc" ] && { echo "error: timed out waiting for the condition" >&2; exit 1; }; echo done ;;
  *) echo "UNEXPECTED \$*" >>"$W/calls.log"; exit 99 ;;
esac
STUB
chmod +x "$W/stub"; ln -s "$W/stub" "$W/bin/kubectl"

reset() {
  rm -rf "$FX"; mkdir -p "$FX"; : >"$W/calls.log"; : >"$W/kubeconfig.seen"
  cp "$W/flux.target" "$FX/flux.live"; cp "$W/cilium.target" "$FX/cilium.live"
  printf 'v1.14.4\n' >"$FX/talos.live"; printf 'v1.37.1\nv1.37.1\n' >"$FX/k8s.live"
  jq -nc '{items: [range(3) | {metadata:{name:"n\(.)"},spec:{},status:{conditions:[{type:"Ready",status:"True"}]}}]}' >"$FX/nodes.json"
  printf 'deploy_flux = true\ntalos_version = "v1.14.4"\nkubernetes_version = "v1.37.1"\n' >"$TFV"
  cp "$REAL_M"/{cilium.yaml,cilium-hubble-drops.yaml,flux-install.yaml,upstream-artifacts.lock} "$M/"
}
run() { ( cd "$C" && env -i PATH="$W/bin:$PATH" HOME="$W" KUBECONFIG=/nonexistent/other OA_ROLLOUT_TIMEOUT=5 "$BASH_BIN" "$A" --tfvars "$TFV" "$@" ) </dev/null >"$W/out" 2>"$W/err"; }
calls() { grep -c -- "$1" "$W/calls.log"; }
said() { grep -qF -- "$1" "$W/out" "$W/err"; }
writes() { calls 'apply --server-side --force-conflicts --field-manager=openaether-bootstrap -f'; }
setlive() { # <file> <name> <tag>
  awk -v n="$2" -v t="$3" '$2 == n { $3 = t } { print }' "$FX/$1" >"$FX/x" && mv "$FX/x" "$FX/$1"
}
droplive() { grep -v " $2 " "$FX/$1" >"$FX/x"; mv "$FX/x" "$FX/$1"; }

echo "--- everything at the pin ---"
reset; run; rc=$?
[ "$rc" = 0 ] && said "run exactly the pinned versions" && [ "$(writes)" = 0 ] && ok "exit 0, nothing written" || bad "rc $rc: $(cat "$W/out" "$W/err")"
[ -s "$W/kubeconfig.seen" ] && ! grep -qv "^$C/kubeconfig\$" "$W/kubeconfig.seen" && ok "the cluster directory's kubeconfig is used" || bad "kubeconfig seen"

echo "--- Flux one minor behind: the dry run shows it and writes nothing; --apply moves it and re-reads ---"
reset; setlive flux.live kustomize-controller v1.8.5
run; rc=$?
[ "$rc" = 3 ] && said "kustomize-controller" && said "v1.8.5" && said "NOTHING was written" && [ "$(writes)" = 0 ] && ok "dry run: exit 3, the difference shown, no write" || bad "rc $rc: $(cat "$W/out" "$W/err")"
said "server-side dry run: the API server accepts" && [ "$(calls 'dry-run=server')" = 1 ] && ok "the server-side dry run of the manifest ran" || bad "no server dry run"
run --apply; rc=$?
[ "$rc" = 0 ] && [ "$(writes)" = 1 ] && [ "$(calls 'rollout status')" = 7 ] && said "run the pinned versions" && ok "applied once, 7 rollouts waited for, re-read at the pin" || bad "rc $rc writes $(writes) rollouts $(calls 'rollout status'): $(cat "$W/err")"
grep -q -- '--server-side --force-conflicts --field-manager=openaether-bootstrap' "$W/calls.log" && ! grep -qE 'kubectl (delete|replace|create|patch)' "$W/calls.log" && ok "server-side apply with a named field manager; no delete, replace, create or patch" || bad "calls: $(cat "$W/calls.log")"
run --apply; rc=$?
[ "$rc" = 0 ] && [ "$(writes)" = 1 ] && ok "idempotent: the second run writes nothing" || bad "second run rc $rc"

echo "--- mutation: Flux AHEAD of the pin is a difference, a downgrade, refused ---"
reset; setlive flux.live source-controller v1.9.9
run; rc=$?
[ "$rc" = 3 ] && said "DOWNGRADE" && said "would be REFUSED" && ok "dry run: exit 3, says the apply would be refused as a downgrade" || bad "rc $rc"
run --apply; rc=$?
[ "$rc" = 2 ] && [ "$(writes)" = 0 ] && said "DOWNGRADE" && ok "--apply refused (exit 2), nothing written" || bad "rc $rc writes $(writes)"
reset; setlive flux.live helm-controller v2.0.0
run --apply; rc=$?
[ "$rc" = 2 ] && [ "$(writes)" = 0 ] && ok "a higher major is a downgrade too" || bad "rc $rc"

echo "--- more than one minor at a time is refused ---"
reset; setlive flux.live kustomize-controller v1.7.4
run --apply; rc=$?
[ "$rc" = 2 ] && [ "$(writes)" = 0 ] && said "more than ONE minor" && ok "two minors behind: refused (exit 2), nothing written" || bad "rc $rc writes $(writes)"
reset; setlive flux.live kustomize-controller v1.8.0; setlive flux.live source-controller v1.8.0
run --apply; rc=$?
[ "$rc" = 0 ] && ok "(control) one minor behind on two controllers is allowed" || bad "control rc $rc"

echo "--- other Flux gates ---"
reset; echo "flux old-controller v0.1.0" >>"$FX/flux.live"
run --apply; rc=$?
[ "$rc" = 2 ] && [ "$(writes)" = 0 ] && said "does not prune" && ok "a controller the artifact no longer has: refused, no prune" || bad "rc $rc"
reset; droplive flux.live source-watcher; setlive flux.live source-controller v1.8.5
run --apply; rc=$?
[ "$rc" = 0 ] && [ "$(writes)" = 1 ] && ok "a controller that is new in the artifact (not running yet) does not block" || bad "rc $rc: $(cat "$W/err")"
reset; setlive flux.live source-controller v1.8.5; : >"$FX/rollout.rc"
run --apply; rc=$?
[ "$rc" = 1 ] && said "did not finish rolling out" && ok "a rollout that times out fails (exit 1) naming the Deployment" || bad "rc $rc"
reset; setlive flux.live source-controller v1.8.5; : >"$FX/noop-apply"
run --apply; rc=$?
[ "$rc" = 1 ] && said "still differ from the pin" && ok "an apply that did not reach the pin is caught by the re-read" || bad "rc $rc"
reset; setlive flux.live source-controller v1.8.5; : >"$FX/apply.rc"
run --apply; rc=$?
[ "$rc" = 1 ] && said "apply refused" && ok "a refused apply fails (exit 1)" || bad "rc $rc"

echo "--- never during a Talos or Kubernetes roll ---"
roll_case() { # <label> <setup>
  reset; setlive flux.live source-controller v1.8.5; eval "$2"
  run --apply; rc=$?
  [ "$rc" = 2 ] && [ "$(writes)" = 0 ] && ok "$1: refused (exit 2), nothing written" || bad "$1: rc $rc writes $(writes): $(cat "$W/err")"
}
roll_case "a node NotReady" "jq -c '.items[1].status.conditions[0].status = \"False\"' $FX/nodes.json >$FX/x; mv $FX/x $FX/nodes.json"
roll_case "a node cordoned" "jq -c '.items[2].spec.unschedulable = true' $FX/nodes.json >$FX/x; mv $FX/x $FX/nodes.json"
roll_case "Talos mixed across nodes" "printf 'v1.14.3\nv1.14.4\n' >$FX/talos.live"
roll_case "Kubernetes mixed across nodes" "printf 'v1.37.0\nv1.37.1\n' >$FX/k8s.live"
roll_case "Talos behind the pin (roll pending)" "printf 'v1.14.2\n' >$FX/talos.live"
roll_case "Kubernetes behind the pin (roll pending)" "printf 'v1.36.3\nv1.36.3\n' >$FX/k8s.live"
reset; setlive flux.live source-controller v1.8.5; : >"$FX/api.rc"; run --apply; rc=$?
[ "$rc" = 1 ] && [ "$(writes)" = 0 ] && ok "API unreachable: exit 1, nothing written" || bad "rc $rc"

echo "--- Cilium: compared, never applied ---"
reset; setlive cilium.live cilium v1.19.5; setlive cilium.live cilium-operator v1.19.5
run; rc=$?
[ "$rc" = 3 ] && said "cilium" && said "v1.19.5" && said "does not apply Cilium" && ok "Cilium one minor behind: dry run exit 3, with the rebuild-aside pointer" || bad "rc $rc"
run --apply; rc=$?
[ "$rc" = 5 ] && [ "$(writes)" = 0 ] && said "NOT changed" && ok "--apply with only Cilium different: exit 5, nothing written" || bad "rc $rc writes $(writes)"
run --apply --component cilium; rc=$?
[ "$rc" = 2 ] && [ "$(writes)" = 0 ] && said "never applied by this script" && ok "--component cilium --apply refused up front (exit 2)" || bad "rc $rc"
reset; setlive cilium.live cilium v1.21.0
run; rc=$?
[ "$rc" = 3 ] && said "v1.21.0" && ok "Cilium AHEAD of the pin is a difference too" || bad "rc $rc"
reset; setlive cilium.live cilium-operator v1.19.0; setlive flux.live source-controller v1.8.5
run --apply; rc=$?
[ "$rc" = 5 ] && [ "$(writes)" = 1 ] && said "run the pinned versions" && said "Cilium differs from the pin and was NOT changed" && ok "both differ: Flux is moved, Cilium is reported unchanged, exit 5 (never 0)" || bad "rc $rc writes $(writes)"

echo "--- the pins come from the committed artifact, checked against the lock ---"
reset; sed -i 's#ghcr.io/fluxcd/source-controller:v1.9.6#ghcr.io/fluxcd/source-controller:v1.9.7#' "$M/flux-install.yaml"
run --apply; rc=$?
[ "$rc" = 1 ] && [ "$(writes)" = 0 ] && said "does not match upstream-artifacts.lock" && ok "an artifact that does not match the lock is neither compared nor applied" || bad "rc $rc"
reset; printf 'cilium_hubble_drop_log = true\n' >>"$TFV"; setlive cilium.live cilium v1.19.5
run; rc=$?
[ "$rc" = 3 ] && said "cilium-hubble-drops.yaml" && ok "cilium_hubble_drop_log selects the hubble-drops artifact" || bad "rc $rc"
reset; printf 'cilium_manifest = <<EOT\nx\nEOT\n' >>"$TFV"
run; rc=$?
[ "$rc" = 1 ] && said "overridden" && ok "an overridden manifest: what runs is UNKNOWN, exit 1" || bad "rc $rc"
reset; printf 'talos_version = "v1.14.4"\n' >"$TFV"
run; rc=$?
[ "$rc" = 0 ] && ! said "Flux controllers" && ok "deploy_flux not true: Flux is not compared, Cilium is" || bad "rc $rc"
reset; printf 'talos_version = "v1.14.4"\n' >"$TFV"
run --component flux; rc=$?
[ "$rc" = 0 ] && said "no Flux to compare" && ok "--component flux without Flux: nothing to do" || bad "rc $rc"
reset; : >"$FX/no-ns"; run --component flux; rc=$?
[ "$rc" = 4 ] && ok "deploy_flux with no flux-system namespace: exit 4" || bad "rc $rc"
reset; run --bogus; rc=$?; [ "$rc" = 1 ] && ok "unknown argument: exit 1" || bad "rc $rc"
reset; run --component nonsense; rc=$?; [ "$rc" = 1 ] && ok "unknown component: exit 1" || bad "rc $rc"

echo
echo "cluster-bootstrap-sync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
