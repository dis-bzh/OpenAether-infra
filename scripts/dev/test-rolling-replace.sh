#!/usr/bin/env bash
# Unit tests for rolling-replace's gates, against a STUB kubectl.
#
# Every gate in rolling-replace.sh decides whether to drain a node, and the
# defects found in them on 2026-08-15 were all logic, not cloud: a resource name
# that resolved to the wrong CRD, an error read as an empty list, an `rc=$?` that
# `set -e` never reached. Each cost between 25 and 90 minutes of paid cloud time
# to notice. None of them needed a cluster to catch — they needed a fake kubectl
# and thirty seconds.
#
# The stub answers from fixture files keyed on the argv it receives, and can be
# told to FAIL a given query, which is the case the real ones kept getting wrong.
#
# Usage: test-rolling-replace.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

PASS=0
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# --- the stub ----------------------------------------------------------------
# STUB_PLAN is a file of "match<TAB>rc<TAB>stdout" lines. The first line whose
# match is a substring of the joined argv wins. No line matching = rc 1, empty.
# One record per line, so multi-line output is written with %% where a newline
# goes — several of these queries legitimately return a list.
cat >"$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
argv="$*"
[ -n "${STUB_PLAN:-}" ] && [ -f "$STUB_PLAN" ] || { exit 1; }
while IFS=$'\t' read -r match rc out; do
  [ -n "$match" ] || continue
  case "$argv" in
    *"$match"*)
      # Like the real thing: results on stdout, diagnostics on stderr. Getting
      # this wrong made the first run of these tests report two false failures,
      # which is the right way round for a harness to be wrong.
      out="${out//%%/$'\n'}"
      if [ "${rc:-0}" = 0 ]; then
        [ -n "$out" ] && printf '%b\n' "$out"
      else
        [ -n "$out" ] && printf '%b\n' "$out" >&2
      fi
      exit "${rc:-0}"
      ;;
  esac
done <"$STUB_PLAN"
exit 1
STUB
chmod +x "$STUB_DIR/kubectl"
export PATH="$STUB_DIR:$PATH"

# --- load the functions under test -------------------------------------------
# rolling-replace.sh is a script, not a library: source it with a sentinel that
# makes it define its functions and stop before doing anything.
extract() { # <fn name>...  — pull the named functions out, with their helpers
  awk -v fns="$1" '
    BEGIN { n = split(fns, a, ","); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\).*/, "", name); inside = (name in want) }
    inside { print }
    inside && /^\}/ { inside = 0 }
  ' "$ROOT/scripts/ops/rolling-replace.sh"
}

# shellcheck disable=SC2016
eval "$(cat <<'PRELUDE'
KCTL=(kubectl)
info() { printf '▶ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
# Only the ones the extracted code interpolates into its messages.
DRAIN_TIMEOUT=900s
CNPG_TIMEOUT=600
PDB_TIMEOUT=600
PRELUDE
)"
eval "$(extract 'cnpg_pod_state,cnpg_deadlocked,cnpg_installed,cnpg_pending,pdb_short,worker_cpu_requests,preflight_roll')"

# --- the upgrade-confirmation gate -------------------------------------------
# Extracted separately because it talks to talosctl, not kubectl, and needs its
# own stub. It exists because on 2026-08-19 six OVH nodes were Ready and on the
# new version while Talos had accepted none of the upgrades, and the roll called
# every one of them done.
UPGRADE_CONFIRM_TIMEOUT=2
POLL=1
ok_msgs="$STUB_DIR/ok"; : >"$ok_msgs"
ok_() { printf '%s\n' "$*" >>"$ok_msgs"; }
eval "$(extract 'assert_upgrade_confirmed' | sed -E 's/^([[:space:]]*)ok /\1ok_ /')"
eval "$(extract 'node_schematic')"
# EXIT, not return: the real die() ends the run, and a stub that merely returns
# lets the function carry on and answer 0 — which would make the gate look like
# it passed exactly when it refused. Each call is made in a subshell.
die() { printf '%s\n' "$*" >&2; exit 42; }

talos_stub() { # <stage> [<upgrade-tag>] [<services-block>]
  cat >"$STUB_DIR/talosctl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"get machinestatus"*) printf '{"spec":{"stage":"%s"}}\n' '$1' ;;
  *"get metakeys"*) [ -n '${2:-}' ] && printf '{"metadata":{"id":6},"spec":{"value":"%s"}}\n' '${2:-}'
                    printf '{"metadata":{"id":9},"spec":{"value":"x"}}\n' ;;
  *services*) printf '%b' '${3:-NODE SERVICE STATE\\n1 apid Running\\n}' ;;
  *"get extensions"*) printf '{"spec":{"metadata":{"name":"schematic","version":"%s"}}}\n' "\${STUB_SCHEMATIC:-aaaa}" ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/talosctl"
}


plan() { STUB_PLAN="$STUB_DIR/plan"; export STUB_PLAN; printf '%b' "$1" >"$STUB_PLAN"; }

echo "=== cnpg_pod_state: an unanswered query is not an absent pod ==="

plan 'get pod alive\t0\tTrue\n'
[ "$(cnpg_pod_state ns alive)" = ready ] && ok "a Ready pod reads ready" || bad "expected ready, got $(cnpg_pod_state ns alive)"

plan 'get pod slow\t0\tFalse\n'
[ "$(cnpg_pod_state ns slow)" = notready ] && ok "an unready pod reads notready" || bad "expected notready"

plan 'get pod gone\t1\tError from server (NotFound): pods "gone" not found\n'
[ "$(cnpg_pod_state ns gone)" = absent ] && ok "NotFound reads absent" || bad "expected absent"

plan 'get pod flaky\t1\tThe connection to the server was refused\n'
[ "$(cnpg_pod_state ns flaky)" = unknown ] && ok "an API error reads unknown, NOT absent" || bad "an API error read as absent — the defect this test exists for"

echo
echo "=== cnpg_deadlocked: fires on the measured shape and nothing else ==="

# The real deadlock: currentPrimary gone, target exists but unready, a third ready.
DEADLOCK='get clusters.postgresql.cnpg.io -A\t0\tfoundation-databases zitadel-db zitadel-db-1 zitadel-db-2\n'
plan "${DEADLOCK}get pod zitadel-db-1\t1\tError from server (NotFound): pods \"zitadel-db-1\" not found\nget pod zitadel-db-2\t0\tFalse\nget pods -l cnpg.io/cluster=zitadel-db\t0\tzitadel-db-2 False%%zitadel-db-3 True\n"
[ "$(cnpg_deadlocked)" = "foundation-databases zitadel-db zitadel-db-2 zitadel-db-1" ] \
  && ok "the measured deadlock is detected, naming the target to delete" \
  || bad "deadlock not detected: got '$(cnpg_deadlocked)'"

# Healthy: no switchover pending.
plan 'get clusters.postgresql.cnpg.io -A\t0\tfoundation-databases zitadel-db zitadel-db-1 zitadel-db-1\n'
[ -z "$(cnpg_deadlocked)" ] && ok "no switchover pending → does not fire" || bad "fired on a healthy cluster"

# Switchover pending but the primary pod still exists — a NORMAL election.
plan "${DEADLOCK}get pod zitadel-db-1\t0\tTrue\nget pod zitadel-db-2\t0\tFalse\nget pods -l cnpg.io/cluster=zitadel-db\t0\tzitadel-db-2 False%%zitadel-db-3 True\n"
[ -z "$(cnpg_deadlocked)" ] && ok "a normal election in progress → does not fire" || bad "fired during a healthy switchover"

# The API is flaky: currentPrimary reads unknown, not absent. Must NOT fire.
plan "${DEADLOCK}get pod zitadel-db-1\t1\tThe connection to the server was refused\nget pod zitadel-db-2\t0\tFalse\nget pods -l cnpg.io/cluster=zitadel-db\t0\tzitadel-db-2 False%%zitadel-db-3 True\n"
[ -z "$(cnpg_deadlocked)" ] && ok "an unreachable API → does not fire (would delete a live primary's target)" || bad "fired on an API error"

# Nothing else is ready: deleting the target would only make it worse.
plan "${DEADLOCK}get pod zitadel-db-1\t1\tError from server (NotFound): pods \"zitadel-db-1\" not found\nget pod zitadel-db-2\t0\tFalse\nget pods -l cnpg.io/cluster=zitadel-db\t0\tzitadel-db-2 False%%zitadel-db-3 False\n"
[ -z "$(cnpg_deadlocked)" ] && ok "no healthy instance to elect → does not fire" || bad "fired with nothing to elect"

echo
echo "=== cnpg_installed ==="
plan 'get crd clusters.postgresql.cnpg.io\t0\tclusters.postgresql.cnpg.io\n'
cnpg_installed && ok "CRD present → installed" || bad "expected installed"
plan 'get crd clusters.postgresql.cnpg.io\t1\tError from server (NotFound)\n'
cnpg_installed && bad "expected not installed" || ok "CRD absent → not installed"

# ==============================================================================
# The pre-roll survey
# ==============================================================================
# Fixtures, from the two clusters that measured the difference on 2026-08-15:
# Scaleway's three workers at 72/47/27% of CPU requests drained clean, OVH's
# three at 78/99/100% did not, and the roll took 2100s per node to say so.
CRD='get crd clusters.postgresql.cnpg.io\t0\tclusters.postgresql.cnpg.io\n'
NO_CRD='get crd clusters.postgresql.cnpg.io\t1\tError from server (NotFound)\n'

CAP_OK='describe nodes\t0\tName: w1%%  cpu 1440m (72%)  2 (100%)%%Name: w2%%  cpu 940m (47%)  2 (100%)%%Name: w3%%  cpu 540m (27%)  2 (100%)\n'
CAP_FULL='describe nodes\t0\tName: w1%%  cpu 1560m (78%)  2 (100%)%%Name: w2%%  cpu 1980m (99%)  2 (100%)%%Name: w3%%  cpu 2000m (100%)  2 (100%)\n'
CAP_ONE='describe nodes\t0\tName: w1%%  cpu 900m (45%)  2 (100%)\n'
CAP_FAIL='describe nodes\t1\tThe connection to the server was refused\n'

# A budget at 0/1/1 is zero BY DESIGN (a CNPG primary, a Longhorn
# instance-manager): as healthy as it will ever be, and not a finding.
PDB_BYDESIGN='get pdb\t0\t{"items":[{"metadata":{"namespace":"foundation-databases","name":"zitadel-db-primary"},"spec":{"selector":{"matchLabels":{"cnpg.io/cluster":"zitadel-db"}}},"status":{"disruptionsAllowed":0,"currentHealthy":1,"expectedPods":1}}]}\n'
PDB_SHORT='get pdb\t0\t{"items":[{"metadata":{"namespace":"observability","name":"vmselect"},"spec":{"selector":{"matchLabels":{"app":"vmselect"}}},"status":{"disruptionsAllowed":0,"currentHealthy":1,"expectedPods":2}}]}\n'
PDB_FAIL='get pdb\t1\tError from server: etcdserver: request timed out\n'

DB_WHOLE='get clusters.postgresql.cnpg.io -A\t0\tfoundation-databases zitadel-db 3 3%%observability grafana-db 2 2\n'
DB_SHORT='get clusters.postgresql.cnpg.io -A\t0\tfoundation-databases zitadel-db 3 2\n'
DB_BLANK='get clusters.postgresql.cnpg.io -A\t0\tfoundation-databases zitadel-db  \n'
DB_FAIL='get clusters.postgresql.cnpg.io -A\t1\tThe connection to the server was refused\n'

HEALTHY="${CRD}${CAP_OK}${PDB_BYDESIGN}${DB_WHOLE}"

# preflight_roll logs through ok/hr and ends in die, so it runs in a subshell:
# its `ok` must not be the harness's pass counter and its `die` must not take the
# harness with it. `set -e` inside, because the real script runs under it — an
# `rc=$?` after a failing assignment is dead code there and must be here too.
run_preflight() {
  ( set -e
    ok()  { printf '✓ %s\n' "$*"; }
    hr()  { :; }
    die() { printf '✗ %s\n' "$*" >&2; exit 1; }
    preflight_roll ) 2>&1
}
survey() { plan "$1"; if OUT="$(run_preflight)"; then RC=0; else RC=$?; fi; }
saw() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

echo
echo "=== worker_cpu_requests / pdb_short: the shared one-shot readings ==="

plan "$CAP_OK"
[ "$(worker_cpu_requests | tr '\n' ' ')" = "w1 72 w2 47 w3 27 " ] \
  && ok "the describe table parses to one percentage per worker" \
  || bad "parsed '$(worker_cpu_requests | tr '\n' ' ')'"

plan "$CAP_FAIL"
worker_cpu_requests >/dev/null 2>&1 && bad "a failed description returned success — no worker would read as no problem" \
  || ok "a failed description returns non-zero, not an empty node list"

plan "$PDB_BYDESIGN"
[ -z "$(pdb_short)" ] && ok "a budget at 0 allowed / 1 healthy / 1 expected is not short" \
  || bad "a by-design zero was reported as short — waiting on it never ends"

plan "$PDB_SHORT"
[ "$(pdb_short | cut -f1-3 | tr '\t' '/')" = "observability/vmselect/1/2" ] \
  && ok "a budget short of a pod is reported with its counts" || bad "got '$(pdb_short)'"

plan "$PDB_FAIL"
pdb_short >/dev/null 2>&1 && bad "a failed budget query returned success" \
  || ok "a failed budget query returns non-zero, not an empty list"

echo
echo "=== preflight_roll: one survey instead of three blocking waits ==="

survey "$HEALTHY"
[ "$RC" = 0 ] && saw "146% requested, 200% available" \
  && ok "a cluster that can lose a worker passes, and says by how much" \
  || bad "healthy cluster refused (rc ${RC}): ${OUT}"

survey "${CRD}${CAP_FULL}${PDB_BYDESIGN}${DB_WHOLE}"
[ "$RC" = 1 ] && saw "3 workers request 277%" \
  && ok "78/99/100% is refused before the first node, not after 2100s" \
  || bad "the OVH capacity shape was allowed (rc ${RC})"

survey "${CRD}${CAP_ONE}${PDB_BYDESIGN}${DB_WHOLE}"
[ "$RC" = 0 ] && saw "single worker" \
  && ok "a single-worker cluster is warned about, not blocked (non-HA is supported)" \
  || bad "non-HA topology refused (rc ${RC})"

survey "${CRD}${CAP_OK}${PDB_SHORT}${DB_WHOLE}"
[ "$RC" = 1 ] && saw "observability/vmselect" && saw "(1/2)" \
  && ok "a budget that allows nothing and is short of a pod is fatal, and named" \
  || bad "a short budget did not stop the roll (rc ${RC})"

survey "${CRD}${CAP_OK}${PDB_BYDESIGN}${DB_SHORT}"
[ "$RC" = 1 ] && saw "zitadel-db(2/3)" \
  && ok "a database missing an instance is fatal, and named" \
  || bad "a 2/3 CNPG cluster did not stop the roll (rc ${RC})"

survey "${CRD}${CAP_OK}${PDB_BYDESIGN}${DB_BLANK}"
[ "$RC" = 1 ] && saw "zitadel-db(?/?)" \
  && ok "an unpopulated status is not 'whole' — the 0/0 that used to pass" \
  || bad "a cluster with no status numbers read as whole (rc ${RC})"

survey "${NO_CRD}${CAP_OK}${PDB_BYDESIGN}"
[ "$RC" = 0 ] && saw "no CNPG CRD" \
  && ok "no CNPG installed → no database gate, and no false finding" \
  || bad "a cluster without CNPG was refused (rc ${RC})"

echo
echo "--- and the one that matters: a query that FAILED is not 'nothing wrong' ---"

survey "${CRD}${CAP_OK}${PDB_FAIL}${DB_WHOLE}"
[ "$RC" = 1 ] && ! saw "every budget that could recover" \
  && ok "an unanswered budget query is fatal, and never claims headroom" \
  || bad "an apiserver error read as 'no budget blocks' (rc ${RC})"

survey "${CRD}${CAP_OK}${PDB_BYDESIGN}${DB_FAIL}"
[ "$RC" = 1 ] && ! saw "every CNPG cluster is whole" \
  && ok "an unanswered CNPG query is fatal, and never claims the databases are whole" \
  || bad "an apiserver error read as 'every database is whole' (rc ${RC})"

survey "${CRD}${CAP_FAIL}${PDB_BYDESIGN}${DB_WHOLE}"
[ "$RC" = 1 ] && ! saw "available without one worker" \
  && ok "an unanswered node description is fatal, and never claims capacity" \
  || bad "an apiserver error read as 'there is room' (rc ${RC})"

echo
echo "--- everything at once: all findings, then exactly one death ---"

survey "${CRD}${CAP_FULL}${PDB_SHORT}${DB_SHORT}"
[ "$RC" = 1 ] && saw "277%" && saw "observability/vmselect" && saw "zitadel-db(2/3)" \
  && ok "three separate blockers are all reported from one survey" \
  || bad "the survey stopped at the first blocker (rc ${RC}): ${OUT}"
[ "$(grep -c '✗' <<<"$OUT")" = 1 ] \
  && ok "…and it dies once, at the end, not per finding" \
  || bad "expected one ✗, got $(grep -c '✗' <<<"$OUT")"

echo
echo "--- and that it is wired in: once, after the budgets are gone, before node 1 ---"
# Everything above tests a function the harness calls itself. The defect that
# cost the most on 2026-08-15 was a fix that was never REACHED, so assert the
# call site too: this is the one thing a stub kubectl cannot observe.
SUT="$ROOT/scripts/ops/rolling-replace.sh"
lineno() { grep -n "$1" "$SUT" | head -1 | cut -d: -f1; }
L_MAINT="$(lineno '^  cnpg_maintenance true$')"
L_PRE="$(lineno '^  preflight_roll$')"
L_ROLL="$(lineno 'replace_node worker')"
[ "$(grep -c '^  *preflight_roll$' "$SUT")" = 1 ] \
  && ok "the survey is called exactly once" || bad "expected one call site"
[ -n "$L_MAINT" ] && [ -n "$L_PRE" ] && [ -n "$L_ROLL" ] \
  && [ "$L_MAINT" -lt "$L_PRE" ] && [ "$L_PRE" -lt "$L_ROLL" ] \
  && ok "…after cnpg_maintenance took effect and before the first replace_node" \
  || bad "call site missing or out of order (maintenance ${L_MAINT:-?}, survey ${L_PRE:-?}, roll ${L_ROLL:-?})"

echo

echo "=== the roll must ask Talos whether it ACCEPTED the upgrade ==="

talos_stub running ""
out="$( { assert_upgrade_confirmed ep 10.255.255.1 node-a; } 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "stage=running with no fallback tag: the node is done" \
  || bad "a confirmed upgrade was rejected (rc=$rc): $out"
grep -q 'upgrade confirmed' "$ok_msgs" && ok "and it says so" || bad "it stayed silent on success"

talos_stub booting "" 'NODE SERVICE STATE\nx ext-qemu-guest-agent Waiting\nx kubelet Running\n'
out="$( { assert_upgrade_confirmed ep 10.255.255.1 node-b; } 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && ok "stage=booting STOPS the roll instead of moving to the next node" \
  || bad "a node whose upgrade Talos never accepted was called done"
grep -q 'WILL REVERT' <<<"$out" && ok "it says the node will revert on its next reboot" \
  || bad "it does not warn about the revert: $out"
grep -q 'ext-qemu-guest-agent' <<<"$out" && ok "and it NAMES the service blocking the boot" \
  || bad "it does not name the stuck service — the diagnosis that cost an afternoon"

talos_stub running "A"
out="$( { assert_upgrade_confirmed ep 10.255.255.1 node-c; } 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'still carries META Upgrade=A' <<<"$out" \
  && ok "running but tag still set: warns, does not block" \
  || bad "the tag-still-present case is not reported (rc=$rc): $out"



echo "=== a node on the right version but the WRONG schematic is not done ==="

# The schematic carries the system extensions. Comparing the version tag alone
# made a schematic change undeliverable by any supported path: every gate said
# "already runs v1.13.8 — skipping" while the fleet sat on the image that broke
# OVH. Measured on a live Scaleway cluster, 2026-08-19.
talos_stub running ""
export STUB_SCHEMATIC=53513e54
out="$(node_schematic ep 10.255.255.1)"
[ "$out" = 53513e54 ] && ok "the running schematic is read off the node" \
  || bad "node_schematic returned '$out'"

printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_DIR/talosctl"; chmod +x "$STUB_DIR/talosctl"
out="$(node_schematic ep 10.255.255.1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok "an unreachable node yields empty, and does not fail the caller" \
  || bad "node_schematic propagated a failure (rc=$rc, out='$out')"
unset STUB_SCHEMATIC

grep -q 'want_sch != .*have_sch\|want_sch" != "\$have_sch' "$ROOT/scripts/ops/rolling-replace.sh" \
  && ok "the skip compares the schematic as well as the tag" \
  || bad "the skip is back to comparing the version tag alone"

echo "=== the etcd leader is rolled LAST, and hands over deliberately ==="
# Taking the leader down forces an election, and during one EVERY apiserver
# fails — which is what a consecutive run of probe failures looks like. Rolling
# the followers first leaves the leader untouched (quorum holds at 2/3), so the
# cluster pays ONE chosen hand-off instead of three forced elections.
eval "$(extract 'etcd_member_and_leader,etcd_leader_index,cp_roll_order')"
CP_IPS=(10.0.0.1 10.0.0.2 10.0.0.3)
talos_ep() { printf 'ep%s' "$2"; }

# A stub that answers `etcd status` per node: the node whose own MEMBER equals
# STUB_LEADER is the leader, exactly as a real cluster reports it.
etcd_stub() { # <leader-ip>
  cat >"$STUB_DIR/talosctl" <<STUB
#!/usr/bin/env bash
node=""; prev=""
for a in "\$@"; do [ "\$prev" = "-n" ] && node="\$a"; prev="\$a"; done
case "\$*" in
  *"etcd status"*)
    declare -A ids=( [10.0.0.1]=aaaaaaaaaaaaaaa1 [10.0.0.2]=aaaaaaaaaaaaaaa2 [10.0.0.3]=aaaaaaaaaaaaaaa3 )
    lead="\${ids[$1]}"
    echo "NODE MEMBER DB SIZE IN USE LEADER RAFT INDEX"
    echo "\$node \${ids[\$node]} 12 MB 4.0 MB (34.06%) \$lead 30689"
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/talosctl"
}

for lead_ip in 10.0.0.1 10.0.0.2 10.0.0.3; do
  etcd_stub "$lead_ip"
  case "$lead_ip" in 10.0.0.1) li=0; want="1 2 0" ;; 10.0.0.2) li=1; want="0 2 1" ;; *) li=2; want="0 1 2" ;; esac
  got="$(PATH="$STUB_DIR:$PATH" cp_roll_order | tr '\n' ' ' | sed 's/ $//')"
  [ "$got" = "$want" ] \
    && ok "leader on cp-${li}: rolled last (order ${got})" \
    || bad "leader on cp-${li}: expected '${want}', got '${got}'"
  [ "$(PATH="$STUB_DIR:$PATH" etcd_leader_index)" = "$li" ] \
    && ok "and the leader is identified as cp-${li}" \
    || bad "the leader was not identified as cp-${li}"
done

# A cluster that will not say who leads is not a reordering problem: keep the
# declared order and say so, rather than inventing one.
cat >"$STUB_DIR/talosctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_DIR/talosctl"
# cp_roll_order runs in a subshell, so a variable it sets cannot be read back
# here — the warning has to be observed on stderr, where it actually goes.
warn() { printf 'WARN:%s\n' "$*" >&2; }
WARN_OUT="$STUB_DIR/warn.txt"
got="$(PATH="$STUB_DIR:$PATH" cp_roll_order 2>"$WARN_OUT" | tr '\n' ' ' | sed 's/ $//')"
[ "$got" = "0 1 2" ] && grep -q 'could not identify the etcd leader' "$WARN_OUT" \
  && ok "an unreadable etcd keeps the index order, and says so" \
  || bad "unreadable etcd: order='${got}' warn='$(tr -d '\n' <"$WARN_OUT")'"

grep -q 'etcd forfeit-leadership' "$ROOT/scripts/ops/rolling-replace.sh" \
  && ok "the roll hands leadership over instead of letting it be taken" \
  || bad "no forfeit-leadership — the last control plane still forces an election"



echo
echo "=== the roll reads the role's env file, not always management's ==="
# `task cluster-roll` declared a ROLE variable that nothing read, and both the
# Taskfile and this script spelled the env file `management-<provider>.tfvars`.
# So `cluster-upgrade ROLE=workload` applied the workload tfvars in its two
# phases and then rolled against the MANAGEMENT state. Three call sites had to
# agree, and only a source read can see two of them — a stub kubectl cannot
# observe which file `tofu init` was handed.
SUT_R="$ROOT/scripts/ops/rolling-replace.sh"
TFY="$ROOT/Taskfile.yml"

grep -qE '^TFVARS="envs/\$\{ROLE\}-\$\{PROVIDER\}\.tfvars"$' "$SUT_R" \
  && ok "rolling-replace builds the env path from the role" \
  || bad "rolling-replace still hardcodes a role in TFVARS"

[ "$(grep -c 'envs/management-\${PROVIDER}' "$SUT_R")" = 0 ] \
  && ok "…and no hardcoded 'management' env path is left in it" \
  || bad "a hardcoded management env path survives in rolling-replace"

grep -q -- '--role=\*)' "$SUT_R" \
  && ok "it accepts --role=" || bad "no --role= in the flag parser"

# The default is what keeps every existing caller working: nothing else in the
# repository passed a role before this change.
grep -qE '^ROLE="management"$' "$SUT_R" \
  && ok "…defaulting to management, so existing callers are unchanged" \
  || bad "no management default — existing callers would break"

# The Taskfile half. Both its lines have to move together: the tofu init that
# selects the BACKEND, and the script call that selects the STATE it rolls.
grep -q 'tf-backend.sh envs/{{.ROLE}}-{{.PROVIDER}}.tfvars' "$TFY" \
  && ok "cluster-roll inits the backend for the role" \
  || bad "cluster-roll still inits the management backend whatever the role"

grep -q 'rolling-replace.sh {{.PROVIDER}} --role={{.ROLE}}' "$TFY" \
  && ok "…and passes that role to the script" \
  || bad "cluster-roll does not pass ROLE to rolling-replace"

# And the caller that had the role all along and never forwarded it.
[ "$(grep -c 'task cluster-roll PROVIDER="\$PROVIDER" ROLE="\$ROLE"' "$ROOT/scripts/dev/cluster-upgrade.sh")" = 2 ] \
  && ok "cluster-upgrade forwards its role on both rolls" \
  || bad "cluster-upgrade still rolls without saying which role"

echo
echo "=== the roll applies the plan it counted, not a fresh one (#55) ==="
# An `apply -auto-approve` re-plans, so the blast-radius count guarded a plan
# nobody applied. The stub tofu logs its argv and answers `show -json` from
# STUB_SHOW; each call runs in a subshell because die() exits.
TOFU_LOG="$STUB_DIR/tofu.log"
cat >"$STUB_DIR/tofu" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TOFU_LOG"
case "$1" in
  plan)  for a in "$@"; do [[ "$a" == -out=* ]] && : >"${a#-out=}"; done
         exit "${STUB_PLAN_RC:-0}" ;;
  show)  printf '%s\n' "$STUB_SHOW" ;;
  apply) exit "${STUB_APPLY_RC:-0}" ;;
esac
STUB
chmod +x "$STUB_DIR/tofu"
export TOFU_LOG
eval "$(extract 'saved_plan_apply')"
TFVARS=envs/management-test.tfvars
REPLACE_ONE='{"resource_changes":[{"change":{"actions":["delete","create"]}},{"change":{"actions":["update"]}}]}'
REPLACE_THREE='{"resource_changes":[{"change":{"actions":["delete","create"]}},{"change":{"actions":["create","delete"]}},{"change":{"actions":["delete"]}}]}'
spa() { # <show-json> [max]  — run saved_plan_apply against the stub
  : >"$TOFU_LOG"
  export STUB_SHOW="$1"
  OUT="$( ( ok() { :; }; saved_plan_apply n1-instance "${2:-2}" "APPLY FAILED" -target=a -replace=a ) 2>&1 )"; RC=$?
}
out_file() { sed -nE 's/^plan .*-out=([^ ]+).*/\1/p' "$TOFU_LOG"; }

spa "$REPLACE_ONE"
PF="$(out_file)"
[ "$RC" = 0 ] && [ -n "$PF" ] && grep -qxF "apply $PF" "$TOFU_LOG" \
  && ok "the apply is handed exactly the file the plan wrote" \
  || bad "apply did not consume the saved plan (rc ${RC}): $(tr '\n' '|' <"$TOFU_LOG")"
grep -qxF "show -json $PF" "$TOFU_LOG" \
  && ok "…and the count is read from that same file" || bad "the count did not come from the saved plan"
! grep -qE '^apply .*(-auto-approve|-target|-replace)' "$TOFU_LOG" \
  && ok "…with no targets or -auto-approve on the apply, so nothing re-plans" \
  || bad "the apply re-plans: $(grep '^apply' "$TOFU_LOG")"
[ ! -e "$PF" ] && ok "…and the plan file (it holds secrets) is removed afterwards" \
  || bad "the saved plan was left on disk at $PF"

spa "$REPLACE_THREE"
[ "$RC" -ne 0 ] && ! grep -q '^apply' "$TOFU_LOG" && grep -q 'destroys 3 resources' <<<"$OUT" \
  && ok "a plan that destroys 3 when 2 are expected is refused, and never applied" \
  || bad "the blast-radius guard let the plan through (rc ${RC}): ${OUT}"

spa 'not json'
[ "$RC" -ne 0 ] && ! grep -q '^apply' "$TOFU_LOG" \
  && ok "an unreadable saved plan is refused, not read as zero deletes" \
  || bad "an unreadable plan was applied (rc ${RC})"

STUB_PLAN_RC=1 spa "$REPLACE_ONE"
[ "$RC" -ne 0 ] && ! grep -q '^apply' "$TOFU_LOG" && grep -q 'could not plan' <<<"$OUT" \
  && ok "a failed plan reaches die and is never applied" \
  || bad "a failed plan was not refused by name (rc ${RC}): ${OUT}"

STUB_APPLY_RC=1 spa "$REPLACE_ONE"
[ "$RC" -ne 0 ] && grep -q 'APPLY FAILED' <<<"$OUT" \
  && ok "a failed apply dies with the caller's message" \
  || bad "a failed apply was not reported (rc ${RC}): ${OUT}"

# The call sites: the gate above is worthless if replace_node goes around it.
[ "$(grep -c '^  saved_plan_apply ' "$SUT_R")" = 2 ] \
  && ok "replace_node goes through it for both applies (instance, then config)" \
  || bad "expected two saved_plan_apply call sites"
[ "$(grep -v '^[[:space:]]*#' "$SUT_R" | grep -c -- '-auto-approve')" = 0 ] \
  && [ "$(grep -cE '^[[:space:]]*tofu apply' "$SUT_R")" = "$(grep -cE '^[[:space:]]*tofu apply "\$pf"' "$SUT_R")" ] \
  && ok "no -auto-approve apply is left, and no tofu apply is handed anything but the plan file" \
  || bad "a re-planning apply survives: $(grep -nE -- '-auto-approve|^[[:space:]]*tofu apply' "$SUT_R" | tr '\n' '|')"
grep -q 'would: tofu plan -out=' "$SUT_R" && ! grep -qE 'would: tofu apply .*-target' "$SUT_R" \
  && ok "--dry-run prints the saved-plan commands, not the old re-planning apply" \
  || bad "--dry-run still prints a targeted apply"
# `for t in` inside replace_node overwrote its cp|worker $t, and the etcd gate
# after the applies silently never ran for a replaced control plane.
[ "$(extract 'replace_node' | grep -c 'for t in')" = 0 ] \
  && ok "replace_node does not reuse \$t (its cp|worker role) as a loop variable" \
  || bad "replace_node loops over \$t again — the etcd gate after it is skipped for CPs"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
