#!/usr/bin/env bash
# ==============================================================================
# bastion-identity-check.sh — per-person bastion accounts, SSH-CA certificates for them, revocation, and the closed
# egress, proven OFFLINE on a real sshd and a real nftables before a paid VM boots the same bytes.
#
# Renders the shared cloud-init with bastion_admins (alice, bob), an SSH CA, the baseline (RevokedKeys, LogLevel
# VERBOSE) and egress.mode = "closed", puts the exact files on Ubuntu 22.04 / 24.04 in Docker (users made like
# cloud-init's `lock_passwd: true`) and checks:
#
#   accounts     each key logs in as its own account and only that one; the sshd login line names the person and the
#                key; the shared account still works; nobody gets the sudo group
#   SSH-CA       a certificate signed for principal <name> logs in as <name> and as nobody else (auth_principals/<name>),
#                an 8 h certificate works inside its window and an expired one is refused
#   revocation   a key in /etc/ssh/revoked_keys is refused while the other operators still log in; what that does to a
#                certificate of that key is MEASURED and printed
#   tunnels      -L to 6443 and 50000 carries traffic under PermitOpen; 8200 is refused when closed, allowed when legacy
#   egress       the closed ruleset (nft -c, then loaded in a container's own network namespace): 6443/50000 reach the
#                cluster subnet, 80/443/8200 do not; the legacy ruleset still allows them (control)
#
# Nothing here writes to the host: containers have no --privileged, NET_ADMIN is held inside the container's own
# network namespace. What it cannot prove: that a cloud image boots with it, a provider's metadata or DHCP path, a
# real FIDO key (no token in a container).
#
# Usage: ./scripts/dev/bastion-identity-check.sh [22.04 24.04]     (task bastion-identity-check)
# Requires: docker, tofu, ssh-keygen, python3 + pyyaml. Run directly it skips (exit 0) without docker; the task
# refuses instead, since a skip would record a green receipt for a proof that never ran.
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="${TEMPLATE:-$ROOT/infrastructure/opentofu/modules/providers/_shared/bastion-cloud-init.yaml.tftpl}"
RELEASES=("$@"); [ ${#RELEASES[@]} -gt 0 ] || RELEASES=(22.04 24.04)

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

command -v docker >/dev/null 2>&1 || { echo "SKIP — docker not available"; exit 0; }
for c in tofu ssh-keygen python3; do command -v "$c" >/dev/null 2>&1 || { echo "✗ $c not found" >&2; exit 1; }; done
python3 -c 'import yaml' 2>/dev/null || { echo "✗ python3 pyyaml module not found" >&2; exit 1; }

WORK="$(mktemp -d)"
LABEL="oa-bastion-identity-check-$$"
cleanup() { docker ps -aq --filter "label=$LABEL" | xargs -r docker rm -f >/dev/null 2>&1; docker network rm "$LABEL" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

# --- keys and render -----------------------------------------------------------------------------------------
for k in shared alice bob carol ca; do ssh-keygen -q -t ed25519 -N '' -f "$WORK/$k" -C "$k@oa-check"; done
ssh-keygen -q -t ed25519 -N '' -f "$WORK/expired" -C "expired@oa-check"
mkdir -p "$WORK/render"
# <name> <egress object> <private_cidr> — writes $WORK/<name>.yaml, always with the same operators and a CA.
# dave has no key at all: a certificate-only account (the SSH CA is the whole of his access).
render() {
  cat >"$WORK/render/main.tf" <<EOF
output "r" {
  value = templatefile("$TEMPLATE", {
    bastion_user = "bastion", ssh_keys = ["$(cat "$WORK/shared.pub")"], private_cidr = "$3",
    extra_packages = [], extra_write_files = [], extra_runcmd = [],
    ssh_ca_public_key = "$(cat "$WORK/ca.pub")", ssh_ca_principals = "",
    baseline = { enabled = true, audit_logging = true, restrict_ssh_source = false, time_servers = [], revoked_keys = [] },
    admin_ip = [],
    admins = {
      alice = { ssh_keys = ["$(cat "$WORK/alice.pub")"] }
      bob   = { ssh_keys = ["$(cat "$WORK/bob.pub")"] }
      dave  = { ssh_keys = [] }
    },
    egress = $2
  })
}
EOF
  tofu -chdir="$WORK/render" init -input=false >/dev/null 2>&1 &&
    tofu -chdir="$WORK/render" apply -auto-approve -input=false >/dev/null 2>&1 &&
    tofu -chdir="$WORK/render" output -raw r >"$WORK/$1.yaml"
}
stage() { # <name> — the file tree (modes applied) and the runcmd, as cloud-init would write them
  python3 -I - "$WORK" "$1" <<'PY'
import json, os, sys, yaml
work, name = sys.argv[1:3]
doc = yaml.safe_load(open(f"{work}/{name}.yaml"))
root = f"{work}/{name}-tree"
for f in doc["write_files"]:
    path = root + f["path"]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(f.get("content", ""))
    os.chmod(path, int(str(f.get("permissions", "0644")), 8))
json.dump(doc, open(f"{work}/{name}.json", "w"))
PY
}
CLOSED='{ mode = "closed", dns_servers = ["192.0.2.53", "2001:db8::53"], ntp_servers = ["192.0.2.123"] }'
LEGACY='{ mode = "legacy", dns_servers = [], ntp_servers = [] }'
render closed "$CLOSED" "10.0.0.0/24" && render legacy "$LEGACY" "10.0.0.0/24" || { echo "✗ could not render the template" >&2; exit 1; }
stage closed; stage legacy

echo "=== the rendered cloud-config ==="
python3 -I - "$WORK" <<'PY' && ok "accounts: the operators are in bastion-admins only, the shared account has no sudo group, nobody has a password" || bad "the user definitions are wrong"
import json, sys
d = json.load(open(f"{sys.argv[1]}/closed.json"))
u = {x["name"]: x for x in d["users"] if isinstance(x, dict)}
assert set(u) == {"bastion", "alice", "bob", "dave"}, set(u)
assert u["alice"]["groups"] == ["bastion-admins"] and u["bob"]["groups"] == ["bastion-admins"], u
assert "sudo" not in u["bastion"]["groups"], u["bastion"]
assert all(x["lock_passwd"] is True and x["sudo"] is False for x in u.values()), u
PY
ROOTDIR="$WORK/closed-tree/etc/ssh"
[ "$(cat "$ROOTDIR/authorized_keys.d/alice")" = "$(cat "$WORK/alice.pub")" ] && [ "$(cat "$ROOTDIR/authorized_keys.d/bob")" = "$(cat "$WORK/bob.pub")" ] \
  && ! grep -qF "$(awk '{print $2}' "$WORK/alice.pub")" "$ROOTDIR/authorized_keys.d/bastion" \
  && ok "each operator has a file of their own, and the shared account's file does not hold their key" || bad "authorized_keys.d is not one file per person"
[ "$(cat "$ROOTDIR/auth_principals/alice")" = alice ] && [ "$(cat "$ROOTDIR/auth_principals/bob")" = bob ] && [ "$(cat "$ROOTDIR/auth_principals/dave")" = dave ] && [ ! -e "$ROOTDIR/auth_principals/bastion" ] \
  && ok "a principals file per operator holds the operator's own name" || bad "auth_principals is not one name per operator"
grep -qx 'PermitOpen \*:6443 \*:50000' "$ROOTDIR/sshd_config.d/99-bastion-hardening.conf" && ok "closed: PermitOpen has no 8200" || bad "closed: PermitOpen still lists 8200"
grep -qx 'PermitOpen \*:6443 \*:50000 \*:8200' "$WORK/legacy-tree/etc/ssh/sshd_config.d/99-bastion-hardening.conf" && ok "(control) legacy: PermitOpen keeps 8200" || bad "legacy PermitOpen changed"

# --- containers ---------------------------------------------------------------------------------------------
build_image() { # <release> — the same image bastion-baseline-check.sh uses, built once
  docker image inspect "oa-bastion-baseline-test:$1" >/dev/null 2>&1 && return 0
  docker build -q -t "oa-bastion-baseline-test:$1" --build-arg "REL=$1" - >/dev/null 2>&1 <<'DOCKERFILE'
ARG REL
FROM ubuntu:${REL}
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    openssh-server openssh-client nftables auditd sudo python3 procps iproute2 netbase >/dev/null && mkdir -p /run/sshd
DOCKERFILE
}

# In-container: prints "ok|msg", "bad|msg" or "info|msg". Keys are in /k, the staged tree in /stage.
SSHD_CHECKS='
r() { printf "%s|%s\n" "$1" "$2"; }
groupadd bastion-admins
for u in bastion alice bob dave; do useradd -m -s /bin/bash -G bastion-admins "$u"; passwd -l "$u" >/dev/null; done   # lock_passwd: true
( cd /stage && find . -type f ) | while read -r f; do install -D -o root -g root -m "$(stat -c %a "/stage/$f")" "/stage/$f" "/$f"; done
mkdir -p /etc/ssh/auth_principals
# The runcmd of a baseline render: root-owned, 0644 (read here, since a locked-down copy is what production has).
for u in bastion alice bob dave; do chown root:root /etc/ssh/authorized_keys.d/$u; chmod 0644 /etc/ssh/authorized_keys.d/$u; done
sed -i "s/^AcceptEnv/#AcceptEnv/" /etc/ssh/sshd_config
sshd -t 2>/tmp/t.err && r ok "sshd -t accepts the rendered config" || { r bad "sshd -t rejects it: $(cat /tmp/t.err)"; exit 0; }
/usr/sbin/sshd -E /var/log/sshd.log; sleep 1
SSHO="-o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5"
can() { ssh -i "$1" $SSHO -l "$2" 127.0.0.1 true 2>/dev/null; }   # <identity file> <user>
tun() { local id=$1 u=$2; shift 2; ssh -i "$id" $SSHO -l "$u" -f -N "$@" 127.0.0.1 2>/dev/null; }   # <identity> <user> -L ...
FPA="$(ssh-keygen -lf /k/alice.pub | awk "{print \$2}")"

can /k/alice alice && r ok "alice logs in as alice with her key" || r bad "alice cannot log in as alice"
can /k/bob bob && r ok "bob logs in as bob with his key" || r bad "bob cannot log in as bob"
can /k/shared bastion && r ok "the shared account still works with the shared key" || r bad "the shared account is broken"
can /k/alice bob && r bad "alice logged in AS BOB with her own key" || r ok "alice'"'"'s key is refused for bob"
can /k/alice bastion && r bad "alice logged in on the shared account" || r ok "alice'"'"'s key is refused on the shared account"
can /k/shared alice && r bad "the shared key logged in as alice" || r ok "the shared key is refused for alice"
grep -q "Accepted publickey for alice .*SHA256:${FPA#SHA256:}" /var/log/sshd.log && r ok "the login line names alice and her key fingerprint (the person is in the log, not a pool)" || r bad "no login line with alice and her fingerprint"
grep -q "Accepted key .* found at /etc/ssh/authorized_keys.d/alice:1" /var/log/sshd.log && r ok "VERBOSE logs the authorized_keys file of the key: it is alice'"'"'s own" || r bad "no authorized_keys.d/alice line in the log"

# SSH-CA. carol has no entry in any authorized_keys: a certificate is her only way in.
sign() { # <principals> <validity> <out-prefix> [key]
  local key=${4:-/k/carol}
  cp "$key" "/tmp/$3"; cp "$key.pub" "/tmp/$3.pub"
  ssh-keygen -q -s /k/ca -I "oa-check-$3" -n "$1" -V "$2" -O permit-port-forwarding "/tmp/$3.pub"
}
can /k/carol alice && r bad "(control) carol logged in without a certificate" || r ok "(control) carol'"'"'s bare key opens nothing"
sign alice +8h c-alice
can /tmp/c-alice alice && r ok "an 8 h certificate for principal alice logs in as alice" || r bad "the alice certificate was refused"
can /tmp/c-alice bob && r bad "alice'"'"'s certificate logged in AS BOB" || r ok "alice'"'"'s certificate is refused for bob (principal mismatch)"
can /tmp/c-alice bastion && r bad "alice'"'"'s certificate logged in on the shared account" || r ok "alice'"'"'s certificate is refused on the shared account"
sign bob +8h c-bob
if can /tmp/c-bob bob && ! can /tmp/c-bob alice; then r ok "bob'"'"'s certificate works for bob only"; else r bad "bob'"'"'s certificate failed for bob or also opened alice"; fi
sign alice -2h:-1h c-old
can /tmp/c-old alice && r bad "an EXPIRED certificate logged in" || r ok "an expired certificate is refused: an 8 h certificate is its own offboarding"
# dave has no key in any file: only a certificate with his name opens his account.
sign dave +8h c-dave
if can /tmp/c-dave dave && ! can /tmp/c-dave alice && ! can /k/carol dave; then r ok "a certificate-only operator (ssh_keys = []) logs in with his certificate, not as anyone else, and his bare key opens nothing"
else r bad "the certificate-only account does not behave"; fi
sign dave -2h:-1h c-dave-old
can /tmp/c-dave-old dave && r bad "dave'"'"'s expired certificate logged in" || r ok "when his certificate expires dave is out: no key of his is left to remove"
VALID="$(ssh-keygen -L -f /tmp/c-alice-cert.pub | grep -E "Valid:" | sed "s/^ *//")"
r info "certificate window: $VALID"

# Tunnels: PermitOpen.
for p in 6443 50000 8200; do
  python3 -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b\"tunnel-ok\")
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer((\"127.0.0.1\", $p), H).serve_forever()" &
done
sleep 1
get() { python3 -c "import urllib.request,sys; print(urllib.request.urlopen(sys.argv[1], timeout=4).read().decode())" "$1" 2>/dev/null; }
tun /k/alice alice -o ExitOnForwardFailure=yes -L 16443:127.0.0.1:6443
tun /k/alice alice -o ExitOnForwardFailure=yes -L 15000:127.0.0.1:50000
tun /k/alice alice -L 18200:127.0.0.1:8200
[ "$(get http://127.0.0.1:16443/)" = tunnel-ok ] && r ok "alice'"'"'s -L to 6443 carries traffic" || r bad "alice'"'"'s 6443 tunnel does not carry traffic"
[ "$(get http://127.0.0.1:15000/)" = tunnel-ok ] && r ok "alice'"'"'s -L to 50000 carries traffic" || r bad "alice'"'"'s 50000 tunnel does not carry traffic"
if [ "$1" = closed ]; then
  [ "$(get http://127.0.0.1:18200/)" = tunnel-ok ] && r bad "closed: -L to 8200 carried traffic" || r ok "closed: -L to 8200 is refused"
else
  [ "$(get http://127.0.0.1:18200/)" = tunnel-ok ] && r ok "(control) legacy: -L to 8200 carries traffic" || r bad "legacy: the 8200 tunnel is broken"
fi
pkill -x ssh 2>/dev/null

# Revocation: the file is read at every authentication. An unrelated key first (a control for the next lines).
cat /k/expired.pub >> /etc/ssh/revoked_keys
can /k/alice alice && r ok "revoking an unrelated key leaves alice in" || r bad "revoking ANOTHER key locked alice out"
cat /k/alice.pub >> /etc/ssh/revoked_keys
can /k/alice alice && r bad "alice'"'"'s revoked key still logs in" || r ok "alice'"'"'s revoked key is refused"
can /k/bob bob && r ok "bob is unaffected by revoking alice" || r bad "revoking alice locked bob out"
# What revoking the KEY of a certificate does (the certificate carries the same public key): measured, not assumed.
cat /k/carol.pub >> /etc/ssh/revoked_keys
if can /tmp/c-alice alice; then r info "a certificate STILL logs in after its public key is in revoked_keys (revoke by expiry or the CA, or use a KRL)"
else r ok "a certificate is refused once its public key is in revoked_keys"; fi
: > /etc/ssh/revoked_keys
can /k/alice alice && r ok "an emptied revoked_keys lets alice back in" || r bad "login did not recover after emptying revoked_keys"
'

for REL in "${RELEASES[@]}"; do
  echo
  echo "=== Ubuntu $REL ==="
  if ! build_image "$REL"; then bad "could not build the test image for $REL (network?)"; continue; fi
  IMG="oa-bastion-baseline-test:$REL"
  for MODE in closed legacy; do
    C="oa-bic-$$-$MODE-${REL//./}"
    docker run -d --name "$C" --label "$LABEL" "$IMG" sleep infinity >/dev/null
    docker cp "$WORK/$MODE-tree/." "$C:/stage" >/dev/null
    mkdir -p "$WORK/k" && cp "$WORK"/{shared,alice,bob,carol,ca,expired}{,.pub} "$WORK/k/" 2>/dev/null
    docker cp "$WORK/k/." "$C:/k" >/dev/null
    docker exec "$C" bash -c 'chmod 600 /k/shared /k/alice /k/bob /k/carol /k/ca /k/expired'
    OUT="$(docker exec "$C" bash -c "$SSHD_CHECKS" bash "$MODE" 2>&1)"
    echo "  -- egress $MODE"
    while IFS='|' read -r verdict msg; do
      case "$verdict" in ok) ok "$msg" ;; bad) bad "$msg" ;; info) echo "     · $msg" ;; "") ;; *) echo "     $verdict${msg:+|$msg}" ;; esac
    done <<<"$OUT"
    docker rm -f "$C" >/dev/null 2>&1
  done

  echo "  -- the nftables output chain"
  for MODE in closed legacy; do
    if docker run --rm --cap-add NET_ADMIN -v "$WORK/$MODE-tree/etc/nftables.conf:/n.nft:ro" "$IMG" nft -c -f /n.nft 2>/dev/null; then ok "nft -c accepts the $MODE ruleset (IPv4 and IPv6 pinned servers included)"
    else bad "nft -c rejects the $MODE ruleset"; fi
  done

  # Behaviour in a container's own network namespace: the ruleset is loaded on S, and S tries ports on T. The cluster
  # subnet is the docker network's, so "inside private_cidr" is real.
  docker network create "$LABEL" >/dev/null 2>&1 || true
  SUBNET="$(docker network inspect "$LABEL" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)"
  if [ -z "$SUBNET" ]; then bad "could not create a docker network for the egress behaviour test"; continue; fi
  T="oa-bic-$$-tgt-${REL//./}"
  docker run -d --name "$T" --label "$LABEL" --network "$LABEL" "$IMG" sleep infinity >/dev/null
  for p in 80 443 6443 8200 50000; do docker exec -d "$T" python3 -m http.server "$p" --bind 0.0.0.0 >/dev/null 2>&1; done
  TIP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$T")"
  render beh_closed "$CLOSED" "$SUBNET" && render beh_legacy "$LEGACY" "$SUBNET" && stage beh_closed && stage beh_legacy || { bad "could not render the behaviour rulesets"; continue; }
  sleep 1
  for MODE in closed legacy; do
    S="oa-bic-$$-srv-$MODE-${REL//./}"
    docker run -d --name "$S" --label "$LABEL" --network "$LABEL" --cap-add NET_ADMIN "$IMG" sleep infinity >/dev/null
    docker cp "$WORK/beh_$MODE-tree/etc/nftables.conf" "$S:/etc/nftables.conf" >/dev/null
    probe() { docker exec "$S" timeout 3 bash -c ">/dev/tcp/$TIP/$1" 2>/dev/null; }
    probe 6443 && probe 443 && probe 8200 || bad "(control) before the ruleset, the target does not answer on 6443/443/8200"
    if docker exec "$S" nft -f /etc/nftables.conf 2>/dev/null; then
      probe 6443 && probe 50000 && ok "$MODE ruleset loaded: 6443 and 50000 reach the cluster subnet" || bad "$MODE ruleset loaded: the cluster ports are cut"
      if [ "$MODE" = closed ]; then
        probe 80 && bad "closed: 80 still answers" || ok "closed: port 80 is dropped"
        probe 443 && bad "closed: 443 still answers" || ok "closed: port 443 is dropped"
        probe 8200 && bad "closed: 8200 still answers" || ok "closed: port 8200 is dropped"
      else
        probe 80 && probe 443 && probe 8200 && ok "(control) legacy: 80, 443 and 8200 still answer" || bad "legacy ruleset changed behaviour"
      fi
    else bad "the $MODE ruleset could not be loaded in the container (NET_ADMIN refused?)"; fi
    docker rm -f "$S" >/dev/null 2>&1
  done
  docker rm -f "$T" >/dev/null 2>&1
done

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
