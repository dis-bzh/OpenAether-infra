#!/usr/bin/env bash
# Wait until the Talos API ANSWERS on the given endpoint.
# Usage: ENDPOINT=<host[:port]> [NODE=<ip>] [MAX_WAIT_SECONDS=900] ./wait-talos-port.sh
#   [RECOVER_PROVIDER=ovh RECOVER_NAME=<instance> RECOVER_AFTER=300 RECOVER_CMD=<path of node-provider.py>]
#
# Two ways to get this wrong, both met on 2026-08-12/13:
#
#  1. A bare TCP connect. On cloud the endpoint is an SSH tunnel on 127.0.0.1 and
#     `ssh -L` accepts locally whatever the far end is doing, so it returned
#     "reachable" in 4ms against a node that was not running. Everything
#     downstream then fired into the void: the machine config applied in 0s to
#     nobody and the health gate waited 600s for a kubelet nobody had configured.
#
#  2. `talosctl version`. It prints a "Server:" block with a Tag and exits 0 even
#     when nothing answers, so neither its status nor its output separates a live
#     node from a closed port. Replacing (1) with it turned the guard into one
#     that could never succeed and cost a full deployment.
#
# What does separate them is the transport error of a real API call. A node in
# maintenance mode answers the TLS handshake with a self-signed certificate —
# x509 error, but an ANSWER. A dead endpoint refuses the connection or times out.
# A configured node answers properly. So: anything but a transport failure means
# the API is up and will take a config.
set -euo pipefail

HOST="${ENDPOINT%%:*}"
if [[ "$HOST" == "$ENDPOINT" ]]; then
  PORT=50000
else
  PORT="${ENDPOINT##*:}"
fi
NODE="${NODE:-$HOST}"

# Bounded, not infinite: a node that never boots (bad image, stuck cloud-init,
# wrong security group...) must fail loudly within the apply's own 15m
# timeout, not hang the whole `tofu apply`/CI job indefinitely.
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ELAPSED=0

#  4. An instance the provider calls ACTIVE whose Talos never answers (OVH, infra #371, lab 27 part B: 2 of 12 creations, +5 to
#     +11 minutes until `node-provider.py hard-reboot` released them in 28-30 s). With RECOVER_AFTER seconds set (OVH only, by the
#     module), the guard asks the provider for that hard reboot itself, at most RECOVER_MAX times, RECOVER_AFTER seconds apart.
#     The reboot of a node in maintenance mode loses nothing, and node-provider.py sends it only to a machine created less than
#     RECOVER_YOUNGER seconds ago: this guard also runs when a tunnel is down on a cluster that has been serving for days, and
#     it must never reboot those. A refusal or a failure is said and the wait goes on; it is never fatal on its own.
RECOVER_AFTER="${RECOVER_AFTER:-0}"
RECOVER_MAX="${RECOVER_MAX:-2}"
RECOVER_YOUNGER="${RECOVER_YOUNGER:-3600}"
RECOVER_PROVIDER="${RECOVER_PROVIDER:-}"
RECOVER_NAME="${RECOVER_NAME:-}"
RECOVER_CMD="${RECOVER_CMD:-}"
recovered=0
next_recover="$RECOVER_AFTER"

recover() {
  recovered=$((recovered + 1)); next_recover=$((ELAPSED + RECOVER_AFTER))
  echo "  ${ELAPSED}s without an answer: asking ${RECOVER_PROVIDER} for a hard reboot of ${RECOVER_NAME} (${recovered}/${RECOVER_MAX}, infra #371)"
  local out
  if out="$("$RECOVER_CMD" hard-reboot "$RECOVER_PROVIDER" --name "$RECOVER_NAME" --ip "$NODE" --younger-than "$RECOVER_YOUNGER" 2>&1)"; then
    echo "  hard reboot requested: ${out}"
  else
    echo "  hard reboot NOT done (the wait goes on): ${out}"
  fi
}

#  3. `talosctl` WITHOUT A TALOSCONFIG. The local-exec passes ENDPOINT and NODE
#     and nothing else, so talosctl fails with "failed to resolve configuration
#     context: talos config file is empty" — never opening a socket. That string
#     is not a transport error, so the probe below read it as "the API answered"
#     and returned true on its first attempt, every time, on every provider.
#     Measured 2026-08-18 on Outscale: the guard passed in 0s, the six config
#     applies then spent 15 minutes each dialling tunnels that were not there and
#     died on "connect: connection refused". The guard existed precisely to
#     prevent that and had never once run.
#
# So the probe asks two questions that need no configuration at all:
#   a) is anything LISTENING locally — `connection refused` means the tunnel
#      itself is gone, which no amount of node readiness will fix;
#   b) does the far end complete a TLS handshake — apid answers with a
#      certificate even in maintenance mode, so a handshake means a live Talos,
#      while an `ssh -L` whose far end is dead accepts and then closes.
# Together they separate the three states the earlier versions confused.

probe() {
  # (a) local listener — catches a dead or never-opened tunnel.
  timeout 5 bash -c ">/dev/tcp/${HOST}/${PORT}" 2>/dev/null || return 1
  # (b) TLS handshake — catches a live tunnel with nothing behind it.
  local out
  out="$(timeout 10 openssl s_client -connect "${HOST}:${PORT}" -brief </dev/null 2>&1)" || true
  grep -qiE 'CONNECTION ESTABLISHED|Peer certificate|Protocol version' <<<"$out"
}
WHAT="Talos API (TCP + TLS handshake)"

command -v openssl >/dev/null 2>&1 || {
  echo "✗ openssl is required to tell a live Talos from an empty tunnel — install it." >&2
  exit 1
}

echo "Waiting for ${WHAT} on ${ENDPOINT} (node ${NODE}, up to ${MAX_WAIT_SECONDS}s)..."
until probe; do
  if [[ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]]; then
    echo "✗ ${ENDPOINT} still not answering after ${MAX_WAIT_SECONDS}s — giving up." >&2
    exit 1
  fi
  if [[ "$RECOVER_AFTER" -gt 0 && -n "$RECOVER_PROVIDER" && -n "$RECOVER_NAME" && -n "$RECOVER_CMD" \
        && "$recovered" -lt "$RECOVER_MAX" && "$ELAPSED" -ge "$next_recover" ]]; then
    recover
  fi
  echo "  not ready, retrying in ${POLL_SECONDS}s... (${ELAPSED}/${MAX_WAIT_SECONDS}s)"
  sleep "$POLL_SECONDS"
  ELAPSED=$((ELAPSED + POLL_SECONDS))
done
echo "Talos API answering on ${ENDPOINT}"
