#!/usr/bin/env bash
# Which quarter of `task test-scripts` a harness belongs to.
#
# CI runs the harnesses on four runners at once (`task test-scripts SHARD=k/4`, the jobs `Script Tests (k/4)` of
# ci.yml) instead of one sequential loop of fifteen minutes. Four jobs, not four loops in one job: the harnesses bind
# fixed local ports (infra #431), so two of them cannot run side by side on one machine.
#
# The split is deterministic and has no state to keep in step:
#   - the heaviest harnesses are listed below with their shard, balanced on the durations of one CI run;
#   - every other harness goes to shard (cksum of its name) mod 4 + 1, so a NEW scripts/dev/test-*.sh needs no line
#     anywhere (infra #400) and still lands in exactly one shard.
# The harness list is the one `task test-scripts` runs: scripts/dev/test-*.sh minus exclude-from-test-scripts.txt.
# The preface of that task (check-jsonpath.sh and the check-required-checks.sh self-test) runs in shard 1 only.
#
# Rebalancing: the `task: [test-scripts] ./scripts/dev/<name>` lines of a CI log carry a timestamp each, so the time
# of a harness is the gap to the next line. Move a line of the table when one shard runs more than ~20 % longer than
# the others over several runs; one run is one sample.
#
# Usage:
#   script-shard.sh K/4       print the harnesses of shard K (1..4), one per line, in the order the task runs them
#   script-shard.sh --check   prove that every harness is in exactly one shard and that the table names real harnesses
# Exit 0 fine, 1 a table or a partition that is wrong, 2 usage.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

SHARDS=4
EXCL=scripts/dev/exclude-from-test-scripts.txt

# <harness> <shard>  # seconds in the CI push run of 2026-11-12 (one runner, harnesses only: shard 1 adds ~9 s of preface)
# Sized so that the four shards come to ~230 s each with the checksum default on everything not listed here.
TABLE='
test-cluster-up.sh              1   # 103
test-talos-tunnels.sh           4   #  75
test-dr-restore-plan.sh         2   #  61
test-wait-talos-port.sh         3   #  57
test-shrink-nodes.sh            4   #  55
test-talos-image.sh             2   #  47
test-pins-verify.sh             3   #  47
test-dead-references.sh         1   #  44
test-rolling-replace.sh         4   #  39
test-security-tests-checks.sh   2   #  35
test-egress-probe.sh            3   #  30
test-cluster-checks.sh          1   #  27
test-s3-isolation.sh            4   #  21
test-clea.sh                    1   #  17
test-cnpg-presync.sh            3   #  17
test-cluster-bootstrap-sync.sh  2   #  16
'

strip() { sed -E 's/[[:space:]]*#.*//; /^[[:space:]]*$/d'; }
usage() { echo "usage: ${0##*/} K/$SHARDS (K from 1 to $SHARDS) | --check" >&2; exit 2; }

# The harnesses `task test-scripts` runs: its glob minus the exclusion list, in its (alphabetical) order.
skip="$(strip <"$EXCL")" || { echo "✗ script-shard: cannot read $EXCL" >&2; exit 1; }
NAMES=()
for t in scripts/dev/test-*.sh; do
  t="${t#scripts/dev/}"
  grep -qxF "$t" <<<"$skip" || NAMES+=("$t")
done
[ "${#NAMES[@]}" -gt 0 ] || { echo "✗ script-shard: no scripts/dev/test-*.sh harness found" >&2; exit 1; }

# The table, read once. Every line must name a harness the task runs, once, with a shard in range: a stale name
# (renamed, deleted or excluded harness) would otherwise sit there balancing nothing.
declare -A LISTED=() IS_HARNESS=()
for n in "${NAMES[@]}"; do IS_HARNESS[$n]=1; done
bad=0
while read -r name shard extra; do
  if [ -n "$extra" ] || ! [[ "$shard" =~ ^[1-9][0-9]*$ ]] || [ "$shard" -gt "$SHARDS" ]; then
    echo "✗ script-shard: table line '$name $shard $extra': want '<harness> <shard 1..$SHARDS>'" >&2; bad=1; continue
  fi
  [ -n "${IS_HARNESS[$name]:-}" ] || { echo "✗ script-shard: the table names $name, which task test-scripts does not run" >&2; bad=1; continue; }
  [ -z "${LISTED[$name]:-}" ] || { echo "✗ script-shard: the table lists $name twice" >&2; bad=1; continue; }
  LISTED[$name]="$shard"
done < <(strip <<<"$TABLE")
[ "$bad" -eq 0 ] || exit 1

# The shard of every harness, worked out once: the table's word, else the checksum of the name.
declare -A OF=()
for n in "${NAMES[@]}"; do
  if [ -n "${LISTED[$n]:-}" ]; then OF[$n]="${LISTED[$n]}"; continue; fi
  sum="$(printf '%s' "$n" | cksum)"
  OF[$n]=$(( ${sum%% *} % SHARDS + 1 ))
done

pick() { # the harnesses of shard $1
  local n
  for n in "${NAMES[@]}"; do
    if [ "${OF[$n]}" = "$1" ]; then echo "$n"; fi
  done
}

check() {
  local k n bad=0 listed
  declare -A seen=() per=()
  for ((k = 1; k <= SHARDS; k++)); do
    per[$k]=0
    while IFS= read -r n; do
      seen[$n]=$(( ${seen[$n]:-0} + 1 ))
      per[$k]=$(( per[$k] + 1 ))
    done < <(pick "$k")
  done
  for n in "${NAMES[@]}"; do
    [ "${seen[$n]:-0}" -eq 1 ] || { echo "✗ script-shard: $n is in ${seen[$n]:-0} shards, not one" >&2; bad=1; }
  done
  for ((k = 1; k <= SHARDS; k++)); do
    [ "${per[$k]}" -gt 0 ] || { echo "✗ script-shard: shard $k/$SHARDS runs no harness" >&2; bad=1; }
    listed=0
    for n in "${!LISTED[@]}"; do [ "${LISTED[$n]}" = "$k" ] && listed=$((listed + 1)); done
    echo "shard $k/$SHARDS: ${per[$k]} harnesses ($listed from the table, $(( ${per[$k]} - listed )) by checksum)"
  done
  [ "$bad" -eq 0 ] || return 1
  echo "OK — ${#NAMES[@]} harnesses, each in exactly one of $SHARDS shards"
}

case "${1:-}" in
  --check) [ "$#" -eq 1 ] || usage; check ;;
  */"$SHARDS")
    k="${1%/*}"
    [ "$#" -eq 1 ] && [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -ge 1 ] && [ "$k" -le "$SHARDS" ] || usage
    pick "$k" ;;
  *) usage ;;
esac
