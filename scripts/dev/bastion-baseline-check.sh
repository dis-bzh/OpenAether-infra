#!/usr/bin/env bash
# ==============================================================================
# bastion-baseline-check.sh — validates the bastion cloud-init OFFLINE, before a paid VM boots it.
#
# A bad bastion cloud-init locks the operator out, and the only real test (a cloud VM) bills. This renders
# the real shared template with `tofu`, with and without bastion_baseline, and puts the exact bytes on the
# same Ubuntu releases the bastion runs (22.04 jammy, 24.04 noble) in Docker:
#
#   default   the render has none of the baseline (the full byte-for-byte hash is in test-cluster-checks.sh)
#   sshd      `sshd -t`; a real login; the key fingerprint in the log; -L through PermitOpen still carries
#             traffic and a port outside it is refused; unix-socket forwarding is refused only with the
#             baseline; a key in RevokedKeys is refused; a broken drop-in is removed by the runcmd guard
#   nftables  `nft -c -f`; on loaded rules in a container's OWN network namespace: port 22 answers the admin
#             source and not another one
#   others    sysctl names exist (read only), audit rules parse with libaudit, sudo goes to 4750 root:sudo,
#             umask, cloud-init schema (when cloud-init is installed)
#
# Nothing here writes to the host: containers have no --privileged, NET_ADMIN is held in the container's own
# network namespace, and every sysctl is only READ. What it cannot prove: that a cloud image boots with it,
# that auditd accepts the rules in a real kernel, that a provider's network keeps the admin source address.
#
# Usage: ./scripts/dev/bastion-baseline-check.sh [22.04 24.04]     (task bastion-baseline-check)
# Requires: docker, tofu, ssh-keygen, python3 + pyyaml. Run directly it skips (exit 0) without docker; the
# task refuses instead, since a skip would record a green receipt for a proof that never ran.
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
LABEL="oa-bastion-baseline-check-$$"
cleanup() { docker ps -aq --filter "label=$LABEL" | xargs -r docker rm -f >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

# --- render --------------------------------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -f "$WORK/id" -C oa-check-key
ssh-keygen -q -t ed25519 -N '' -f "$WORK/revoked" -C revoked-key
PUB="$(cat "$WORK/id.pub")"
mkdir -p "$WORK/render"
render() { # <name> <baseline object> <admin_ip list> — writes $WORK/<name>.yaml
  cat >"$WORK/render/main.tf" <<EOF
output "r" {
  value = templatefile("$TEMPLATE", {
    bastion_user = "bastion", ssh_keys = ["$PUB"], private_cidr = "10.0.0.0/24",
    extra_packages = [], extra_write_files = [], extra_runcmd = [],
    ssh_ca_public_key = "", ssh_ca_principals = "", baseline = $2, admin_ip = $3
  })
}
EOF
  tofu -chdir="$WORK/render" init -input=false >/dev/null 2>&1 &&
    tofu -chdir="$WORK/render" apply -auto-approve -input=false >/dev/null 2>&1 &&
    tofu -chdir="$WORK/render" output -raw r >"$WORK/$1.yaml"
}
OFFB='{ enabled = false, audit_logging = true, restrict_ssh_source = false, time_servers = [], revoked_keys = [] }'
ONB='{ enabled = true, audit_logging = true, restrict_ssh_source = false, time_servers = ["time.example.org"], revoked_keys = [] }'
render off "$OFFB" '[]' && render on "$ONB" '[]' || { echo "✗ could not render the template" >&2; exit 1; }

# Stage each render as a file tree (modes applied) plus its runcmd items, exactly what cloud-init would write.
stage() { # <name>
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
json.dump(doc["runcmd"], open(f"{work}/{name}-runcmd.json", "w"))
json.dump(doc, open(f"{work}/{name}.json", "w"))
PY
}
stage off; stage on

echo "=== the default render carries none of the baseline ==="
if ! grep -qE 'bastion-baseline|99-bastion-hardening.conf.*RevokedKeys|nft-drop|auditd|chrony|sysctl --system' "$WORK/off.yaml" &&
   [ ! -e "$WORK/off-tree/etc/sysctl.d" ] && [ ! -e "$WORK/off-tree/etc/audit" ] && grep -q 'netcat-openbsd' "$WORK/off.yaml"; then
  ok "baseline off: no sysctl, audit, journald, drop-in, nft log, chrony — and the old packages stay"
else bad "the default render contains baseline content"; fi
python3 -I - "$WORK" <<'PY' && ok "baseline on: the cloud-config is valid YAML with the same top-level keys" || bad "the on render changed the cloud-config structure"
import sys, yaml
a = yaml.safe_load(open(f"{sys.argv[1]}/off.yaml")); b = yaml.safe_load(open(f"{sys.argv[1]}/on.yaml"))
assert list(a) == list(b), (list(a), list(b))
assert "netcat-openbsd" not in b["packages"] and "tcpdump" not in b["packages"] and "auditd" in b["packages"]
PY
# The directives themselves, by name: a mutant that weakens one must not pass on behaviour that another setting
# already provides (PermitOpen alone already refuses unix-socket forwarding on OpenSSH 8.9+).
MISSING=""
for d in 'LogLevel VERBOSE' 'StrictModes yes' 'PermitUserEnvironment no' 'PermitEmptyPasswords no' 'AllowStreamLocalForwarding no' 'GatewayPorts no' 'RevokedKeys /etc/ssh/revoked_keys'; do
  grep -qx "$d" "$WORK/on-tree/etc/ssh/sshd_config.d/98-bastion-baseline.conf" || MISSING="$MISSING [$d]"
done
[ -z "$MISSING" ] && ok "the sshd baseline drop-in names every directive" || bad "missing from 98-bastion-baseline.conf:$MISSING"
if command -v cloud-init >/dev/null 2>&1; then
  if cloud-init schema -c "$WORK/on.yaml" 2>&1 | grep -q '^Valid schema'; then ok "cloud-init schema accepts the baseline render"
  else bad "cloud-init schema rejects the baseline render"; fi
else echo "  ~ cloud-init is not installed: schema not checked"; fi

# --- containers ---------------------------------------------------------------------------------------
build_image() { # <release>
  docker image inspect "oa-bastion-baseline-test:$1" >/dev/null 2>&1 && return 0
  docker build -q -t "oa-bastion-baseline-test:$1" --build-arg "REL=$1" - >/dev/null 2>&1 <<'DOCKERFILE'
ARG REL
FROM ubuntu:${REL}
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    openssh-server openssh-client nftables auditd sudo python3 procps iproute2 netbase >/dev/null && mkdir -p /run/sshd
DOCKERFILE
}

# The in-container script for the sshd checks. Prints "ok|msg" or "bad|msg" lines. $1 = on|off.
SSHD_CHECKS='
r() { printf "%s|%s\n" "$1" "$2"; }
SSH="ssh -i /root/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -l bastion"
# What a first boot does: the groups, the user, then the rendered files and the runcmd items that touch sshd.
groupadd bastion-admins; useradd -m -s /bin/bash -G bastion-admins bastion
( cd /stage && find . -type f ) | while read -r f; do install -D -o root -g root -m "$(stat -c %a "/stage/$f")" "/stage/$f" "/$f"; done
mkdir -p /etc/ssh/auth_principals
if [ "$1" = on ]; then
  chown root:root /etc/ssh/authorized_keys.d/bastion; chmod 0644 /etc/ssh/authorized_keys.d/bastion
else
  chown bastion:bastion /etc/ssh/authorized_keys.d/bastion
fi
if [ "$1" = on ]; then
  cp -p /etc/ssh/sshd_config /etc/ssh/sshd_config.pre-baseline && sed -i "s/^AcceptEnv/#AcceptEnv/" /etc/ssh/sshd_config
  grep -q "^AcceptEnv" /etc/ssh/sshd_config && r bad "AcceptEnv is still active after the sed" || r ok "AcceptEnv is commented out of the main sshd_config"
fi
sshd -t 2>/tmp/t.err && r ok "sshd -t accepts the rendered config" || { r bad "sshd -t rejects it: $(cat /tmp/t.err)"; exit 0; }
/usr/sbin/sshd -E /var/log/sshd.log; sleep 1
$SSH 127.0.0.1 true 2>/dev/null && r ok "key login works as the bastion user" || { r bad "key login FAILED"; exit 0; }
grep -q "Accepted publickey for bastion.*SHA256:" /var/log/sshd.log && r ok "the login line carries the key fingerprint" || r bad "no fingerprint in the login line"
# What LogLevel VERBOSE adds at INFO: the line number of the key in authorized_keys.d (maps a login to a key to a person)
# and the session start/close lines. The "Accepted publickey ... SHA256:" line above is already there at INFO.
if [ "$1" = on ]; then
  grep -q "Accepted key ED25519 SHA256:.* found at /etc/ssh/authorized_keys.d/bastion:1" /var/log/sshd.log && grep -q "Starting session" /var/log/sshd.log \
    && r ok "VERBOSE adds the authorized_keys line of the key and the session start/close" || r bad "no VERBOSE-only lines in the sshd log"
else
  grep -q "Accepted key" /var/log/sshd.log && r bad "(control) INFO already logs the key line: the VERBOSE check above would prove nothing" || r ok "(control) the default level does not log the key line"
fi
# 6443 is inside PermitOpen; 7000 is not.
python3 -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b\"tunnel-ok\")
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer((\"127.0.0.1\", 6443), H).serve_forever()" &
python3 -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b\"should-be-refused\")
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer((\"127.0.0.1\", 7000), H).serve_forever()" &
sleep 1
get() { python3 -c "import urllib.request,sys; print(urllib.request.urlopen(sys.argv[1], timeout=4).read().decode())" "$1" 2>/dev/null; }
$SSH -o ExitOnForwardFailure=yes -f -N -L 16443:127.0.0.1:6443 127.0.0.1 2>/dev/null
[ "$(get http://127.0.0.1:16443/)" = tunnel-ok ] && r ok "-L to 6443 (PermitOpen) carries traffic" || r bad "the 6443 tunnel does not carry traffic"
$SSH -f -N -L 17000:127.0.0.1:7000 127.0.0.1 2>/dev/null
[ "$(get http://127.0.0.1:17000/)" = should-be-refused ] && r bad "-L to 7000 (outside PermitOpen) carried traffic" || r ok "-L to a port outside PermitOpen is refused"
# Unix-socket forwarding: refused only with the baseline.
python3 -c "
import socket, os
p=\"/tmp/remote.sock\"
try: os.unlink(p)
except OSError: pass
s=socket.socket(socket.AF_UNIX); s.bind(p); os.chmod(p, 0o777); s.listen(4)
while True:
    c,_=s.accept(); c.sendall(b\"sock-ok\"); c.close()" &
sleep 1
rm -f /tmp/local.sock
$SSH -f -N -L /tmp/local.sock:/tmp/remote.sock 127.0.0.1 2>/dev/null
sleep 1
GOT="$(python3 -c "
import socket
s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(\"/tmp/local.sock\"); print(s.recv(16).decode())" 2>/dev/null)"
# With PermitOpen set, OpenSSH 8.9+ already refuses unix-socket forwarding (measured: the server logs "request to
# connect to path ..., but the request was denied"); the explicit directive is defence in depth. Both facts are
# asserted: the combined config refuses it, and the directive alone does what it says on a config WITHOUT PermitOpen.
[ "$GOT" = sock-ok ] && r bad "unix-socket forwarding works under the rendered config" || r ok "unix-socket forwarding is refused under the rendered config"
for MODE2 in plain denied; do
  EXTRA=""; [ "$MODE2" = denied ] && EXTRA="AllowStreamLocalForwarding no"
  PORT=$([ "$MODE2" = plain ] && echo 2222 || echo 2223)
  printf "Port %s\nHostKey /etc/ssh/ssh_host_ed25519_key\nAuthorizedKeysFile /etc/ssh/authorized_keys.d/%%u\nAllowTcpForwarding yes\nUsePAM yes\nPidFile /tmp/sshd-%s.pid\n%s\n" "$PORT" "$MODE2" "$EXTRA" > /tmp/min-$MODE2.conf
  /usr/sbin/sshd -f /tmp/min-$MODE2.conf -E /tmp/min-$MODE2.log; sleep 1
  rm -f /tmp/min-$MODE2.sock
  $SSH -p "$PORT" -f -N -L /tmp/min-$MODE2.sock:/tmp/remote.sock 127.0.0.1 2>/dev/null; sleep 1
  GOT2="$(python3 -c "
import socket
s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(\"/tmp/min-$MODE2.sock\"); print(s.recv(16).decode())" 2>/dev/null)"
  if [ "$MODE2" = plain ]; then
    [ "$GOT2" = sock-ok ] && r ok "(control) without PermitOpen and without the directive, unix-socket forwarding works" || r bad "(control) the minimal config does not forward a unix socket either: the next check proves nothing"
  else
    [ "$GOT2" = sock-ok ] && r bad "AllowStreamLocalForwarding no did not stop unix-socket forwarding" || r ok "AllowStreamLocalForwarding no stops unix-socket forwarding by itself"
  fi
done
if [ "$1" = on ]; then
  # RevokedKeys: the file is read at every authentication, no restart needed.
  cat /stage-revoked.pub >> /etc/ssh/revoked_keys
  $SSH 127.0.0.1 true 2>/dev/null && r ok "an unrelated revoked key does not lock the operator out" || r bad "revoking ANOTHER key locked the operator out"
  cat /root/id.pub >> /etc/ssh/revoked_keys
  $SSH 127.0.0.1 true 2>/dev/null && r bad "a key listed in revoked_keys still logs in" || r ok "a key listed in revoked_keys is refused"
  : > /etc/ssh/revoked_keys
  $SSH 127.0.0.1 true 2>/dev/null && r ok "an emptied revoked_keys lets the key back in" || r bad "login did not recover after emptying revoked_keys"
  # The runcmd guard: a broken baseline drop-in is removed, a good one stays.
  cp /etc/ssh/sshd_config.d/98-bastion-baseline.conf /tmp/98.good
  echo "NoSuchDirective yes" >> /etc/ssh/sshd_config.d/98-bastion-baseline.conf
  sh -c "$GUARD"
  [ ! -e /etc/ssh/sshd_config.d/98-bastion-baseline.conf ] && sshd -t && r ok "a broken drop-in is removed by the guard and sshd -t is green again" || r bad "the guard left a broken drop-in"
  cp /tmp/98.good /etc/ssh/sshd_config.d/98-bastion-baseline.conf
  sh -c "$GUARD"
  [ -e /etc/ssh/sshd_config.d/98-bastion-baseline.conf ] && r ok "a good drop-in survives the guard" || r bad "the guard removed a good drop-in"
fi
'

for REL in "${RELEASES[@]}"; do
  echo
  echo "=== Ubuntu $REL ==="
  if ! build_image "$REL"; then bad "could not build the test image for $REL (network?)"; continue; fi
  IMG="oa-bastion-baseline-test:$REL"

  GUARD="$(python3 -I - "$WORK" <<'PY'
import json, sys
items = json.load(open(f"{sys.argv[1]}/on-runcmd.json"))
print(next(i for i in items if isinstance(i, str) and "falling back to the proven config" in i))
PY
)"
  for MODE in off on; do
    C="oa-bbc-$$-$MODE-${REL//./}"
    docker run -d --name "$C" --label "$LABEL" "$IMG" sleep infinity >/dev/null
    docker cp "$WORK/$MODE-tree/." "$C:/stage" >/dev/null
    docker cp "$WORK/id" "$C:/root/id" >/dev/null; docker cp "$WORK/id.pub" "$C:/root/id.pub" >/dev/null
    docker cp "$WORK/revoked.pub" "$C:/stage-revoked.pub" >/dev/null
    docker exec "$C" chmod 600 /root/id
    OUT="$(docker exec -e GUARD="$GUARD" "$C" bash -c "$SSHD_CHECKS" bash "$MODE" 2>&1)"
    echo "  -- baseline $MODE"
    while IFS='|' read -r verdict msg; do
      case "$verdict" in ok) ok "$msg" ;; bad) bad "$msg" ;; "") ;; *) echo "     $verdict${msg:+|$msg}" ;; esac
    done <<<"$OUT"
    docker rm -f "$C" >/dev/null 2>&1
  done

  echo "  -- nftables, sysctl, audit rules, sudo, umask"
  # nft -c on both renders (a deliberately broken file must fail, or -c proves nothing).
  for MODE in off on; do
    if docker run --rm --cap-add NET_ADMIN -v "$WORK/$MODE-tree/etc/nftables.conf:/n.nft:ro" "$IMG" nft -c -f /n.nft 2>/dev/null; then ok "nft -c accepts the $MODE ruleset"
    else bad "nft -c rejects the $MODE ruleset"; fi
  done
  printf 'table inet filter { chain input { tcp dport 22 acept } }\n' >"$WORK/broken.nft"
  docker run --rm --cap-add NET_ADMIN -v "$WORK/broken.nft:/n.nft:ro" "$IMG" nft -c -f /n.nft >/dev/null 2>&1 \
    && bad "nft -c accepted a broken file: the check above proves nothing" || ok "nft -c refuses a broken file (the check discriminates)"

  # Behaviour: the baseline ruleset, loaded in a container's own network namespace, accepts port 22 from the
  # admin source and from no other.
  S="oa-bbc-$$-srv-${REL//./}"; A="oa-bbc-$$-adm-${REL//./}"; B="oa-bbc-$$-oth-${REL//./}"
  docker run -d --name "$A" --label "$LABEL" "$IMG" sleep infinity >/dev/null
  docker run -d --name "$B" --label "$LABEL" "$IMG" sleep infinity >/dev/null
  AIP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$A")"
  render nftsrc '{ enabled = true, audit_logging = true, restrict_ssh_source = true, time_servers = [], revoked_keys = [] }' "[\"$AIP/32\"]" && stage nftsrc
  docker run -d --name "$S" --label "$LABEL" --cap-add NET_ADMIN "$IMG" sleep infinity >/dev/null
  docker cp "$WORK/nftsrc-tree/etc/nftables.conf" "$S:/etc/nftables.conf" >/dev/null
  SIP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$S")"
  docker exec -d "$S" python3 -m http.server 22 --bind 0.0.0.0 >/dev/null 2>&1
  sleep 1
  probe() { docker exec "$1" timeout 4 bash -c ">/dev/tcp/$SIP/22" 2>/dev/null; }
  probe "$A" && ok "(control) port 22 answers before the ruleset is loaded" || bad "the test listener is not reachable even before the ruleset"
  if docker exec "$S" nft -f /etc/nftables.conf 2>/dev/null; then
    probe "$A" && ok "ruleset loaded: port 22 answers the admin source ($AIP)" || bad "the admin source is locked out by the ruleset"
    probe "$B" && bad "ruleset loaded: port 22 still answers a source outside admin_ip" || ok "ruleset loaded: port 22 does not answer another source"
    docker exec "$S" nft list chain inet filter input 2>/dev/null | grep -q 'nft-drop-in' && ok "the final input rule logs with the nft-drop-in prefix" || bad "no log rule at the end of the input chain"
  else bad "the ruleset could not be loaded in the container (NET_ADMIN refused?)"; fi
  docker rm -f "$S" "$A" "$B" >/dev/null 2>&1

  # sysctl: every key must exist in a kernel (READ only; nothing is written). net.core.* is not visible from a
  # container's network namespace, so the host's /proc/sys is asked, once.
  if [ -z "${SYSCTL_DONE:-}" ]; then
    SYSCTL_DONE=1
    KEYS="$(sed -nE 's/^[[:space:]]*([a-z0-9_.]+)[[:space:]]*=.*/\1/p' "$WORK/on-tree/etc/sysctl.d/99-bastion-hardening.conf")"
    MISSING=""; for k in $KEYS; do [ -e "/proc/sys/${k//.//}" ] || MISSING="$MISSING $k"; done
    [ -z "$MISSING" ] && ok "every sysctl key exists in a kernel ($(wc -w <<<"$KEYS") keys, host /proc/sys, read only)" || bad "sysctl keys not found:$MISSING"
  fi

  # audit rules: libaudit's own parser (no kernel, no capability).
  if docker run --rm -v "$WORK/on-tree/etc/audit/rules.d/50-bastion.rules:/r.rules:ro" -v "$ROOT/scripts/dev/audit-rules-parse.py:/p.py:ro" "$IMG" python3 -I /p.py /r.rules; then ok "libaudit parses every audit rule"
  else bad "libaudit rejects an audit rule"; fi

  # sudo: the runcmd item, run for real.
  SUDOCMD="$(python3 -I - "$WORK" <<'PY'
import json, sys
print(next(i for i in json.load(open(f"{sys.argv[1]}/on-runcmd.json")) if isinstance(i, str) and "dpkg-statoverride --list" in i))
PY
)"
  GOT="$(docker run --rm -e C="$SUDOCMD" "$IMG" bash -c 'sh -c "$C"; stat -c "%a %U:%G" /usr/bin/sudo')"
  [ "$GOT" = "4750 root:sudo" ] && ok "dpkg-statoverride leaves sudo at 4750 root:sudo" || bad "sudo is '$GOT', expected '4750 root:sudo'"
  GOT="$(docker run --rm -v "$WORK/on-tree/etc/profile.d/umask.sh:/u.sh:ro" "$IMG" sh -c '. /u.sh; umask')"
  [ "$GOT" = 0077 ] && ok "the profile.d snippet sets umask 0077" || bad "umask is $GOT"
done

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
