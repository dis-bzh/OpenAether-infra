#!/usr/bin/env bash
# OpenAether — adopt a Talos bootstrap the state does not remember (#67)
#
# A bootstrap that reached the node but was never recorded (interrupted apply,
# dropped tunnel) is re-sent by the next phase 2 at a live etcd: refused with
# AlreadyExists or, on a CP with an empty disk, accepted and forking etcd. So:
# when the state lacks the resource AND a control plane already reports etcd
# members, import it. The provider ignores the import ID and sends nothing to a
# node (scripts/dev/test-bootstrap-import.sh). Any other answer does nothing, so
# the worst this can be is inert — it only ever adds the import.
#
# Usage, from the cluster dir with the backend inited and the tunnels open:
#   adopt-bootstrap.sh <role> <provider>
# ADOPT_PROBE_TIMEOUT: seconds one `talosctl etcd members` may take (default 15).

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROLE="${1:?usage: adopt-bootstrap.sh <role> <provider>}"
PROVIDER="${2:?usage: adopt-bootstrap.sh <role> <provider>}"
ADDR='module.talos.talos_machine_bootstrap.this[0]'
skip() { echo "▶ adopt-bootstrap: $* — bootstrapping as usual"; exit 0; }

state="$(tofu state list 2>/dev/null)" || skip "cannot read the state (the plan below will say why)"
grep -qxF "$ADDR" <<<"$state" && exit 0 # recorded: the normal re-run

for bin in jq talosctl timeout; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin is not installed"
done
OFFSET="$(oa_tunnel_offset)" || exit 1

mapfile -t CPS < <(tofu output -json control_plane_private_ips 2>/dev/null |
  jq -r '.[]? | select(type == "string" and length > 0)' 2>/dev/null)
[ "${#CPS[@]}" -gt 0 ] || skip "no control plane in the outputs"

# This cluster's own client config: ./talosconfig is one path shared by every
# cluster in the checkout.
TC="$(mktemp)" || skip "no temporary file"
trap 'rm -f "$TC"' EXIT
{ tofu output -raw talosconfig >"$TC" 2>/dev/null && [ -s "$TC" ]; } || skip "no talosconfig in the outputs"

# rc decides, never the text: a node that cannot be asked counts as "no etcd".
# </dev/null because talosctl reads stdin. -e is the tunnel, -n the node itself.
found="" members="" n=0
for i in "${!CPS[@]}"; do
  out="$(TALOSCONFIG="$TC" timeout -k 5 "${ADOPT_PROBE_TIMEOUT:-15}" talosctl \
    -e "127.0.0.1:$((50000 + OFFSET + i))" -n "${CPS[$i]}" etcd members </dev/null 2>/dev/null)" || continue
  n="$(grep -cE ':2380' <<<"$out")"
  [ "${n:-0}" -ge 1 ] || continue
  found="$i" members="$out"; break
done
[ -n "$found" ] || skip "no control plane reports an etcd member"

echo "▶ adopt-bootstrap: etcd on cp-${found} (${CPS[$found]}) already has ${n} member(s), of ${#CPS[@]} control plane(s),"
echo "  yet the state has no ${ADDR}. Another bootstrap would be refused"
echo "  (AlreadyExists) or fork etcd. Adopting it: nothing is sent to any node."
sed 's/^/    /' <<<"$members"

cmd=(tofu import -input=false -var-file="envs/${ROLE}-${PROVIDER}.tfvars" -var talos_bootstrap=true "$ADDR" "${CPS[0]}")
"${cmd[@]}" && { echo "✓ adopted ${ADDR}"; exit 0; }
echo "✗ tofu import failed and the state is unchanged. Run it by hand, then re-run:" >&2
echo "    ${TF_DATA_DIR:+TF_DATA_DIR=$TF_DATA_DIR }tofu import -input=false -var-file=envs/${ROLE}-${PROVIDER}.tfvars -var talos_bootstrap=true '${ADDR}' ${CPS[0]}" >&2
exit 1
