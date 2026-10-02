#!/usr/bin/env bash
# Prints `true` when the state holds the Talos bootstrap, `false` when it does not.
# A state that cannot be READ is neither: the answer would be a guess, and `false`
# on a bootstrapped cluster zeroes the node counts and drops the talos_* resources
# (bootstrap, machine configs, kubeconfig) from the state. A first run has no state
# object yet: that is a real `false`. Run from the cluster dir, backend inited.
set -uo pipefail
list="$(tofu state list -no-color 2>&1)"
if [ $? -ne 0 ]; then
  case "$list" in
    *"No state file was found"*) echo false; exit 0 ;;
  esac
  printf '✗ cannot read the state, so whether the cluster is bootstrapped is unknown:\n%s\n' "$list" >&2
  exit 1
fi
if grep -q 'module.talos.talos_machine_bootstrap' <<<"$list"; then echo true; else echo false; fi
