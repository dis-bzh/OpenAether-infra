#!/usr/bin/env bash
# The graceful stop of a LIVE control plane before it is replaced (lab 27 sitting 3, F-CPFLAP arm C): the gates that skip it,
# the order of the steps, what a failure of the stop leaves behind, and that a dead node is untouched. Stub talosctl and
# kubectl; function tests plus the real script's --dry-run in a throwaway tree.
# Usage: test-cp-graceful-stop.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB="$(mktemp -d)"
trap 'rm -rf "${STUB:?}"' EXIT
PASS=0; FAIL=0
ok_() { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
RR="$ROOT/scripts/ops/rolling-replace.sh"

# talosctl: `service etcd` is healthy for the endpoints listed in $STUB_HEALTHY (one port per line); `shutdown` is logged and
# fails when $STUB_SHUTDOWN_FAILS exists.
cat >"$STUB/talosctl" <<'S'
#!/usr/bin/env bash
echo "talosctl $*" >>"$STUB_CALLS"
case "$*" in
  *"service etcd"*) ep="$(sed -E 's/.*-e 127.0.0.1:([0-9]+).*/\1/' <<<"$*")"
    grep -qx "$ep" "$STUB_HEALTHY" && printf 'NODE  SERVICE\n1  etcd  Running  OK  HEALTH  OK\n' || exit 1 ;;
  *shutdown*) [ -f "$STUB_SHUTDOWN_FAILS" ] && exit 1; [ -f "$STUB_NEVER_STOPS" ] || : >"$STUB_STOPPED"; exit 0 ;;
esac
exit 0
S
chmod +x "$STUB/talosctl"
export PATH="$STUB:$PATH" STUB_CALLS="$STUB/calls" STUB_HEALTHY="$STUB/healthy" STUB_SHUTDOWN_FAILS="$STUB/shutfails" STUB_NEVER_STOPS="$STUB/never" STUB_STOPPED="$STUB/stopped"

extract() { awk -v fns="$1" 'BEGIN{n=split(fns,a,",");for(i=1;i<=n;i++)w[a[i]]=1} /^[a-z_]+\(\) \{/{nm=$1;sub(/\(\).*/,"",nm);ins=(nm in w)} ins{print} ins&&/^\}/{ins=0}' "$ROOT/scripts/lib/roll-gates.sh"; }
info() { :; }; ok() { printf 'OK:%s\n' "$*"; }; warn() { printf 'WARN:%s\n' "$*" >&2; }; hr() { :; }
die() { printf '%s\n' "$*" >&2; exit 42; }
# shellcheck disable=SC2034  # read by the extracted functions
TUNNEL_OFFSET=0
# The endpoint probe: an endpoint is "down" once the shutdown has been ordered, unless the node never stops.
oa_talos_endpoint_ok() { [ "$2" = 50000 ] && [ -f "$STUB_STOPPED" ] && return 1; return 0; }
eval "$(cat <<'EOT'
GRACEFUL_STOP_TIMEOUT=2
GRACEFUL_STOP_POLL=1
EOT
)"
eval "$(extract 'talos_ep,healthy_peer_cp,cp_graceful_stop_refusal,stop_cp_gracefully')"
run() { # <index> → rc; output in $STUB/out; calls in $STUB/calls
  : >"$STUB/calls"; rm -f "${STUB:?}/stopped"
  (stop_cp_gracefully cp-0 10.0.0.10 "$1") >"$STUB/out" 2>&1; echo $?
}

echo "=== cp_graceful_stop_refusal / stop_cp_gracefully: the gates ==="
CP_IPS=(10.0.0.10 10.0.0.11 10.0.0.12)
printf '%s\n' 50000 50001 50002 >"$STUB_HEALTHY"; rm -f "${STUB:?}/shutfails" "${STUB:?}/never"
rc="$(run 0)"
{ [ "$rc" = 0 ] && grep -q 'talosctl shutdown -e 127.0.0.1:50000 -n 10.0.0.10 --force --wait=false' "$STUB/calls" && grep -q 'OK:cp-0 stopped' "$STUB/out"; } \
  && ok_ "3 of 3 healthy: the node is shut down (forced past Talos's own drain, no client wait) and seen to stop" || bad "healthy 3/3: rc=$rc $(cat "$STUB/out") $(cat "$STUB/calls")"

printf '%s\n' 50000 50001 >"$STUB_HEALTHY"
rc="$(run 0)"
{ [ "$rc" = 0 ] && ! grep -q 'shutdown' "$STUB/calls" && grep -q 'SKIPPED.*2 of 3' "$STUB/out"; } \
  && ok_ "2 of 3 control planes healthy: NO shutdown, a warning, rc 0 (the current path goes on)" || bad "2/3 healthy: rc=$rc $(cat "$STUB/out")"

printf '%s\n' 50001 50002 >"$STUB_HEALTHY"
rc="$(run 0)"
{ [ "$rc" = 0 ] && ! grep -q 'shutdown' "$STUB/calls" && grep -q 'SKIPPED' "$STUB/out"; } \
  && ok_ "the node's own etcd not healthy: NO shutdown" || bad "self unhealthy: rc=$rc $(cat "$STUB/out")"

CP_IPS=(10.0.0.10); printf '%s\n' 50000 >"$STUB_HEALTHY"
rc="$(run 0)"
{ [ "$rc" = 0 ] && ! grep -q 'shutdown' "$STUB/calls" && grep -q 'SKIPPED.*only 1 control plane' "$STUB/out"; } \
  && ok_ "a single control plane: NO shutdown" || bad "1 CP: rc=$rc $(cat "$STUB/out")"
CP_IPS=(10.0.0.10 10.0.0.11); printf '%s\n' 50000 50001 >"$STUB_HEALTHY"
rc="$(run 0)"
{ [ "$rc" = 0 ] && ! grep -q 'shutdown' "$STUB/calls"; } && ok_ "two control planes: NO shutdown" || bad "2 CP: rc=$rc"
CP_IPS=(10.0.0.10 10.0.0.11 10.0.0.12 10.0.0.13 10.0.0.14); printf '%s\n' 50000 50001 50002 50003 >"$STUB_HEALTHY"
rc="$(run 0)"
{ [ "$rc" = 0 ] && ! grep -q 'shutdown' "$STUB/calls"; } && ok_ "5 control planes with 4 healthy: NO shutdown (no margin on quorum)" || bad "4/5: rc=$rc"
CP_IPS=(10.0.0.10 10.0.0.11 10.0.0.12)

echo
echo "=== a failure of the stop never ends the run ==="
printf '%s\n' 50000 50001 50002 >"$STUB_HEALTHY"; : >"$STUB/shutfails"
rc="$(run 0)"
{ [ "$rc" = 0 ] && grep -q 'shutdown was refused.*untouched' "$STUB/out" && ! grep -q 'uncordon' "$STUB/calls"; } \
  && ok_ "a refused shutdown: warning, rc 0, the node untouched, the replacement goes on" || bad "refused: rc=$rc $(cat "$STUB/out")"
rm -f "${STUB:?}/shutfails"; : >"$STUB/never"
t0=$SECONDS; rc="$(run 0)"; dt=$((SECONDS - t0))
{ [ "$rc" = 0 ] && grep -q 'still answers 2s after' "$STUB/out" && [ "$dt" -le 6 ]; } \
  && ok_ "a node that never stops: bounded wait (${dt}s of 2), warning, rc 0" || bad "never stops: rc=$rc dt=$dt $(cat "$STUB/out")"
rm -f "${STUB:?}/never"
# Tunnels down: the node endpoint AND the peers fail TLS, which must not be read as "stopped".
oa_talos_endpoint_ok() { return 1; }
rc="$(run 0)"
{ [ "$rc" = 0 ] && ! grep -q 'OK:cp-0 stopped' "$STUB/out" && grep -q 'still answers' "$STUB/out"; } \
  && ok_ "no endpoint answers at all (tunnels down): NOT reported as stopped" || bad "tunnels down read as stopped: $(cat "$STUB/out")"
oa_talos_endpoint_ok() { [ "$2" = 50000 ] && [ -f "$STUB_STOPPED" ] && return 1; return 0; }

echo
echo "=== the place in the flow of replace_node ==="
body="$(awk '/^replace_node\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RR")"
a="$(grep -n 'cordon_drain "\$node_name"$' <<<"$body" | tail -1 | cut -d: -f1)"
b="$(grep -n 'stop_cp_gracefully' <<<"$body" | head -1 | cut -d: -f1)"
c="$(grep -n '^    etcd_remove_member' <<<"$body" | head -1 | cut -d: -f1)"
d="$(grep -n 'saved_plan_apply "\${node_name}-instance" .* apply' <<<"$body" | head -1 | cut -d: -f1)"
[ -z "$d" ] && d="$(grep -n 'tofu 1/2' <<<"$body" | head -1 | cut -d: -f1)"
{ [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ]; } \
  && ok_ "drain, THEN the graceful stop, THEN the etcd member removal, THEN the applies" || bad "order wrong (drain:$a stop:$b etcd:$c apply:$d)"
grep -B1 'stop_cp_gracefully "\$node_name"' <<<"$body" | grep -q '"\$t" == "cp" && \$DEAD -eq 0' \
  && ok_ "only for a control plane and never for a dead node" || bad "the call is not guarded by cp and not-dead"
awk '/^  else$/{e=1} e&&/stop_cp_gracefully/{x=1} /end of the replacement path/{exit !x}' "$RR" \
  && ok_ "it sits in the replacement branch: the in-place --upgrade path is not touched" || bad "the call is outside the replacement branch"

echo
echo "=== --dry-run shows the extra step (real script, throwaway tree) ==="
T="$STUB/tree"; mkdir -p "$T/scripts/ops" "$T/scripts/internal" "$T/cluster/envs" "$STUB/bin"
cp "$RR" "$T/scripts/ops/"; ln -s "$ROOT/scripts/lib" "$T/scripts/lib"
printf '#!/usr/bin/env bash\necho true\n' >"$T/scripts/internal/bootstrap-in-state.sh"; chmod +x "$T/scripts/internal/bootstrap-in-state.sh"
printf 'cluster_name = "lab"\nenvironment = "dev"\n' >"$T/cluster/envs/management-ovh.tfvars"; : >"$T/cluster/talosconfig"; : >"$T/cluster/kubeconfig"
cat >"$STUB/bin/tofu" <<'S'
#!/usr/bin/env bash
[ "$1 $2" = "output -json" ] && echo '{"control_plane_private_ips":{"value":["10.0.0.10","10.0.0.11","10.0.0.12"]},"worker_private_ips":{"value":["10.0.0.20"]}}'
[ "$1 $2" = "state list" ] && printf '%s\n' 'module.ovh[0].openstack_compute_instance_v2.control_plane[0]' 'module.ovh[0].openstack_compute_instance_v2.worker[0]'
exit 0
S
cat >"$STUB/bin/kubectl" <<'S'
#!/usr/bin/env bash
case "$*" in *"get nodes -o jsonpath"*) printf 'lab-dev-cp-0 10.0.0.10\nlab-dev-worker-0 10.0.0.20\n' ;; esac
exit 0
S
chmod +x "$STUB/bin/tofu" "$STUB/bin/kubectl"
dry() { ( cd "$T/cluster" && PATH="$STUB/bin:$STUB:$PATH" bash "$T/scripts/ops/rolling-replace.sh" ovh "$@" --dry-run --yes ) >"$STUB/out" 2>&1; }
dry --cp-only --ip=10.0.0.10
{ grep -q 'would: talosctl shutdown -e 127.0.0.1:50000 -n 10.0.0.10 --force --wait=false, then wait up to 300s' "$STUB/out" \
  && grep -q 'only if all 3 control planes report a healthy etcd' "$STUB/out"; } \
  && ok_ "a live control plane: the dry run prints the shutdown, its wait and its condition" || bad "dry run of a live cp: $(head -c 1500 "$STUB/out")"
dry --workers-only --ip=10.0.0.20
{ grep -q 'would: kubectl cordon' "$STUB/out" && ! grep -q 'talosctl shutdown' "$STUB/out"; } \
  && ok_ "a worker: no shutdown step" || bad "dry run of a worker: $(head -c 1000 "$STUB/out")"
dry --cp-only --dead --node=lab-dev-cp-0 --ip=10.0.0.10
{ grep -q 'NOT drain (the node is dead)' "$STUB/out" && ! grep -q 'talosctl shutdown' "$STUB/out"; } \
  && ok_ "a dead control plane: the current path, no shutdown" || bad "dry run of a dead cp: $(head -c 1000 "$STUB/out")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
