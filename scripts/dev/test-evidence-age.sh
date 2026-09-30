#!/usr/bin/env bash
# Unit tests for #121: check-evidence-age.sh against throwaway fixtures (a
# variables.tf and a status.md) with the clock injected, so no case depends on
# today's date or on the real pin. The real tree is asserted to PARSE only:
# whether its measurements are stale is a verdict for `task evidence-check`,
# and a verdict that turns this harness red would turn CI red with no commit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/dev/check-evidence-age.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# Without this, every case below reads a missing gate as "rc 127" and some of
# them (the `-ne 0` ones) would pass on it.
[ -x "$GATE" ] || { echo "✗ $GATE is missing or not executable — this harness would grade nothing" >&2; exit 1; }

CL="$TMP/cluster"
ST="$TMP/status.md"

# No `renovate:` anchor in the fixture: Cléa reads one as a version Renovate should bump.
cluster() { # <talos pin> <kubernetes pin>: a variables.tf shaped like the real one
  rm -rf "$CL"; mkdir -p "$CL/envs"
  cat >"$CL/variables.tf" <<EOF
variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default = "$1"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default = "$2"
}
EOF
}
# Rows on stdin, under a header whose column order is not the real page's:
# columns are found by name, never by position.
status() { { printf '# fixture\n\nprose | with a pipe\n\n| | measured | k8s | `Talos` |\n|---|---|---|---|\n'; cat; } >"$ST"; }
# rc in $rc, output in $out. OA_EVIDENCE_TODAY is the clock, a case sets TODAY to move it.
gate() { out="$(OA_EVIDENCE_TODAY="${TODAY:-2026-09-30}" "$GATE" "$@" --status "$ST" --cluster-dir "$CL" 2>&1)"; rc=$?; }
stale_lines() { grep '^✗' <<<"$out"; }
expect() { # <name> <want rc>
  [ "$rc" -eq "$2" ] && ok "$1 (rc=$rc)" || bad "$1 — want rc=$2, got rc=$rc: $out"
}

GREEN='| Scaleway, re-run | 2026-08-20 | unchanged at 1.36.3 | ✅ 6/6 nodes 1.13.8→1.13.9 |'

echo "=== a current measurement passes ==="
cluster v1.13.9 v1.36.3
status <<<"$GREEN"
gate
expect "measured at the pin, 41 days ago" 0
grep -q '^✓ scaleway' <<<"$out" && ok "the provider is the first word of the first cell, lowercased" || bad "no '✓ scaleway' line: $out"

echo
echo "=== a pin that moved past the measurement is stale, and the line says which ==="
cluster v1.13.10 v1.36.3
gate
expect "Talos moved" 1
stale_lines | grep -q 'scaleway.*talos.*v1\.13\.9.*v1\.13\.10' && ok "names the measured and the pinned Talos" || bad "Talos pair not named: $out"
cluster v1.13.9 v1.36.4
gate
expect "Kubernetes moved" 1
stale_lines | grep -q 'kubernetes' && ! stale_lines | grep -qi 'talos' && ok "names Kubernetes and not Talos" || bad "wrong component named: $out"

echo
echo "=== the age limit: equal passes, one day more does not ==="
cluster v1.13.9 v1.36.3
TODAY=2026-10-04 gate; expect "45 days old" 0
TODAY=2026-10-05 gate; expect "46 days old" 1
grep -q '46 days' <<<"$out" && ok "the age is in the output" || bad "no '46 days': $out"
OA_EVIDENCE_MAX_AGE_DAYS=10 TODAY=2026-09-01 gate; expect "a tighter OA_EVIDENCE_MAX_AGE_DAYS=10 at 12 days" 1

echo
echo "=== the newest row per provider is judged, by date and not by position ==="
status <<<'| Scaleway | 2026-08-01 | 1.36.1→1.36.2 | 1.13.6→1.13.7 |
| Scaleway, re-run | 2026-08-20 | 1.36.3 | 1.13.8→1.13.9 |'
gate; expect "an old stale row BEFORE the current one" 0
status <<<'| Scaleway, re-run | 2026-08-20 | 1.36.3 | 1.13.8→1.13.9 |
| Scaleway | 2026-08-01 | 1.36.1→1.36.2 | 1.13.6→1.13.7 |'
gate; expect "an old stale row AFTER the current one" 0
status <<<'| Scaleway | 2026-08-25 | 1.36.3 | 1.13.7→1.13.8 |
| Scaleway | 2026-08-01 | 1.36.3 | 1.13.8→1.13.9 |'
gate; expect "a newer stale row first, an older current one after" 1
status <<<'| Scaleway | 2026-08-20 | 1.36.3 | 1.13.8→1.13.9 |
| Scaleway, re-run | 2026-08-20 | 1.36.3 | 1.13.7→1.13.8 |'
gate; expect "two rows on one day: the later one is judged, here stale" 1
status <<<'| Scaleway | 2026-08-20 | 1.36.3 | 1.13.7→1.13.8 |
| Scaleway, re-run | 2026-08-20 | 1.36.3 | 1.13.8→1.13.9 |'
gate; expect "two rows on one day: the later one is judged, here current" 0

echo
echo "=== each provider is judged on its own ==="
status <<<"$GREEN
| OVH | 2026-08-19 | ✅ 1.36.2→1.36.3 | ✅ 1.13.7→1.13.8 |"
gate; expect "scaleway current, ovh stale" 1
grep -q '^✓ scaleway' <<<"$out" && stale_lines | grep -q '^✗ ovh' && ! stale_lines | grep -q scaleway \
  && ok "scaleway passes and only ovh is flagged" || bad "wrong providers flagged: $out"
grep -q '1 current, 1 stale' <<<"$out" && ok "the tally ends the output" || bad "no tally: $out"

echo
echo "=== --warn (task preflight): stale is news, a broken extractor still fails ==="
status <<<"$GREEN"
gate --warn; expect "current under --warn" 0
grep -q '⚠' <<<"$out" && bad "a current tree was warned about: $out" || ok "…and nothing is warned"
cluster v1.13.10 v1.36.3
gate --warn; expect "stale under --warn" 0
grep -q '^✗ scaleway' <<<"$out" && grep -q '⚠' <<<"$out" && ok "…but the stale line and the warning are printed" || bad "stale not reported: $out"
no_table() { printf '# fixture\n\nNo table here.\n' >"$ST"; }
no_table; gate --warn; expect "not verifiable under --warn" 2
cluster v1.13.9 v1.36.3

echo
echo "=== not verifiable is 2, never 1: the extractor is broken, not the repository ==="
no_table; gate; expect "no table at all" 2
printf '# fixture\n\n| | k8s | Talos |\n|---|---|---|\n| Scaleway | 1.36.3 | 1.13.9 |\n' >"$ST"
gate; expect "a table without a measured column" 2
status <<<'| Scaleway | 2026-13-45 | 1.36.3 | 1.13.9 |'; gate; expect "a date that does not exist" 2
status <<<'| Scaleway | 20260820 | 1.36.3 | 1.13.9 |'; gate; expect "a date not written YYYY-MM-DD" 2
status <<<'| Scaleway | — | 1.36.3 | 1.13.9 |'; gate; expect "a row with no date" 2
status <<<'| Scaleway | 2026-08-20 | 1.36.3 | — |'; gate; expect "a Talos cell with no version" 2
status <<<'| Scaleway | 2026-08-20 | unchanged | 1.13.9 |'; gate; expect "a Kubernetes cell with no version" 2
status <<<'| Scaleway | 2026-10-01 | 1.36.3 | 1.13.9 |'; gate; expect "a row dated after today" 2
status <<<'| Scaleway | 2026-08-20 | 1.36.3 |'; gate; expect "a row shorter than the header" 2
status <<<'| 2026-08-20 | 2026-08-20 | 1.36.3 | 1.13.9 |'; gate; expect "a first cell naming no provider" 2
status <<<"$GREEN"
OA_EVIDENCE_MAX_AGE_DAYS=abc gate; expect "OA_EVIDENCE_MAX_AGE_DAYS=abc" 2
TODAY=yesterday gate; expect "OA_EVIDENCE_TODAY=yesterday" 2
printf 'variable "talos_version" {\n  type = string\n}\n' >"$CL/variables.tf"
gate; expect "a variables.tf with no default" 2
cluster not-a-version v1.36.3; gate; expect "a pin that is not a version" 2
cluster v1.13.9 v1.36.3
rm "$CL/variables.tf"; gate; expect "a cluster dir with no variables.tf" 2
grep -q 'pin' <<<"$out" && ok "and it names the pin it could not read" || bad "no pin named: $out"
cluster v1.13.9 v1.36.3
printf '| | measured | k8s | Talos |\n|---|---|---|---|\n| Scaleway | 2026-08-20 | 1.36.3 | \xff1.13.9 |\n' >"$ST"
gate; expect "a status file that is not UTF-8" 2
status <<<"$GREEN"; rm "$ST"; gate; expect "a status file that is not there" 2

echo
echo "=== the pin comes from variables.tf, never from a real tfvars ==="
pin="$("$ROOT/scripts/internal/talos-version.sh")"
out="$("$GATE" 2>&1)"
grep -qF "$pin" <<<"$out" && ok "on this tree, the printed pin is talos-version.sh's ($pin)" || bad "pin $pin not printed: $out"
cluster v1.13.9 v1.36.3
status <<<"$GREEN"
before="$(OA_EVIDENCE_TODAY=2026-09-30 "$GATE" --status "$ST" --cluster-dir "$CL" 2>&1)"
printf 'talos_version = "v9.9.9"\nkubernetes_version = "v9.9.9"\n' >"$CL/envs/management-x.tfvars"
gate
[ "$rc" -eq 0 ] && [ "$out" = "$before" ] && ok "an envs/*.tfvars beside variables.tf changes nothing" || bad "a tfvars changed the verdict: $out"

echo
echo "=== the real tree parses (a verdict is not asserted) ==="
out="$("$GATE" 2>&1)"; rc=$?
[ "$rc" -le 1 ] && ok "docs/status.md is read: rc=$rc, never 2" || bad "docs/status.md is not readable by the gate (rc=$rc): $out"
n="$(grep -cE '^[✓✗] ' <<<"$out")"
[ "$n" -ge 3 ] && ok "$n providers judged" || bad "fewer than 3 providers judged ($n): $out"

echo
echo "=== wiring: what task runs the gate, and what must never ==="
# A date-driven gate inside `lint` or `test` would turn a required check red
# with no commit, and this one is red by design until OVH and Outscale re-run.
for t in lint test; do
  dry="$(task --dir "$ROOT" --dry "$t" 2>&1)"
  grep -q 'check-evidence-age' <<<"$dry" && bad "task $t runs the gate — a required check would go red with no commit" \
    || ok "task $t does not run the gate"
done
dry="$(task --dir "$ROOT" --dry evidence-check 2>&1)"
grep -q 'check-evidence-age' <<<"$dry" && ok "task evidence-check runs the gate" || bad "task evidence-check does not name the gate: ${dry:0:200}"
dry="$(task --dir "$ROOT" --dry preflight 2>&1)"
grep -q 'check-evidence-age' <<<"$dry" && ok "task preflight runs the gate" || bad "task preflight does not name the gate"
export OA_EVIDENCE_TODAY=2026-09-30
"$GATE" >/dev/null 2>&1; want=$?
# Plain `task` turns any failure into 201; -x passes the script's own code through.
task --dir "$ROOT" -x evidence-check >/dev/null 2>&1; got=$?
[ "$got" -eq "$want" ] && ok "task evidence-check exits as the script does (rc=$got)" || bad "task exits $got, the script $want"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
