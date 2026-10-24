#!/usr/bin/env bash
# ==============================================================================
# infra-verify.sh (infra #408): "Cilium and Flux run the pinned version" and "the apps ref Flux follows is git_ref".
#
# The real infra-verify.sh runs in a throwaway layout with a stub kubectl whose answers come from fixture files, against the REAL
# committed artifacts. Every other section of the verifier is answered green or left unanswered (it counts as UNCHECKED, which
# does not matter here: only the lines of the two new sections are judged, and the exit code is judged against BAD lines).
# Mutations: the check must FAIL when the cluster is behind, when it is ahead, when the live ref or the tfvars differ, and say
# UNKNOWN (not pass) when it cannot read. Offline, no cluster.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }
BASH_BIN="$(command -v bash)"
# shellcheck source=../lib/common.sh
source scripts/lib/common.sh; source scripts/lib/pins.sh
REAL_M=infrastructure/opentofu/cluster/bootstrap-manifests

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"; FX="$W/fx"; M="$C/bootstrap-manifests"
mkdir -p "$C/envs" "$M" "$W/scripts/dev" "$W/scripts/lib" "$W/scripts/internal" "$W/bin" "$FX"
cp scripts/dev/infra-verify.sh "$W/scripts/dev/"; cp scripts/lib/common.sh scripts/lib/pins.sh "$W/scripts/lib/"
cp "$REAL_M"/{cilium.yaml,cilium-hubble-drops.yaml,flux-install.yaml} "$M/"
printf 'variable "git_ref" {\n  default = "refs/tags/0.0.1"\n}\nvariable "talos_version" {\n  default = "v1.14.4"\n}\nvariable "kubernetes_version" {\n  default = "v1.37.1"\n}\n' >"$C/variables.tf"
TFV="$C/envs/management-stub.tfvars"
oa_artifact_pins flux "$M/flux-install.yaml" >"$W/flux.target"
oa_artifact_pins cilium "$M/cilium.yaml" >"$W/cilium.target"

cat >"$W/stub" <<STUB
#!/usr/bin/env bash
n="\$(basename "\$0")"
[ "\$n" = sleep ] && exit 0
[ "\$n" = kubectl ] || exit 1
render() {
  while read -r _ n t; do
    case "\$2" in
      deploy) jq -nc --arg n "\$n" --arg i "ghcr.io/fluxcd/\$n:\$t" '{metadata:{name:\$n},spec:{template:{spec:{containers:[{image:\$i}]}}}}' ;;
      ds) jq -nc --arg n "\$n" --arg i "quay.io/cilium/\$n:\$t@sha256:abc" '{metadata:{name:\$n},spec:{template:{spec:{containers:[{image:\$i}]}}}}' ;;
    esac
  done <"\$1" | jq -s '{items: .}'
}
case "\$*" in
  *"get --raw"*) echo ok ;;
  *"custom-columns=V:.status.nodeInfo.osImage"*) echo "Talos (v1.14.4)" ;;
  *"custom-columns=V:.status.nodeInfo.kubeletVersion"*) echo "v1.37.1" ;;
  *"get nodes"*"--no-headers"*) printf 'a Ready cp 1d\nb Ready w 1d\nc Ready w 1d\n' ;;
  *"k8s-app=cilium"*) printf 'c1 1/1 Running\nc2 1/1 Running\nc3 1/1 Running\n' ;;
  *"deploy coredns -o json") [ -f "$FX/coredns.unreadable" ] && exit 1; cat "$FX/coredns.json" ;;
  *"deploy coredns"*) echo 2 ;;
  *"get ns "*|*"get namespace "*) [ -f "$FX/no-flux-ns" ] && exit 1; echo Active ;;
  *"wait --for=condition=Available"*) echo ok ;;
  "-n flux-system get deployments -o json") [ -f "$FX/flux.unreadable" ] && exit 1; render "$FX/flux.live" deploy ;;
  "-n kube-system get daemonsets,deployments -o json") [ -f "$FX/cilium.unreadable" ] && exit 1; render "$FX/cilium.live" ds ;;
  *"gitrepositories.source.toolkit.fluxcd.io openaether -o json") [ -f "$FX/gr.unreadable" ] && exit 1; cat "$FX/gr.json" ;;
  *"kustomizations.kustomize.toolkit.fluxcd.io openaether-platform -o json") cat "$FX/ks.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$W/stub"; for t in kubectl sleep; do ln -s "$W/stub" "$W/bin/$t"; done

mkdns() { # <replicas> <hard hostname spread: true|false> — the Deployment kube-system/coredns as the apiserver returns it
  jq -nc --argjson r "$1" --argjson h "$2" '{spec:{replicas:$r,template:{spec:(if $h then {topologySpreadConstraints:[{topologyKey:"kubernetes.io/hostname",whenUnsatisfiable:"DoNotSchedule",maxSkew:1}]} else {} end)}}}' >"$FX/coredns.json"; }
mkgr() { jq -nc --arg r "$1" '{spec:{ref:{name:$r}}}' >"$FX/gr.json"; }
mkks() { jq -nc --arg r "$1" '{spec:{postBuild:{substitute:{GIT_REF:$r}}}}' >"$FX/ks.json"; }
reset() {
  rm -rf "$FX"; mkdir -p "$FX"; cp "$W/flux.target" "$FX/flux.live"; cp "$W/cilium.target" "$FX/cilium.live"
  mkgr refs/tags/0.4.0; mkks refs/tags/0.4.0; mkdns 3 true
  printf 'git_ref = "refs/tags/0.4.0"\ndeploy_flux = true\ncluster_name = "c"\nenvironment = "dev"\n' >"$TFV"
  cp "$REAL_M"/{cilium.yaml,cilium-hubble-drops.yaml,flux-install.yaml} "$M/"
}
setlive() { awk -v n="$2" -v t="$3" '$2 == n { $3 = t } { print }' "$FX/$1" >"$FX/x" && mv "$FX/x" "$FX/$1"; }
run() { ( env -i PATH="$W/bin:$PATH" HOME="$W" API_TIMEOUT=2 NODES_TIMEOUT=2 DNS_TIMEOUT=2 ${EXTRA:-} "$BASH_BIN" "$W/scripts/dev/infra-verify.sh" "${1:-stub}" management ) </dev/null >"$W/raw" 2>&1; rc=$?
  sed 's/\x1b\[[0-9;]*m//g' "$W/raw" >"$W/out"; }
line() { grep -F -- "$1" "$W/out" | grep -F -- "$2" | head -1; }   # <section hint> <text>
has() { grep -qF -- "$1" "$W/out"; }
badline() { grep -E '^  ✗' "$W/out" | grep -F -- "$1" | head -1; }
unkline() { grep -E '^  \?' "$W/out" | grep -F -- "$1" | head -1; }

echo "--- Cilium and Flux at the pin ---"
reset; run
has "✓ Cilium run the pinned version (v1.20.2)" && has "✓ Flux controllers run the pinned version" && ok "both pass at the pin" || bad "$(grep -n 'Cilium\|Flux' "$W/out")"
has "the GitRepository and GIT_REF both follow the declared git_ref (refs/tags/0.4.0)" && ok "the apps ref passes when the three agree" || bad "no apps ref pass"

echo "--- mutation: Cilium behind / ahead / missing / unreadable ---"
reset; setlive cilium.live cilium v1.19.5; run
{ [ -n "$(badline 'Cilium: cilium pinned v1.20.2 running v1.19.5')" ] && has "BEHIND" && has "rebuild aside" && [ "$rc" -ne 0 ]; } && ok "Cilium behind: BAD with the rebuild-aside pointer, run fails" || bad "$(grep Cilium "$W/out")"
reset; setlive cilium.live cilium-operator v1.21.0; run
{ [ -n "$(badline 'Cilium: cilium-operator pinned v1.20.2 running v1.21.0')" ] && has "AHEAD of the pin" && [ "$rc" -ne 0 ]; } && ok "Cilium ahead: BAD (both directions), run fails" || bad "$(grep Cilium "$W/out")"
reset; grep -v ' cilium-operator ' "$FX/cilium.live" >"$FX/x"; mv "$FX/x" "$FX/cilium.live"; run
[ -n "$(badline 'cilium-operator pinned v1.20.2 not running')" ] && ok "a pinned workload that is not running is BAD" || bad "$(grep Cilium "$W/out")"
reset; : >"$FX/cilium.unreadable"; run
[ -n "$(unkline 'Cilium: could not read the running workloads')" ] && ! has "✓ Cilium run the pinned" && [ "$rc" -ne 0 ] && ok "unreadable: UNKNOWN, not a pass" || bad "$(grep Cilium "$W/out")"
reset; printf 'cilium_hubble_drop_log = true\n' >>"$TFV"; run
has "✓ Cilium run the pinned version" && ok "cilium_hubble_drop_log reads the hubble-drops artifact (same version, passes)" || bad "$(grep Cilium "$W/out")"
reset; printf 'cilium_manifest = <<EOT\nx\nEOT\n' >>"$TFV"; run
[ -n "$(unkline 'cilium_manifest or flux_manifest is overridden')" ] && ok "an overridden manifest is UNCHECKED" || bad "no override line"

echo "--- mutation: Flux behind / ahead / extra / unreadable ---"
reset; setlive flux.live kustomize-controller v1.8.5; run
{ [ -n "$(badline 'Flux controllers: kustomize-controller pinned v1.9.6 running v1.8.5')" ] && has "task cluster-bootstrap-sync PROVIDER=stub ROLE=management APPLY=1" && has "BEHIND"; } && ok "Flux behind: BAD with the command to run" || bad "$(grep Flux "$W/out")"
reset; setlive flux.live source-controller v1.9.9; run
{ [ -n "$(badline 'source-controller pinned v1.9.6 running v1.9.9')" ] && has "AHEAD of the pin" && [ "$rc" -ne 0 ]; } && ok "Flux ahead: BAD" || bad "$(grep Flux "$W/out")"
reset; echo "flux old-controller v0.1.0" >>"$FX/flux.live"; run
[ -n "$(badline 'old-controller running v0.1.0 not pinned')" ] && ok "a controller running that the pin does not have is BAD" || bad "$(grep Flux "$W/out")"
reset; : >"$FX/flux.unreadable"; run
[ -n "$(unkline 'Flux controllers: could not read the running workloads')" ] && ok "unreadable: UNKNOWN" || bad "$(grep Flux "$W/out")"
reset; printf 'git_ref = "refs/tags/0.4.0"\n' >"$TFV"; run
! has "Flux controllers" && ! has "apps ref Flux follows" && ok "deploy_flux not true: neither Flux check runs" || bad "Flux checks ran without deploy_flux"

echo "--- mutation: the apps ref, both directions ---"
reset; mkgr refs/tags/0.3.2; run
{ [ -n "$(badline 'the GitRepository openaether follows refs/tags/0.3.2, git_ref declares refs/tags/0.4.0')" ] && has "task cluster-apps-ref PROVIDER=stub ROLE=management APPLY=1" && [ "$rc" -ne 0 ]; } && ok "live GitRepository behind the tfvars: BAD with the command" || bad "$(grep -i 'ref' "$W/out")"
reset; mkks refs/tags/0.3.2; run
[ -n "$(badline 'GIT_REF of the Kustomization openaether-platform is'"'"'refs/tags/0.3.2'"'"'')" ] || [ -n "$(badline "refs/tags/0.3.2', git_ref declares refs/tags/0.4.0")" ]
[ $? -eq 0 ] && [ "$rc" -ne 0 ] && ok "live GIT_REF differs: BAD" || bad "$(grep -i 'ref' "$W/out")"
reset; mkgr refs/tags/0.5.0; mkks refs/tags/0.5.0; run
{ [ -n "$(badline 'follows refs/tags/0.5.0, git_ref declares refs/tags/0.4.0')" ] && has "keep the cluster's ref"; } && ok "cluster AHEAD of the tfvars: BAD too, with the way to keep it" || bad "$(grep -i 'ref' "$W/out")"
reset; printf 'git_ref = "refs/tags/0.5.0"\ndeploy_flux = true\n' >"$TFV"; run
[ -n "$(badline 'git_ref declares refs/tags/0.5.0')" ] && ok "the tfvars changed and the cluster not: BAD" || bad "$(grep -i 'ref' "$W/out")"
reset; : >"$FX/gr.unreadable"; run
[ -n "$(unkline 'apps ref is UNCHECKED')" ] && ! has "both follow the declared git_ref" && ok "objects unreadable: UNKNOWN, not a pass" || bad "$(grep -i 'ref' "$W/out")"
reset; jq -nc '{spec:{ref:{tag:"0.4.0"}}}' >"$FX/gr.json"; run
[ -n "$(unkline 'no spec.ref.name')" ] && ok "another ref form: UNKNOWN" || bad "$(grep -i 'ref' "$W/out")"
reset; mkgr refs/heads/lab/x; mkks refs/heads/lab/x; printf 'git_ref = "refs/heads/lab/x"\ndeploy_flux = true\n' >"$TFV"; run
has "both follow the declared git_ref" && has "is a branch, a moving ref" && ok "a branch in sync passes but is warned about" || bad "$(grep -i 'ref' "$W/out")"
reset; EXTRA=TF_VAR_git_ref=refs/tags/0.3.2 run
[ -n "$(badline 'git_ref declares refs/tags/0.3.2')" ] && ok "TF_VAR_git_ref wins over the tfvars, like tofu" || bad "$(grep -i 'ref' "$W/out")"

echo "--- K2 (lab 26): CoreDNS runs the declared replica count and spread, both directions ---"
reset; run
has "✓ CoreDNS runs the declared 3 replica(s) with a hard spread over nodes" && ok "3 nodes, 3 replicas, hard spread: passes" || bad "$(grep -i coredns "$W/out")"
reset; mkdns 2 false; run
{ [ -n "$(badline 'CoreDNS has 2 replica(s) (spec), the config declares 3')" ] && has "BEHIND the declaration" \
  && has "kubectl -n kube-system patch deployment coredns --type merge --patch-file scripts/ops/coredns-ha-patch.json" && [ "$rc" -ne 0 ]; } \
  && ok "the Talos-created Deployment (2 replicas, no spread): BAD with the one-time command, run fails" || bad "$(grep -i coredns "$W/out")"
reset; mkdns 5 true; run
{ [ -n "$(badline 'CoreDNS has 5 replica(s) (spec), the config declares 3')" ] && has "AHEAD of the declaration"; } && ok "more replicas than declared: BAD too (both directions)" || bad "$(grep -i coredns "$W/out")"
reset; mkdns 3 false; run
{ [ -n "$(badline 'no hard spread over nodes')" ] && [ "$rc" -ne 0 ]; } && ok "the right count without the hard spread: BAD" || bad "$(grep -i coredns "$W/out")"
reset; : >"$FX/coredns.unreadable"; run
{ [ -n "$(unkline 'could not read Deployment kube-system/coredns')" ] && ! has "✓ CoreDNS runs the declared"; } && ok "unreadable: UNKNOWN, not a pass" || bad "$(grep -i coredns "$W/out")"
reset; mkdns 2 false; printf 'coredns_ha = false\n' >>"$TFV"; run
! has "✓ CoreDNS runs the declared" && [ -z "$(badline 'CoreDNS has')" ] && ok "coredns_ha = false: the Talos Deployment is what is declared, nothing to compare" || bad "$(grep -i coredns "$W/out")"
reset; mkdns 2 false; run local
! has "✓ CoreDNS runs the declared" && ok "provider local: not judged" || bad "local judged"
# the one-time patch must say what the manifest says (drift guard)
python3 -I - "$PWD/scripts/ops/coredns-ha-patch.json" "$PWD/infrastructure/opentofu/modules/talos/coredns.yaml.tftpl" <<'PY' && ok "scripts/ops/coredns-ha-patch.json equals the manifest's replicas, tolerations and spread (3 replicas)" || bad "the patch file drifted from coredns.yaml.tftpl"
import json, sys, yaml
patch = json.load(open(sys.argv[1]))
txt = open(sys.argv[2]).read().replace("${replicas}", "3").replace("${min_domains}", "3").replace("${image_tag}", "v0")
dep = next(d for d in yaml.safe_load_all(txt) if d and d["kind"] == "Deployment")
want = {"spec": {"replicas": dep["spec"]["replicas"], "template": {"spec": {k: dep["spec"]["template"]["spec"][k] for k in ("tolerations", "topologySpreadConstraints")}}}}
sys.exit(0 if patch == want else 1)
PY

echo
echo "pins-verify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
