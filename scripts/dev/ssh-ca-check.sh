#!/usr/bin/env bash
# ==============================================================================
# ssh-ca-check.sh — proves the bastion cloud-init template actually enables
# SSH-CA once ssh_ca_public_key / ssh_ca_principals are set (#81: both were
# hardcoded to an empty file/dir, so no caller could ever turn it on).
#
# Local-docker proof (rung "local-docker"): renders the real .tftpl with `tofu`
# (the same technique used to investigate #81 — read what the template
# actually emits, not what the .tftpl source implies) and drops the exact
# write_files bytes onto a real sshd in Docker. No cloud account, no VM boot.
#
# Asserts the issue's own closing bar:
#   0. Defaults ("") still render an EMPTY trust file and NO principals file
#      at all — today's inert behaviour, byte for byte.
#   1. A CA-signed certificate authenticates.
#   2. The SAME bare key, presented without its certificate, is REFUSED.
#   3. `ssh -o ExitOnForwardFailure=yes -L` through PermitOpen actually
#      carries traffic.
#
# ⚠️ Signs with `-O permit-port-forwarding` explicitly: ssh-keygen's default
# extension set already includes it, but a narrowed one that forgets it still
# authenticates and then refuses every `-L` — the exact 2026-08-18 failure
# this issue cites (talos-tunnels.sh reporting 0/6 against a healthy bastion).
#
# Usage: ./scripts/dev/ssh-ca-check.sh
# Requires: docker, tofu, ssh, ssh-keygen, python3+pyyaml. Run directly it skips
# (exit 0) without docker; `task ssh-ca-check` refuses instead, since a skip
# would record a green receipt for a proof that never ran.
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$ROOT/infrastructure/opentofu/modules/providers/_shared/bastion-cloud-init.yaml.tftpl"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

command -v docker >/dev/null 2>&1 || { echo "SKIP — docker not available, cannot run the local sshd proof"; exit 0; }
for c in tofu ssh ssh-keygen python3; do
  command -v "$c" >/dev/null 2>&1 || { echo "✗ $c not found — required for this proof" >&2; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "✗ python3 pyyaml module not found — required for this proof" >&2; exit 1; }

WORK="$(mktemp -d)"
CONTAINER="ssh-ca-check-$$"
IMAGE="ubuntu:24.04"
BASTION_USER="bastion"
PRINCIPAL="ssh-ca-check-admin"

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

echo "=== 0. Rendering the template — both the default (\"\") and SSH-CA-on ==="

# CA + a user key signed for $PRINCIPAL, WITH permit-port-forwarding explicit
# (see the ⚠️ above — the default extension set covers it, but don't rely on
# an implicit default for the one thing #81's own regression was about).
ssh-keygen -q -t ed25519 -N '' -f "$WORK/ca" -C ca
ssh-keygen -q -t ed25519 -N '' -f "$WORK/user" -C "$PRINCIPAL"
ssh-keygen -q -s "$WORK/ca" -I ssh-ca-check -n "$PRINCIPAL" -O permit-port-forwarding \
  -V always:forever "$WORK/user.pub"
CA_PUBKEY="$(cat "$WORK/ca.pub")"

render() { # <ssh_ca_public_key> <ssh_ca_principals> <out-file>
  cat >"$WORK/render.tf" <<EOF
output "rendered" {
  value = templatefile("$TEMPLATE", {
    bastion_user      = "$BASTION_USER"
    ssh_keys          = []
    private_cidr      = "10.0.0.0/24"
    extra_packages    = []
    extra_write_files = []
    extra_runcmd      = []
    ssh_ca_public_key = "$1"
    ssh_ca_principals = "$2"
  })
}
EOF
  tofu -chdir="$WORK" init -input=false >/dev/null 2>&1 &&
    tofu -chdir="$WORK" apply -auto-approve -input=false >/dev/null 2>&1 &&
    tofu -chdir="$WORK" output -raw rendered >"$3"
}

render "" "" "$WORK/off.yaml" ||
  { echo "✗ could not render the template with default vars" >&2; exit 1; }
render "$CA_PUBKEY" "$PRINCIPAL" "$WORK/on.yaml" ||
  { echo "✗ could not render the template with SSH-CA vars set" >&2; exit 1; }

# Pull out exactly what a provider's bastion.tf would ship to disk — no
# cloud-init interpreter involved, the proof is the literal template bytes —
# and stage the "on" render's files for the container step below.
CHECKS="$(python3 - "$WORK" "$BASTION_USER" <<'PY'
import sys, yaml

work, user = sys.argv[1], sys.argv[2]

def write_files(name):
    with open(f"{work}/{name}.yaml") as f:
        doc = yaml.safe_load(f)
    return {wf["path"]: wf["content"] for wf in doc["write_files"]}

off, on = write_files("off"), write_files("on")
principals_path = f"/etc/ssh/auth_principals/{user}"

def check(cond, msg):
    print(("ok" if cond else "bad") + "|" + msg)

check(off["/etc/ssh/trusted_user_ca.pub"] == "",
      "default renders an empty trusted_user_ca.pub (unchanged)")
check(principals_path not in off,
      "default renders NO auth_principals file at all (unchanged)")
check(on["/etc/ssh/trusted_user_ca.pub"].strip() != "",
      "ssh_ca_public_key set -> trusted_user_ca.pub carries it")
check(principals_path in on,
      "ssh_ca_principals set -> auth_principals file is rendered")

# .get(..., "") rather than a bare index: a regression that drops one of
# these paths must fail on the checks above, not crash here before they are
# even reported.
with open(f"{work}/sshd-hardening.conf", "w") as f:
    f.write(on.get("/etc/ssh/sshd_config.d/99-bastion-hardening.conf", ""))
with open(f"{work}/trusted_user_ca.pub", "w") as f:
    f.write(on.get("/etc/ssh/trusted_user_ca.pub", ""))
with open(f"{work}/auth_principals", "w") as f:
    f.write(on.get(principals_path, ""))
PY
)"
[ -n "$CHECKS" ] || { echo "✗ template rendering/extraction produced nothing — parser broke silently" >&2; exit 1; }

while IFS='|' read -r verdict msg; do
  [ "$verdict" = "ok" ] && ok "$msg" || bad "$msg"
done <<<"$CHECKS"

echo
echo "=== 1-3. Materializing the rendered files onto a real sshd (Docker) ==="

docker run -d --name "$CONTAINER" -p 127.0.0.1::22 "$IMAGE" sleep infinity >/dev/null

docker exec -e DEBIAN_FRONTEND=noninteractive "$CONTAINER" bash -c "
  set -e
  apt-get update -qq
  apt-get install -y -qq openssh-server openssh-client netcat-openbsd
  groupadd bastion-admins
  useradd -m -s /bin/bash -G bastion-admins -c bastion $BASTION_USER
  mkdir -p /etc/ssh/authorized_keys.d /etc/ssh/auth_principals /run/sshd
  chmod 755 /etc/ssh/authorized_keys.d /etc/ssh/auth_principals
  : > /etc/ssh/authorized_keys.d/$BASTION_USER
  chmod 0600 /etc/ssh/authorized_keys.d/$BASTION_USER
" >/dev/null
SETUP_RC=$?

if [ "$SETUP_RC" -ne 0 ]; then
  bad "container setup (packages/user/dirs) failed — cannot run the live sshd checks"
else
  docker cp "$WORK/sshd-hardening.conf" "$CONTAINER:/etc/ssh/sshd_config.d/99-bastion-hardening.conf" >/dev/null
  docker cp "$WORK/trusted_user_ca.pub" "$CONTAINER:/etc/ssh/trusted_user_ca.pub" >/dev/null
  docker cp "$WORK/auth_principals" "$CONTAINER:/etc/ssh/auth_principals/$BASTION_USER" >/dev/null
  docker exec "$CONTAINER" bash -c "
    chmod 0600 /etc/ssh/sshd_config.d/99-bastion-hardening.conf
    chmod 0644 /etc/ssh/trusted_user_ca.pub /etc/ssh/auth_principals/$BASTION_USER
  "

  if ! docker exec "$CONTAINER" sshd -t; then
    bad "rendered sshd config is rejected by sshd -t"
  else
    ok "rendered sshd config is accepted by sshd -t"
    docker exec "$CONTAINER" /usr/sbin/sshd
    # Synthetic cluster-port listener: PermitOpen allows *:6443, so this
    # stands in for what a real Talos/K8s endpoint would be at that port.
    docker exec -d "$CONTAINER" bash -c 'nc -lk 127.0.0.1 6443 > /tmp/nc-received.txt'

    HOST_PORT=""
    for i in $(seq 1 20); do
      HOST_PORT="$(docker port "$CONTAINER" 22/tcp 2>/dev/null | head -1 | cut -d: -f2)"
      if [ -n "$HOST_PORT" ] && ssh -i "$WORK/user" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o BatchMode=yes -o ConnectTimeout=2 -p "$HOST_PORT" "$BASTION_USER@127.0.0.1" true 2>/dev/null; then
        break
      fi
      sleep 1
    done

    SSH="ssh -i $WORK/user -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -p $HOST_PORT ${BASTION_USER}@127.0.0.1"

    # --- 1. Cert authenticates ---
    if $SSH echo cert-ok 2>/dev/null | grep -q cert-ok; then
      ok "CA-signed certificate authenticates"
    else
      bad "CA-signed certificate did NOT authenticate"
    fi

    # --- 2. Same key, no cert -> refused ---
    mv "$WORK/user-cert.pub" "$WORK/user-cert.pub.hidden"
    if $SSH echo should-not-print 2>/dev/null | grep -q should-not-print; then
      bad "the bare key (no certificate) was accepted — should be refused"
    else
      ok "the same key WITHOUT its certificate is refused"
    fi
    mv "$WORK/user-cert.pub.hidden" "$WORK/user-cert.pub"

    # --- 3. -L with ExitOnForwardFailure carries real traffic ---
    if $SSH -o ExitOnForwardFailure=yes -N -f -L 16443:127.0.0.1:6443 2>/dev/null; then
      MARKER="ssh-ca-check-$$"
      printf '%s\n' "$MARKER" | timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/16443; cat >&3" 2>/dev/null
      sleep 1
      if docker exec "$CONTAINER" grep -q "$MARKER" /tmp/nc-received.txt 2>/dev/null; then
        ok "ssh -o ExitOnForwardFailure=yes -L succeeds and carries traffic through PermitOpen"
      else
        bad "the tunnel came up but no traffic reached the far side"
      fi
      pkill -f "16443:127.0.0.1:6443" >/dev/null 2>&1 || true
    else
      bad "ssh -o ExitOnForwardFailure=yes -L failed to set up"
    fi
  fi
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
