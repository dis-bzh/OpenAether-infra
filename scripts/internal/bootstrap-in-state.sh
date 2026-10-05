#!/usr/bin/env bash
# Prints `true` when the state holds the Talos bootstrap, `false` when it does not.
# A state that cannot be READ is neither: the answer would be a guess, and `false`
# on a bootstrapped cluster zeroes the node counts and drops the talos_* resources
# (bootstrap, machine configs, kubeconfig) from the state. A first run has no state
# object yet: that is a real `false`. Run from the cluster dir, backend inited.
#
# A state holding the bootstrap, a machine config or the kubeconfig but NO machine secrets is refused too: the
# nodes still trust the PKI those secrets held, and any apply from it mints a new one (#66). Only the bootstrap
# makes the answer `true`.
set -uo pipefail
list="$(tofu state list -no-color 2>&1)"
if [ $? -ne 0 ]; then
  case "$list" in
    *"No state file was found"*) echo false; exit 0 ;;
  esac
  printf '✗ cannot read the state, so whether the cluster is bootstrapped is unknown:\n%s\n' "$list" >&2
  exit 1
fi
has() { grep -qF "$1" <<<"$list"; }
# `this`, or `unprotected` (tofu test): either one is the secrets.
if ! has 'module.talos.talos_machine_secrets.' \
   && { has 'module.talos.talos_machine_bootstrap' || has 'module.talos.talos_machine_configuration_apply' \
        || has 'module.talos.talos_cluster_kubeconfig'; }; then
  cat >&2 <<'MSG'
✗ the state holds Talos resources but no talos_machine_secrets (`task infra-down-plan` untracks
  them, and so does `tofu state rm`). The nodes still trust the PKI they held; an apply from this state
  would mint a new one they reject ("certificate signed by unknown authority"). Nothing was applied.
  Do not run cluster-up or infra-apply. Restore a state that still holds the secrets, or rebuild them from a node
  (infrastructure/opentofu/cluster/README.md, "Lost the Talos secrets"; #66), or finish the teardown.
MSG
  exit 1
fi
if has 'module.talos.talos_machine_bootstrap'; then echo true; else echo false; fi
