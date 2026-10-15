#!/usr/bin/env bash
# Print the inbound rules of a provider's node security group as a Markdown table, read from the code that
# creates them, so that docs/network.md cannot say anything the rules do not. test-flow-matrix.sh compares
# this output with the table between the markers of docs/network.md and docs/network.fr.md.
#
#   scw      the `node_inbound_ports` map of scw/security.tf (the one tests/scaleway.tftest.hcl pins), plus the LB carrier rule
#   ovh      every ingress openstack_networking_secgroup_rule_v2 of ovh/security.tf
#   outscale every Inbound outscale_security_group_rule of outscale/security.tf
#
# Values are printed as written (a variable stays `var.x`): this reads the code, it does not evaluate it.
# --fr prints the same rows with the words of the French twin (the facts are the same, only the labels change).
# Usage: gen-flow-matrix.sh [--fr] <scw|ovh|outscale> [root-dir]
set -euo pipefail

FR=0; [ "${1:-}" != --fr ] || { FR=1; shift; }
PROV="${1:?usage: gen-flow-matrix.sh [--fr] <scw|ovh|outscale> [root-dir]}"
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DIR="$ROOT/infrastructure/opentofu/modules/providers"

HDR='| Rule | Protocol | Ports | Source | Present when |
|---|---|---|---|---|'

render() {
case "$PROV" in
  scw)
    F="$DIR/scw/security.tf"
    [ -f "$F" ] || { echo "✗ $F not found" >&2; exit 1; }
    echo "$HDR"
    # Inside `node_inbound_ports = { ... }`, one rule per line: name = { protocol = "X", ports = "Y" | null }
    awk '
      /node_inbound_ports = \{/ { inmap = 1; next }
      inmap && /^  \}/ { inmap = 0 }
      inmap && /= \{ protocol = / {
        name = $1
        match($0, /protocol = "[A-Z]+"/); proto = substr($0, RSTART + 12, RLENGTH - 13)
        ports = "-"
        if (match($0, /ports = "[^"]+"/)) ports = substr($0, RSTART + 9, RLENGTH - 10)
        printf "| `%s` | %s | %s | node subnet (`scw_subnet_in_use`) | always |\n", name, proto, ports
      }
    ' "$F"
    # The gateway ports and the carrier-range rule are derived from variables, not listed in the map.
    grep -q 'gateway-\${k}' "$F" && echo '| `gateway-<name>` | TCP | `var.app_lb_node_ports` | node subnet (`scw_subnet_in_use`) | `deploy_app_lb` |'
    grep -q 'carrier-' "$F" && echo '| `carrier-<name>` | TCP | the k8s API port when `k8s_lb_mode = "managed"`, and the gateway ports | `100.64.0.0/10` | the matching load balancer exists |'
    ;;
  ovh | outscale)
    F="$DIR/$PROV/security.tf"
    [ -f "$F" ] || { echo "✗ $F not found" >&2; exit 1; }
    echo "$HDR"
    awk -v prov="$PROV" '
      function reset() { name = ""; ing = 0; proto = "all"; pmin = ""; pmax = ""; src = "-"; cond = "always"; cidr = "" }
      function emit(   ports) {
        if (!ing || name == "") return
        ports = (pmin == "" ? "all" : (pmin == pmax ? pmin : pmin "-" pmax))
        if (ports ~ /var\./) ports = "`" ports "`"
        printf "| `%s` | %s | %s | %s | %s |\n", name, proto, ports, src, cond
      }
      function srcfrom(s) {
        if (s ~ /secgroup_v2\.bastion|security_group\.bastion/) return "bastion SG"
        if (s ~ /secgroup_v2\.this|security_group\.this/) return "cluster SG members"
        return ""
      }
      /^resource "(openstack_networking_secgroup_rule_v2|outscale_security_group_rule)"/ { reset(); name = $3; gsub(/"/, "", name); next }
      name == "" { next }
      /^}/ { emit(); reset(); next }
      /direction += "ingress"/ { ing = 1 }
      /flow += "Inbound"/ { ing = 1 }
      /^  (protocol|ip_protocol|    ip_protocol) +=/ || /^ *(protocol|ip_protocol) += "/ { match($0, /"[^"]+"/); proto = substr($0, RSTART + 1, RLENGTH - 2); if (proto == "-1") proto = "all" }
      /(port_range_min|from_port_range) +=/ { v = $3; gsub(/[^0-9a-z_.]/, "", v); pmin = v }
      /(port_range_max|to_port_range) +=/ { v = $3; gsub(/[^0-9a-z_.]/, "", v); pmax = v }
      /(remote_ip_prefix|ip_range) +=/ { v = $0; sub(/^[^=]*= */, "", v); gsub(/"/, "", v); src = (v ~ /each\.value/ ? "`admin_ip`" : (v ~ /outscale_subnet\.public/ ? "public subnet (LB)" : (v ~ /^[0-9]/ ? "`" v "`" : "`" v "`"))) }
      # The group of the rule itself is a 2-space attribute; the group it admits is `remote_group_id` or a deeper `security_group_id`.
      /remote_group_id|^ {4,}security_group_id/ { s = srcfrom($0); if (s != "") src = s }
      /count += +var\.deploy_app_lb/ { cond = "`deploy_app_lb`" }
      /for_each += +toset\(var\.admin_ip\)/ { src = "`admin_ip`" }
    ' "$F"
    ;;
  *) echo "✗ unknown provider: $PROV" >&2; exit 2 ;;
esac
}

if [ "$FR" = 1 ]; then
  render | sed \
    -e 's/^| Rule | Protocol | Ports | Source | Present when |$/| Règle | Protocole | Ports | Source | Présente quand |/' \
    -e 's/node subnet/sous-réseau des nœuds/' \
    -e 's/| always |$/| toujours |/' \
    -e 's/bastion SG/SG du bastion/' \
    -e 's/cluster SG members/membres du SG du cluster/' \
    -e 's/public subnet (LB)/sous-réseau public (LB)/' \
    -e 's/| all | all |/| tous | tous |/' \
    -e 's/the k8s API port when `k8s_lb_mode = "managed"`, and the gateway ports/le port de l'"'"'API k8s quand `k8s_lb_mode = "managed"`, et les ports de la passerelle/' \
    -e 's/the matching load balancer exists/le load balancer correspondant existe/'
else
  render
fi
