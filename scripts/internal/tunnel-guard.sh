#!/usr/bin/env bash
# The Talos tunnels must answer before a plan or an apply of a bootstrapped state: every module.talos
# resource speaks to the Talos API through them, so with them shut the run waits 15 minutes per resource.
# `ensure` rebuilds what is broken. Usage: tunnel-guard.sh <ssh-key>   (cwd: the cluster dir)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${OA_SKIP_TUNNEL_GUARD:-}" = 1 ] && exit 0
SSH_KEY="${1:?usage: tunnel-guard.sh <ssh-key>}" "$HERE/../bootstrap/talos-tunnels.sh" ensure . && exit 0
# A changed admin_ip is the one case where the apply IS the repair, and the tunnels cannot exist until it lands.
cat >&2 <<'MSG'
✗ the Talos tunnels cannot be rebuilt, so nothing was planned or applied.
  If your public IP changed, the bastion no longer lets this machine in and this apply is the fix: put the
  new address in admin_ip and run it with the check off and the health read skipped, e.g.
    OA_SKIP_TUNNEL_GUARD=1 TF_VAR_skip_health_check=true task infra-apply PROVIDER=… APPROVE=auto
  (docs/admin-access.md). Otherwise check the key, the bastion and its routing, then re-run.
MSG
exit 1
