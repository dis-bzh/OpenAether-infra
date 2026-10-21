#!/usr/bin/env bash
# The CoreDNS manifest that modules/talos injects (infra #388), rendered for 3, 2 and 1 replicas and parsed: every object is
# valid YAML, the Service and the budget select the Deployment's pods, replicas never exceed minDomains (a replica that
# waits for ever), nothing carries the 300 s default toleration, and the mutation cases each fail for the right reason.
# Static: it proves the manifest, not what a scheduler or a node does with it.
# Usage: test-coredns-manifest.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL="$ROOT/infrastructure/opentofu/modules/talos/coredns.yaml.tftpl"
W="$(mktemp -d)"; trap 'rm -rf "${W:?}"' EXIT
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

render() { sed -e "s/\${replicas}/$1/g" -e "s/\${min_domains}/$1/g" -e 's/${image_tag}/v0.0.0/g' "${2:-$TPL}"; }

audit() { # file -> prints problems, one per line
  python3 -I - "$1" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
kinds = {d["kind"]: d for d in docs}
bad = []
for k in ("ServiceAccount", "ClusterRole", "ClusterRoleBinding", "ConfigMap", "Service", "PodDisruptionBudget", "Deployment"):
    if k not in kinds:
        bad.append("missing " + k)
if bad:
    print("\n".join(bad)); sys.exit()
dep, svc, pdb = kinds["Deployment"], kinds["Service"], kinds["PodDisruptionBudget"]
spec = dep["spec"]; pod = spec["template"]["spec"]; labels = spec["template"]["metadata"]["labels"]
if spec["selector"]["matchLabels"] != labels: bad.append("the Deployment selector is not its pod labels")
if not svc["spec"]["selector"].items() <= labels.items(): bad.append("the Service selects other pods")
if not pdb["spec"]["selector"]["matchLabels"].items() <= labels.items(): bad.append("the budget selects other pods")
if pdb["spec"].get("maxUnavailable") != 1: bad.append("the budget must allow exactly one disruption")
if svc["spec"].get("clusterIP") != "10.96.0.10": bad.append("the Service must keep the ClusterIP 10.96.0.10")
host = [c for c in pod.get("topologySpreadConstraints", []) if c["topologyKey"] == "kubernetes.io/hostname"]
if not host or host[0]["whenUnsatisfiable"] != "DoNotSchedule": bad.append("no hard hostname spread")
elif host[0].get("minDomains", 0) > spec["replicas"]: bad.append("minDomains above the replicas: a pod waits for ever")
elif host[0].get("minDomains") != spec["replicas"]: bad.append("minDomains must equal the replicas")
if not any(c["topologyKey"] == "topology.kubernetes.io/zone" and c["whenUnsatisfiable"] == "ScheduleAnyway"
           for c in pod.get("topologySpreadConstraints", [])): bad.append("no zone preference")
tol = {t.get("key"): t.get("tolerationSeconds") for t in pod.get("tolerations", [])}
for key in ("node.kubernetes.io/unreachable", "node.kubernetes.io/not-ready"):
    if tol.get(key) != 30: bad.append("%s must be tolerated for 30 s, not %r" % (key, tol.get(key)))
c = pod["containers"][0]
if "cpu" not in c["resources"]["requests"] or "memory" not in c["resources"]["limits"]: bad.append("requests or limits missing")
print("\n".join(bad))
PY
}

for n in 3 2 1; do
  render "$n" >"$W/r$n.yaml"
  out="$(audit "$W/r$n.yaml")"
  [ -z "$out" ] && ok_ "$n replica(s): valid, selectors agree, hard host spread, 30 s tolerations, budget" || bad "$n replica(s): $out"
done
grep -q "replicas: 3" "$W/r3.yaml" && ok_ "the replica count is the one given" || bad "replicas not substituted"

# mutations: each must be caught
mut() { # name sed-expression expected-substring
  sed -e "$2" "$W/r3.yaml" >"$W/m.yaml"
  out="$(audit "$W/m.yaml")"
  grep -q "$3" <<<"$out" && ok_ "caught: $1" || bad "not caught: $1 (got: ${out:-nothing})"
}
mut "300 s default toleration" 's/tolerationSeconds: 30/tolerationSeconds: 300/' "30 s"
mut "hostname spread made soft" 's/DoNotSchedule/ScheduleAnyway/' "hard hostname spread"
mut "minDomains above replicas" 's/minDomains: 3/minDomains: 4/' "waits for ever"
mut "budget allowing two" 's/maxUnavailable: 1$/maxUnavailable: 2/' "exactly one disruption"
mut "other ClusterIP" 's/clusterIP: 10.96.0.10/clusterIP: 10.96.0.11/' "ClusterIP"
mut "budget selecting other pods" '/kind: PodDisruptionBudget/,/---/ s/k8s-app: kube-dns/k8s-app: other/' "budget selects other"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
