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
  *"deploy cilium-operator -o json") [ -f "$FX/operator.unreadable" ] && exit 1; cat "$FX/operator.json" ;;
  *"get ns "*|*"get namespace "*) [ -f "$FX/no-flux-ns" ] && exit 1; echo Active ;;
  *"wait --for=condition=Available"*) echo ok ;;
  "-n flux-system get deployments -o json") [ -f "$FX/flux.unreadable" ] && exit 1; render "$FX/flux.live" deploy ;;
  "-n kube-system get daemonsets,deployments -o json") [ -f "$FX/cilium.unreadable" ] && exit 1; render "$FX/cilium.live" ds ;;
  *"gitrepositories.source.toolkit.fluxcd.io openaether -o json") [ -f "$FX/gr.unreadable" ] && exit 1; cat "$FX/gr.json" ;;
  *"kustomizations.kustomize.toolkit.fluxcd.io openaether-platform -o json") cat "$FX/ks.json" ;;
  *"get clusters.postgresql.cnpg.io -l openaether.io/managed=true -o json")
    [ -f "$FX/cnpg.nocrd" ] && { echo "error: the server doesn't have a resource type \"clusters\"" >&2; exit 1; }
    [ -f "$FX/cnpg.unreadable" ] && { echo "Unable to connect to the server" >&2; exit 1; }
    cat "$FX/cnpg.json" ;;
  *"exec "*"-c postgres -- psql -U postgres -Atc "*)
    [ -f "$FX/exec.unreadable" ] && exit 1
    sql=""; for a; do sql="\$a"; done
    case "\$sql" in
      "show synchronous_standby_names") cat "$FX/names.txt" ;;
      "select application_name, sync_state from pg_stat_replication") cat "$FX/repl.txt" ;;
      *) exit 1 ;;
    esac ;;
  *"get failoverquorums.postgresql.cnpg.io "*)
    [ -f "$FX/fq.missing" ] && { echo 'Error from server (NotFound): failoverquorums "x" not found' >&2; exit 1; }
    [ -f "$FX/fq.unreadable" ] && { echo "Unable to connect to the server" >&2; exit 1; }
    echo "failoverquorum.postgresql.cnpg.io/x" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$W/stub"; for t in kubectl sleep; do ln -s "$W/stub" "$W/bin/$t"; done

mkdns() { # <replicas> <hard hostname spread: true|false> — the Deployment kube-system/coredns as the apiserver returns it
  jq -nc --argjson r "$1" --argjson h "$2" '{spec:{replicas:$r,template:{spec:(if $h then {topologySpreadConstraints:[{topologyKey:"kubernetes.io/hostname",whenUnsatisfiable:"DoNotSchedule",maxSkew:1}]} else {} end)}}}' >"$FX/coredns.json"; }
mkop() { jq -nc --argjson r "$1" '{spec:{replicas:$r}}' >"$FX/operator.json"; }
mkgr() { jq -nc --arg r "$1" '{spec:{ref:{name:$r}}}' >"$FX/gr.json"; }
mkks() { jq -nc --arg r "$1" '{spec:{postBuild:{substitute:{GIT_REF:$r}}}}' >"$FX/ks.json"; }
reset() {
  rm -rf "$FX"; mkdir -p "$FX"; cp "$W/flux.target" "$FX/flux.live"; cp "$W/cilium.target" "$FX/cilium.live"
  mkgr refs/tags/0.4.0; mkks refs/tags/0.4.0; mkdns 3 true; mkop 2
  echo '{"items":[]}' >"$FX/cnpg.json"
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

echo "--- study LAB-B2: the platform CNPG Clusters run the 0.4.0 synchronous replication and archive ---"
SYNCB='{"method":"any","number":1,"dataDurability":"required","failoverQuorum":true}'
mkcl() { # <name> <instances> <sync json|null> <ContinuousArchiving status> [labels json] — the Clusters a list returns (one file)
  jq -nc --arg n "$1" --argjson i "$2" --argjson s "$3" --arg a "$4" --argjson l "${5:-{\}}" \
    '{metadata:{name:$n, labels:({"openaether.io/managed":"true"} + $l)}, spec:{instances:$i, postgresql:(if $s == null then {} else {synchronous:$s} end)},
      status:{currentPrimary:"\($n)-1", conditions:[{type:"ContinuousArchiving", status:$a}]}}'
}
cnpg_fx() { jq -sc '{items: .}' >"$FX/cnpg.json"; }
cnpg_ok() { printf 'ANY 1 ("db-2","db-3")\n' >"$FX/names.txt"; printf 'db-2|quorum\ndb-3|quorum\n' >"$FX/repl.txt"; }
CNPGH="The platform CNPG Clusters"
reset; run
! has "$CNPGH" && ok "no CNPG Cluster in the namespace: the section is silent" || bad "section printed"
reset; : >"$FX/cnpg.nocrd"; run
! has "$CNPGH" && ! has "could not list the CNPG" && ok "no CNPG CRD (a pure-infra cluster): silent, not UNKNOWN" || bad "$(grep -i cnpg "$W/out")"
reset; mkcl db 3 "$SYNCB" True | cnpg_fx; cnpg_ok; run
has "✓ foundation-databases/db: ContinuousArchiving True" && has "✓ foundation-databases/db: synchronous_standby_names set on db-1, 2 replica(s) quorum/sync" && has "✓ foundation-databases/db: the FailoverQuorum object exists" \
  && [ -z "$(badline 'foundation-databases/db')" ] && ok "a converged Cluster passes all four checks" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 null True | cnpg_fx; printf '\n' >"$FX/names.txt"; : >"$FX/repl.txt"; run
{ [ -n "$(badline 'foundation-databases/db: spec.postgresql.synchronous is not the 0.4.0 block')" ] && has "task cnpg-presync PROVIDER=stub ROLE=management APPLY=1" && [ "$rc" -ne 0 ]; } \
  && ok "a 0.3.x Cluster (no block): BAD with the command to run, run fails" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 "$(jq -c '.dataDurability = "preferred"' <<<"$SYNCB")" True | cnpg_fx; cnpg_ok; run
[ -n "$(badline 'is not the 0.4.0 block')" ] && ok "a weaker block (durability preferred) is BAD too" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 "$SYNCB" False | cnpg_fx; cnpg_ok; run
{ [ -n "$(badline 'ContinuousArchiving is False')" ] && has "docs/upgrade.md (break-glass R1, R2)" && has "task backup-verify"; } && ok "ContinuousArchiving False: BAD with the pointers" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 "$SYNCB" True | cnpg_fx; printf '\n' >"$FX/names.txt"; printf 'db-2|async\ndb-3|async\n' >"$FX/repl.txt"; run
{ [ -n "$(badline 'synchronous_standby_names is EMPTY on db-1')" ] && has "cloudnative-pg#11627" && has "select pg_reload_conf()"; } && ok "declared and synchronous_standby_names EMPTY: BAD with the reload" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 null True | cnpg_fx; cnpg_ok; run
[ -n "$(badline 'the running state and the declaration disagree')" ] && ok "running synchronous but not declared: BAD (the other direction)" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 "$SYNCB" True | cnpg_fx; printf 'ANY 1 ("db-2")\n' >"$FX/names.txt"; printf 'db-2|quorum\ndb-3|async\n' >"$FX/repl.txt"; run
[ -n "$(badline 'only 1 of 2 replica(s) are quorum/sync')" ] && ok "one replica not in the quorum: BAD" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 "$SYNCB" True | cnpg_fx; cnpg_ok; : >"$FX/fq.missing"; run
[ -n "$(badline 'FailoverQuorum object does not exist')" ] && ok "declared failoverQuorum and no object: BAD" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 null True | cnpg_fx; printf '\n' >"$FX/names.txt"; : >"$FX/repl.txt"; run
[ -n "$(badline 'a FailoverQuorum object exists but the spec does not declare')" ] && ok "an object the spec does not declare: BAD (the other direction)" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 "$SYNCB" True | cnpg_fx; cnpg_ok; : >"$FX/exec.unreadable"; run
[ -n "$(unkline 'could not ask the primary db-1')" ] && ! has "synchronous_standby_names set on" && [ "$rc" -ne 0 ] && ok "the primary cannot be asked: UNKNOWN, not a pass" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 "$SYNCB" True | cnpg_fx; cnpg_ok; : >"$FX/fq.unreadable"; run
[ -n "$(unkline 'could not read the FailoverQuorum object')" ] && ok "the FailoverQuorum object cannot be read: UNKNOWN" || bad "$(grep 'foundation-databases' "$W/out")"
reset; : >"$FX/cnpg.unreadable"; run
[ -n "$(unkline 'could not list the CNPG Clusters of foundation-databases')" ] && ok "the list fails (not 'no CRD'): UNKNOWN" || bad "$(grep -i cnpg "$W/out")"
reset; { mkcl db 3 "$SYNCB" True; mkcl app-ha 3 null False '{"openaether.io/db-profile":"ha"}'; mkcl rt-x 1 null False; } | cnpg_fx; cnpg_ok; run
! has "app-ha" && ! has "rt-x" && ok "a profile Cluster and an rt-* copy are not judged (same selection as cnpg-presync)" || bad "$(grep 'foundation-databases' "$W/out")"
reset; mkcl db 3 null False | cnpg_fx; run local
! has "$CNPGH" && ok "provider local: not judged" || bad "local judged"

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
# (the patch is the 3-zone shape: the template rendered with zone_hard = true; cluster-coredns-ha.sh softens the zone term below 3 zones)
python3 -I - "$PWD/scripts/ops/coredns-ha-patch.json" "$PWD/infrastructure/opentofu/modules/talos/coredns.yaml.tftpl" <<'PY' && ok "scripts/ops/coredns-ha-patch.json equals the manifest's replicas, tolerations and spread (3 replicas, 3 zones: the zone term required)" || bad "the patch file drifted from coredns.yaml.tftpl"
import json, sys, yaml
patch = json.load(open(sys.argv[1]))
txt = open(sys.argv[2]).read().replace("${replicas}", "3").replace("${min_domains}", "3").replace("${image_tag}", "v0")
txt = txt.replace("${zone_when}", "DoNotSchedule").replace("${zone_min_domains}", "3")
txt = "".join(l for l in txt.splitlines(True) if not l.startswith("%{"))
zone = [c for c in patch["spec"]["template"]["spec"]["topologySpreadConstraints"] if c["topologyKey"] == "topology.kubernetes.io/zone"]
assert len(zone) == 1 and zone[0]["whenUnsatisfiable"] == "DoNotSchedule" and zone[0]["minDomains"] == 3 and zone[0]["nodeTaintsPolicy"] == "Honor", "the patch must carry the required zone term"
dep = next(d for d in yaml.safe_load_all(txt) if d and d["kind"] == "Deployment")
want = {"spec": {"replicas": dep["spec"]["replicas"], "template": {"spec": {k: dep["spec"]["template"]["spec"][k] for k in ("tolerations", "topologySpreadConstraints")}}}}
sys.exit(0 if patch == want else 1)
PY

echo "--- the Cilium operator runs 2 replicas (critical-path audit) ---"
reset; run
has "✓ the Cilium operator runs 2 replica(s)" && ok "2 replicas: passes" || bad "$(grep -i operator "$W/out")"
reset; mkop 1; run
{ [ -n "$(badline 'the Cilium operator has 1 replica(s), the manifest declares 2')" ] && has "kubectl -n kube-system patch deployment cilium-operator --type merge --patch-file scripts/ops/cilium-operator-ha-patch.json" && [ "$rc" -ne 0 ]; } \
  && ok "the Talos-created operator (1 replica): BAD with the one-time command, run fails" || bad "$(grep -i operator "$W/out")"
reset; : >"$FX/operator.unreadable"; run
{ [ -n "$(unkline 'could not read Deployment kube-system/cilium-operator')" ] && ! has "✓ the Cilium operator runs"; } && ok "unreadable: UNKNOWN, not a pass" || bad "$(grep -i operator "$W/out")"
reset; mkop 1; run local
! has "the Cilium operator has" && ok "provider local: not judged" || bad "local judged"
# the shipped manifest and the one-time patch say the same, and the local render keeps one replica
python3 -I - "$PWD/scripts/ops/cilium-operator-ha-patch.json" "$PWD/$REAL_M/cilium.yaml" "$PWD/$REAL_M/cilium-hubble-drops.yaml" <<'PY' && ok "cilium-operator-ha-patch.json equals the operator Deployment of both committed artifacts (2 replicas, zone preference, budget of one, required hostname anti-affinity)" || bad "the patch file or the committed Cilium artifacts drifted"
import json, sys, yaml
patch = json.load(open(sys.argv[1]))
for f in sys.argv[2:]:
    docs = [d for d in yaml.safe_load_all(open(f)) if d]
    dep = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "cilium-operator")
    pod = dep["spec"]["template"]["spec"]
    want = {"spec": {"replicas": dep["spec"]["replicas"], "strategy": dep["spec"]["strategy"], "template": {"spec": {"topologySpreadConstraints": pod["topologySpreadConstraints"]}}}}
    assert patch == want, f
    pdb = next(d for d in docs if d["kind"] == "PodDisruptionBudget" and d["metadata"]["name"] == "cilium-operator")
    assert pdb["spec"]["maxUnavailable"] == 1 and pdb["spec"]["selector"]["matchLabels"].items() <= dep["spec"]["template"]["metadata"]["labels"].items()
    anti = pod["affinity"]["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
    assert any(t["topologyKey"] == "kubernetes.io/hostname" for t in anti), "hostnetwork pods must never share a node"
    assert dep["spec"]["replicas"] == 2
PY
grep -q -- '--set operator.replicas=1' scripts/bootstrap/render-bootstrap-manifests.sh && [ "$(grep -c -- '--set operator.replicas=1' scripts/bootstrap/render-bootstrap-manifests.sh)" = 1 ] \
  && ok "the local render keeps one operator replica (one Docker node); production renders 2" || bad "operator.replicas in the render script is not 1 (local) + 2 (production)"

echo
echo "pins-verify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
