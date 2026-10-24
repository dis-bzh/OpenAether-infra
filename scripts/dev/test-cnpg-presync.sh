#!/usr/bin/env bash
# ==============================================================================
# cnpg-presync.sh (study LAB-B2): the 0.4.0 synchronous block is put on the live CNPG Clusters BEFORE the apps ref moves.
#
# The real script runs in a throwaway copy of the repository layout. kubectl is ONE stub: it serves a fixture list of Clusters,
# Backups, pods and nodes as the JSON the API would give, applies a merge patch with jq, answers `psql` by mode (ok / needs a
# reload first / never), and logs every call, so "the dry run writes nothing", "only spec.postgresql.synchronous is patched",
# "nothing is deleted or forced" and "R1 comes before the timeout" are asserted on the log. What a real PostgreSQL answers, how
# long CNPG takes and the lost reload of cloudnative-pg#11627 are NOT reproduced: the study measured them on a reduced lab.
# Offline, no credentials, no cluster.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

SCRIPT=scripts/ops/cnpg-presync.sh
[ -f "$SCRIPT" ] || { echo "✗ $SCRIPT does not exist — nothing was checked" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }
BASH_BIN="$(command -v bash)"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"; FX="$W/fx"
mkdir -p "$C/envs" "$W/scripts/ops" "$W/scripts/lib" "$W/bin" "$FX"
cp "$SCRIPT" "$W/scripts/ops/"; cp scripts/lib/common.sh scripts/lib/pins.sh "$W/scripts/lib/"
A="$W/scripts/ops/cnpg-presync.sh"
echo "apiVersion: v1" >"$C/kubeconfig"
TFV="$C/envs/management-stub.tfvars"
printf 'variable "talos_version" {\n  default = "v1.14.4"\n}\nvariable "kubernetes_version" {\n  default = "v1.37.1"\n}\n' >"$C/variables.tf"

cat >"$W/stub" <<STUB
#!/usr/bin/env bash
echo "kubectl \$*" >>"$W/calls.log"
echo "\$KUBECONFIG" >>"$W/kubeconfig.seen"
sql=""; for a; do sql="\$a"; done
case "\$*" in
  *"get clusters.postgresql.cnpg.io -l openaether.io/managed=true -o json")
    [ -f "$FX/nocrd" ] && { echo 'error: the server doesn'"'"'t have a resource type "clusters"' >&2; exit 1; }
    [ -f "$FX/list.rc" ] && { echo "Unable to connect to the server: i/o timeout" >&2; exit 1; }
    cat "$FX/clusters.json" ;;
  "-n "*" get clusters.postgresql.cnpg.io "*" -o json") jq -c --arg n "\$5" '.items[] | select(.metadata.name == \$n)' "$FX/clusters.json" ;;
  "-n "*" get backups.postgresql.cnpg.io -o json") [ -f "$FX/backups.rc" ] && { echo "forbidden" >&2; exit 1; }; cat "$FX/backups.json" ;;
  "-n "*" get pods -l cnpg.io/cluster="*" -o json") cat "$FX/pods.json" ;;
  "-n "*" patch clusters.postgresql.cnpg.io "*" --type merge -p "*)
    [ -f "$FX/patch.rc" ] && { echo "forbidden" >&2; exit 1; }
    jq -c --arg n "\$5" --argjson p "\$9" '.items |= map(if .metadata.name == \$n then (. * \$p | .status.readyInstances = .spec.instances | .status.instanceNames = [range(.spec.instances) | "\(\$n)-\(. + 1)"]) else . end)' "$FX/clusters.json" >"$FX/x" && mv "$FX/x" "$FX/clusters.json" ;;
  "-n "*" exec "*" -c postgres -- psql -U postgres -Atc "*)
    echo "exec \$4 \$sql" >>"$W/exec.log"
    pod="\$4"; c="\${pod%-*}"
    good=0; mode="\$(cat "$FX/mode")"
    [ "\$mode" = ok ] && good=1
    [ "\$mode" = needs-reload ] && [ -f "$FX/reloaded-\$c" ] && good=1
    names=\$good; stat=\$good; st=quorum
    [ "\$mode" = no-names ] && { names=0; stat=1; }
    [ "\$mode" = async-replicas ] && { names=1; stat=1; st=async; }
    case "\$sql" in
      "show synchronous_standby_names") [ "\$names" = 1 ] && echo "ANY 1 (\"\$c-2\",\"\$c-3\")" || echo "" ;;
      "select application_name, sync_state from pg_stat_replication") [ "\$stat" = 1 ] && { echo "\$c-2|\$st"; echo "\$c-3|\$st"; } ;;
      "select pg_reload_conf()") touch "$FX/reloaded-\$c"; echo t ;;
      *) echo "UNEXPECTED SQL \$sql" >>"$W/calls.log"; exit 99 ;;
    esac ;;
  "get nodes -o json") cat "$FX/nodes.json" ;;
  *"custom-columns=V:.status.nodeInfo.osImage"*) while read -r v; do echo "Talos (\$v)"; done <"$FX/talos.live" ;;
  *"custom-columns=V:.status.nodeInfo.kubeletVersion"*) cat "$FX/k8s.live" ;;
  *) echo "UNEXPECTED \$*" >>"$W/calls.log"; exit 99 ;;
esac
STUB
chmod +x "$W/stub"; ln -s "$W/stub" "$W/bin/kubectl"

SYNC='{"method":"any","number":1,"dataDurability":"required","failoverQuorum":true}'
mk() { # <name> <instances> <sync json or null> [labels json] [plugins json]
  jq -nc --arg n "$1" --argjson i "$2" --argjson s "$3" --argjson l "${4:-{\}}" --argjson pl "${5:-[]}" '
    {metadata:{name:$n, namespace:"foundation-databases", labels:({"openaether.io/managed":"true"} + $l)},
     spec:({instances:$i, postgresql:(if $s == null then {} else {synchronous:$s} end)} + (if ($pl|length) > 0 then {plugins:$pl} else {} end)),
     status:{phase:"Cluster in healthy state", readyInstances:$i, currentPrimary:"\($n)-1", instanceNames:[range($i) | "\($n)-\(. + 1)"]}}'
}
setclusters() { jq -sc '{items: .}' >"$FX/clusters.json"; }
reset() {
  rm -rf "$FX"; mkdir -p "$FX"; : >"$W/calls.log"; : >"$W/exec.log"; : >"$W/kubeconfig.seen"
  echo ok >"$FX/mode"
  { mk zitadel-db 3 null; mk grafana-db 3 null; } | setclusters
  jq -nc '{items: [{spec:{cluster:{name:"zitadel-db"}}, status:{phase:"completed", stoppedAt:"2023-11-14T00:00:00Z"}},
                   {spec:{cluster:{name:"grafana-db"}}, status:{phase:"completed", stoppedAt:"2023-11-14T01:00:00Z"}}]}' >"$FX/backups.json"
  jq -nc '{items: []}' >"$FX/pods.json"
  printf 'v1.14.4\n' >"$FX/talos.live"; printf 'v1.37.1\nv1.37.1\n' >"$FX/k8s.live"
  jq -nc '{items: [range(3) | {metadata:{name:"n\(.)"},spec:{},status:{conditions:[{type:"Ready",status:"True"}]}}]}' >"$FX/nodes.json"
  printf 'talos_version = "v1.14.4"\nkubernetes_version = "v1.37.1"\n' >"$TFV"
}
run() { ( cd "$C" && env -i PATH="$W/bin:$PATH" HOME="$W" KUBECONFIG=/nonexistent/other OA_NOW=1700000000 OA_PRESYNC_POLL=0.2 OA_PRESYNC_KICK_AFTER=1 OA_PRESYNC_TIMEOUT=3 "$BASH_BIN" "$A" --tfvars "$TFV" "$@" ) </dev/null >"$W/out" 2>"$W/err"; }
calls() { grep -c -- "$1" "$W/calls.log"; }
execs() { grep -c -- "$1" "$W/exec.log"; }
said() { grep -qF -- "$1" "$W/out" "$W/err"; }
patches() { calls ' patch clusters.postgresql.cnpg.io'; }
live() { jq -c --arg n "$1" ".items[] | select(.metadata.name == \$n) | $2" "$FX/clusters.json"; }

echo "--- a new cluster: no CNPG Cluster, no CRD: nothing to presync, quiet ---"
reset; jq -nc '{items: []}' >"$FX/clusters.json"; run --apply; rc=$?
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && [ ! -s "$W/err" ] && [ "$(patches)" = 0 ] && ok "exit 0, no output, nothing patched" || bad "rc $rc: $(cat "$W/out" "$W/err")"
reset; : >"$FX/nocrd"; run; rc=$?
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && [ ! -s "$W/err" ] && ok "no CNPG CRD yet: exit 0, quiet" || bad "rc $rc: $(cat "$W/out" "$W/err")"

echo "--- every Cluster already has the block: in sync ---"
reset; { mk zitadel-db 3 "$SYNC"; mk grafana-db 3 "$SYNC"; } | setclusters; run --apply; rc=$?
[ "$rc" = 0 ] && said "nothing to presync" && [ "$(patches)" = 0 ] && [ "$(execs .)" = 0 ] && ok "exit 0, nothing patched, nothing asked of a pod" || bad "rc $rc: $(cat "$W/out" "$W/err")"
reset; { mk zitadel-db 3 "$(jq -c '.failoverQuorum = false' <<<"$SYNC")"; } | setclusters; run; rc=$?
[ "$rc" = 3 ] && ok "failoverQuorum false is a difference (each of the four values counts)" || bad "rc $rc"
reset; { mk zitadel-db 3 "$(jq -c '.dataDurability = "preferred"' <<<"$SYNC")"; } | setclusters; run; rc=$?
[ "$rc" = 3 ] && ok "dataDurability preferred is a difference" || bad "rc $rc"

echo "--- dry run on 0.3.x Clusters: lists them, selects by label and excludes profile and restore-test Clusters, writes nothing ---"
reset; { mk zitadel-db 3 null; mk grafana-db 3 null; mk app-ha 3 null '{"openaether.io/db-profile":"ha"}'; mk rt-abc 1 null; } | setclusters; run; rc=$?
[ "$rc" = 3 ] && said "~ foundation-databases/zitadel-db" && said "~ foundation-databases/grafana-db" && ok "exit 3, both differing Clusters listed" || bad "rc $rc: $(cat "$W/out" "$W/err")"
! said "app-ha" && ! said "rt-abc" && ok "a db-profile Cluster and an rt-* copy are not selected" || bad "profile or restore-test Cluster listed"
said "NOTHING was written" && said "task cnpg-presync PROVIDER=… ROLE=… APPLY=1" && ok "it says nothing was written and names the command" || bad "no such line"
[ "$(patches)" = 0 ] && [ "$(execs .)" = 0 ] && ok "no patch, no exec" || bad "calls: $(tr '\n' '|' <"$W/calls.log")"
grep -q 'get clusters.postgresql.cnpg.io -l openaether.io/managed=true' "$W/calls.log" && ok "the selection is the managed label, not a name" || bad "selection call: $(head -3 "$W/calls.log")"
! grep -E 'zitadel-db|grafana-db' "$A" | grep -vE '^\s*#' >/dev/null && ok "the script names no Cluster" || bad "a Cluster name is hard-coded"
[ -s "$W/kubeconfig.seen" ] && ! grep -qv "^$C/kubeconfig\$" "$W/kubeconfig.seen" && ok "kubectl used the cluster directory's kubeconfig, not the caller's" || bad "kubeconfig seen: $(tr '\n' ' ' <"$W/kubeconfig.seen")"

echo "--- --apply: only spec.postgresql.synchronous is patched, then it waits for the quorum ---"
reset; { mk zitadel-db 3 null; mk grafana-db 3 "$SYNC"; } | setclusters; run --apply; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "rc $rc: $(cat "$W/out" "$W/err")"
[ "$(patches)" = 1 ] && grep -q 'patch clusters.postgresql.cnpg.io zitadel-db --type merge' "$W/calls.log" && ok "one merge patch, on the differing Cluster only" || bad "calls: $(grep patch "$W/calls.log")"
body="$(grep ' patch ' "$W/calls.log" | sed 's/.* -p //')"
[ "$(jq -c . <<<"$body")" = "$(jq -nc --argjson w "$SYNC" '{spec:{postgresql:{synchronous:$w}}}')" ] && ok "the body is exactly spec.postgresql.synchronous = any / 1 / required / failoverQuorum" || bad "body: $body"
[ "$(live zitadel-db .spec.postgresql.synchronous)" = "$SYNC" ] && ok "the live Cluster holds the block" || bad "live: $(live zitadel-db .spec)"
grep -q 'exec zitadel-db-1 show synchronous_standby_names' "$W/exec.log" && grep -q 'exec zitadel-db-1 select application_name, sync_state from pg_stat_replication' "$W/exec.log" \
  && ok "it asked the primary for synchronous_standby_names and pg_stat_replication" || bad "exec: $(cat "$W/exec.log")"
! grep -qE ' (delete|replace|create|apply|scale) | --force|promote|switchover' "$W/calls.log" && ok "no delete, replace, create, apply, force, promote or switchover" || bad "forbidden call: $(grep -E 'delete|force|promote' "$W/calls.log")"
[ "$(execs pg_reload_conf)" = 0 ] && ok "a Cluster that converges at once is not reloaded" || bad "reload without need"
said "Next: task cluster-apps-ref" && ok "it names the next step" || bad "no next step"
run --apply; rc=$?
[ "$rc" = 0 ] && said "nothing to presync" && [ "$(patches)" = 1 ] && ok "second run: in sync, no second patch (idempotent)" || bad "rc $rc, patches $(patches)"

echo "--- fewer than 3 instances: it stops instead of guessing; --scale is the explicit way ---"
reset; { mk zitadel-db 3 "$SYNC"; mk grafana-db 2 null; } | setclusters; run --apply; rc=$?
[ "$rc" = 2 ] && [ "$(patches)" = 0 ] && said "has 2 instance(s)" && said "APPLY=1 SCALE=1" && ok "refused (exit 2) before any write, the message names SCALE=1" || bad "rc $rc: $(cat "$W/err")"
reset; { mk zitadel-db 3 "$SYNC"; mk grafana-db 2 null; } | setclusters; run; rc=$?
[ "$rc" = 3 ] && said "has 2 instance(s)" && ok "the dry run says it as well" || bad "rc $rc"
reset; { mk zitadel-db 3 "$SYNC"; mk grafana-db 2 null; } | setclusters; run --apply --scale; rc=$?
body="$(grep ' patch ' "$W/calls.log" | sed 's/.* -p //')"
[ "$rc" = 0 ] && [ "$(jq -c . <<<"$body")" = "$(jq -nc --argjson w "$SYNC" '{spec:{instances:3,postgresql:{synchronous:$w}}}')" ] \
  && ok "--scale: instances 3 and the block in ONE patch (the shape the study measured), converged" || bad "rc $rc body $body: $(cat "$W/err")"
[ "$(live grafana-db .spec.instances)" = 3 ] && ok "the Cluster has 3 instances" || bad "instances: $(live grafana-db .spec.instances)"
reset; { mk zitadel-db 3 null; mk grafana-db 3 null; } | setclusters; run --apply --scale; rc=$?
body="$(grep ' patch ' "$W/calls.log" | head -1 | sed 's/.* -p //')"
[ "$rc" = 0 ] && ! jq -e '.spec.instances' <<<"$body" >/dev/null && ok "--scale does not touch the instances of a Cluster that already has 3" || bad "rc $rc body $body"

echo "--- preconditions refuse, nothing is written ---"
refused() { # <label> <expected text>
  [ "$rc" = 2 ] && [ "$(patches)" = 0 ] && [ "$(execs .)" = 0 ] && said "$2" && ok "$1: exit 2, $2" || bad "$1: rc $rc, patches $(patches): $(cat "$W/err" | head -3)"
}
reset; jq -c '.items[1].status.phase = "Cluster in a degraded state"' "$FX/clusters.json" >"$FX/x" && mv "$FX/x" "$FX/clusters.json"; run --apply; rc=$?
refused "a Cluster not healthy (even one that needs nothing)" "foundation-databases/grafana-db is not healthy"
reset; jq -c '.items[0].status.readyInstances = 2' "$FX/clusters.json" >"$FX/x" && mv "$FX/x" "$FX/clusters.json"; run --apply; rc=$?
refused "readyInstances below instances" "ready 2/3"
reset
jq -c '.items[0].status.stoppedAt = "2023-11-01T00:00:00Z"' "$FX/backups.json" >"$FX/x" && mv "$FX/x" "$FX/backups.json"; run --apply; rc=$?
refused "the only Backup of zitadel-db is old" "task backup-verify"
reset; jq -c '.items = []' "$FX/backups.json" >"$FX/x" && mv "$FX/x" "$FX/backups.json"; run --apply; rc=$?
refused "no Backup at all" "kubectl cnpg backup zitadel-db -n foundation-databases"
reset; jq -c '.items[0].status.phase = "failed"' "$FX/backups.json" >"$FX/x" && mv "$FX/x" "$FX/backups.json"; run --apply; rc=$?
refused "a failed Backup does not count" "no completed Backup"
reset; : >"$FX/backups.rc"; run --apply; rc=$?
refused "Backups unreadable" "UNKNOWN"
reset; jq -c '.items[1].status.conditions[0].status = "False"' "$FX/nodes.json" >"$FX/x" && mv "$FX/x" "$FX/nodes.json"; run --apply; rc=$?
refused "a node not Ready (roll under way)" "roll may be under way"
reset; printf 'v1.14.3\nv1.14.4\n' >"$FX/talos.live"; run --apply; rc=$?
refused "Talos mixed across nodes" "disagree on Talos"
reset; printf 'v1.14.2\n' >"$FX/talos.live"; run --apply; rc=$?
refused "Talos behind the pin" "roll is pending"
PLUG='[{"name":"barman-cloud.cloudnative-pg.io","isWALArchiver":true}]'
reset; { mk zitadel-db 3 null '{}' "$PLUG"; mk grafana-db 3 "$SYNC"; } | setclusters
jq -nc '{items: [{metadata:{name:"zitadel-db-1"},spec:{containers:[{name:"postgres"}]}}, {metadata:{name:"zitadel-db-2"},spec:{containers:[{name:"postgres"},{name:"plugin-barman-cloud"}]}}]}' >"$FX/pods.json"
run --apply; rc=$?
refused "a pod predates the plugin sidecar while the plugin is enabled" "do NOT promote or switch over"
said "zitadel-db-1" && ! said "zitadel-db-2 predate" && ok "the old pod is named, the one with the sidecar is not" || bad "pods named: $(cat "$W/err")"
reset; { mk zitadel-db 3 null '{}' "$PLUG"; mk grafana-db 3 "$SYNC"; } | setclusters
jq -nc '{items: [{metadata:{name:"zitadel-db-1"},spec:{containers:[{name:"postgres"},{name:"plugin-barman-cloud"}]}}]}' >"$FX/pods.json"
run --apply; rc=$?
[ "$rc" = 0 ] && ok "(control) a plugin enabled and every pod with its sidecar is not a reason to refuse" || bad "control rc $rc: $(cat "$W/err")"
reset; run; rc=$?
[ "$rc" = 3 ] && ! said "REFUSED" && ok "(control) with every precondition met the dry run does not say REFUSED" || bad "control rc $rc"
reset; jq -c '.items[0].status.phase = "Cluster in a degraded state"' "$FX/clusters.json" >"$FX/x" && mv "$FX/x" "$FX/clusters.json"; run; rc=$?
[ "$rc" = 3 ] && said "An apply would be REFUSED" && [ "$(patches)" = 0 ] && ok "the dry run reports the refusal an apply would meet (exit 3, no write)" || bad "rc $rc"

echo "--- a Cluster that needs a reload: R1 runs after KICK_AFTER, on every instance, then it converges ---"
reset; echo needs-reload >"$FX/mode"; run --apply; rc=$?
[ "$rc" = 0 ] && [ "$(execs 'select pg_reload_conf()')" -ge 3 ] && ok "converged after the reload (exit 0)" || bad "rc $rc, reloads $(execs 'select pg_reload_conf()'): $(cat "$W/err")"
for p in zitadel-db-1 zitadel-db-2 zitadel-db-3 grafana-db-1 grafana-db-2 grafana-db-3; do
  grep -q "exec $p select pg_reload_conf()" "$W/exec.log" || bad "no reload on $p"
done
[ "$(execs 'select pg_reload_conf()')" = 6 ] && ok "pg_reload_conf on all 3 instances of both Clusters, once each" || bad "reload count $(execs 'select pg_reload_conf()')"
said "reloading the configuration on every instance" && ok "the kick is announced" || bad "no kick line"
! grep -qE ' (delete|replace|create|apply) | --force' "$W/calls.log" && ok "still no delete or force" || bad "forbidden call"

echo "--- never converges: exit 1 with the break-glass steps printed, nothing deleted or forced ---"
reset; echo never >"$FX/mode"; { mk zitadel-db 3 null; } | setclusters; run --apply; rc=$?
[ "$rc" = 1 ] && said "did not converge within 3 s" && ok "exit 1 at the timeout" || bad "rc $rc: $(cat "$W/err")"
said "Break-glass for foundation-databases/zitadel-db" && said "select pg_reload_conf()" && said "delete the OLD replica pods ONE AT A TIME (zitadel-db-2 zitadel-db-3)" && said "delete the old primary pod (zitadel-db-1) GRACEFULLY" \
  && ok "R1 and R2 are printed with the real pod names, replicas before the primary" || bad "break-glass text: $(cat "$W/err")"
said "NEVER add --force" && said "Do NOT run kubectl cnpg promote" && ok "the force and promote warnings are there" || bad "warnings missing"
! grep -qE ' (delete|replace|create) | --force' "$W/calls.log" && ok "the script itself deleted nothing and forced nothing" || bad "forbidden call: $(grep -E 'delete|force' "$W/calls.log")"
[ "$(execs 'select pg_reload_conf()')" = 3 ] && ok "R1 ran once before giving up" || bad "reloads $(execs 'select pg_reload_conf()')"

echo "--- each half of the convergence check counts on its own ---"
reset; echo no-names >"$FX/mode"; { mk zitadel-db 3 null; } | setclusters; run --apply; rc=$?
[ "$rc" = 1 ] && said "synchronous_standby_names is empty on zitadel-db-1" && ok "replicas streaming but synchronous_standby_names empty: not converged (exit 1)" || bad "rc $rc: $(cat "$W/err")"
reset; echo async-replicas >"$FX/mode"; { mk zitadel-db 3 null; } | setclusters; run --apply; rc=$?
[ "$rc" = 1 ] && said "fewer than 2 replica(s) quorum/sync" && ok "names set but the replicas are async in pg_stat_replication: not converged (exit 1)" || bad "rc $rc: $(cat "$W/err")"
echo "--- failures are never read as success ---"
reset; : >"$FX/list.rc"; run --apply; rc=$?
[ "$rc" = 1 ] && said "cannot list the CNPG Clusters" && [ "$(patches)" = 0 ] && ok "API unreachable is not 'no Cluster': exit 1" || bad "rc $rc: $(cat "$W/err")"
reset; : >"$FX/patch.rc"; run --apply; rc=$?
[ "$rc" = 1 ] && said "refused" && ok "patch refused: exit 1" || bad "rc $rc"
reset; rm -f "$C/kubeconfig"; run; rc=$?
[ "$rc" = 1 ] && said "no kubeconfig" && ok "no kubeconfig: exit 1" || bad "rc $rc"
echo "apiVersion: v1" >"$C/kubeconfig"
reset; run --bogus; rc=$?
[ "$rc" = 1 ] && ok "unknown argument: exit 1" || bad "rc $rc"
reset; ( cd "$C" && env -i PATH="$W/bin:$PATH" HOME="$W" "$BASH_BIN" "$A" ) </dev/null >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" = 1 ] && said "--tfvars FILE is required" && ok "no --tfvars: exit 1" || bad "rc $rc"

echo "--- nothing secret is printed ---"
reset; echo never >"$FX/mode"; run --apply
! grep -qiE 'password|token|AKIA|BEGIN|secret' "$W/out" "$W/err" && ok "no secret-looking text in the output" || bad "output has secret-looking text"

echo
echo "cnpg-presync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
