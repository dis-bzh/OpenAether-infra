#!/usr/bin/env bash
# Tests for scripts/ops/teardown-all.sh, the dev fast lane that destroys a cluster in one command.
#
# One concern: the GUARD. A guard that fails open is worse than none, so every refusal below
# asserts that NOTHING ran, and each guard condition has a test that goes red when the condition
# is removed. The script runs from a COPY of the tree (so it needs no test seam and nothing here
# can touch a real checkout), on a PATH that holds only stubs and a few system tools: any other
# command is logged by command_not_found_handle and fails the run that issued it.
#
# Usage: test-teardown-all.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1   # the last section renders this tree's Taskfile
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
# Before the jail: the last section renders the real Taskfile.
REAL_TASK="$(command -v task || true)"
ORIG_PATH="$PATH"
CALLS="$STUB_DIR/calls" KC_LOG="$STUB_DIR/kc" TTY_LOG="$STUB_DIR/tty" FD_LOG="$STUB_DIR/fd.log"
export CALLS KC_LOG TTY_LOG FD_LOG
# Nothing inherited may stand in for a fixture: credentials would make fleet-down probe a real state.
unset OA_NO_TEARDOWN_ALL OA_ENVS_DIR KUBECONFIG CONFIRM TF_CLI_ARGS TF_CLI_ARGS_plan TF_CLI_ARGS_apply TF_CLI_ARGS_destroy
# shellcheck disable=SC2046  # the names are plain identifiers
unset $(compgen -e | grep -E '^(SCW|OVH|OS|OUTSCALE|AWS)_' || true)

# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
oa_require_fn tfv tfv_strict || exit 1

PASS=0 FAIL=0 SKIP=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33m↷ SKIPPED\033[0m %s\n' "$*"; SKIP=$((SKIP + 1)); }

# --- the tree under test: copies of what the script reads, stubs for what it calls ----------
TREE="$STUB_DIR/tree" CLUSTER="$STUB_DIR/tree/infrastructure/opentofu/cluster"
SCRIPT="$TREE/scripts/ops/teardown-all.sh"
mkdir -p "$TREE/scripts/lib" "$TREE/scripts/ops/purge-orphans" "$TREE/scripts/internal" "$CLUSTER/envs" "$STUB_DIR/bin" "$STUB_DIR/fd"
cp "$ROOT/scripts/lib/common.sh" "$TREE/scripts/lib/"
cp "$ROOT/scripts/internal/resolve-s3-cred.sh" "$ROOT/scripts/internal/tf-backend.sh" "$TREE/scripts/internal/"
cp "$ROOT/scripts/ops/teardown-all.sh" "$SCRIPT"
cp "$ROOT/infrastructure/opentofu/cluster/variables.tf" "$CLUSTER/"
: >"$TREE/scripts/ops/purge-orphans/scaleway.py"; : >"$TREE/scripts/ops/purge-orphans/ovh.py"
: >"$TREE/scripts/ops/purge-orphans/outscale.py"   # proxmox gets no purge script, like the real tree
: >"$TREE/scripts/ops/verify-provider-clean.py"

# fleet-down: a stub that records its call, the kubeconfig and the stdin it was given; or the real one.
cat >"$STUB_DIR/fleet-down.stub" <<'STUB'
#!/usr/bin/env bash
printf 'fleet-down %s\n' "$*" >>"$CALLS"
printf '%s\n' "${KUBECONFIG-unset}" >>"$KC_LOG"
[ ! -t 0 ] || echo "fleet-down was given a terminal" >>"$TTY_LOG"
case " $* " in
  *" --plan "*)
    # Says "--force-no-edges" in its own output on purpose: nothing may parse it into a flag.
    echo "STUB PLAN $1: 7 to destroy (re-run with --force-no-edges if the management is unreachable)"
    [ "${STUB_FAIL_PLAN_ON:-}" = "$1" ] && exit 1 ;;
  *) [ "${STUB_FAIL_APPLY_ON:-}" = "$1" ] && exit 1 ;;
esac
exit 0
STUB
use_fleet() { cp "$([ "$1" = real ] && echo "$ROOT/scripts/ops/fleet-down.sh" || echo "$STUB_DIR/fleet-down.stub")" "$TREE/scripts/ops/fleet-down.sh"; chmod +x "$TREE/scripts/ops/fleet-down.sh"; }
# python3 stands in for both proof scripts: it fails like python does on a missing file, and the exit code is chosen per script.
cat >"$STUB_DIR/bin/python3" <<'STUB'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >>"$CALLS"
[ -f "$1" ] || { echo "python3: can't open file '$1'" >&2; exit 2; }
for ((n = 0; n < ${STUB_PY_LINES:-1}; n++)); do echo "stub listing line $n"; done
[ -z "${STUB_PY_STDERR:-}" ] || echo "$STUB_PY_STDERR" >&2
case "$1" in *verify-provider-clean*) exit "${STUB_VERIFY_RC:-0}" ;; *) exit "${STUB_PURGE_RC:-0}" ;; esac
STUB
# task: only `kubeconfig` is legitimate here, and it can fail.
cat >"$STUB_DIR/bin/task" <<'STUB'
#!/usr/bin/env bash
printf 'task %s\n' "$*" >>"$CALLS"
[ "$1" = kubeconfig ] && exit "${STUB_KUBECONFIG_RC:-0}"
exit 99
STUB
chmod +x "$STUB_DIR"/bin/*
# The jail: these system tools and nothing else. A command that is not here is not run, it is logged.
for b in bash env sed grep awk tr cat head dirname basename mkdir rm cp mv mktemp date sort uniq cut tee sleep wc ls chmod ln touch script; do
  if p="$(type -P "$b")"; then ln -sf "$p" "$STUB_DIR/bin/$b"; fi
done
cat >"$STUB_DIR/notfound.sh" <<'STUB'
command_not_found_handle() { printf 'NOTFOUND %s\n' "$*" >>"$CALLS"; return 127; }
STUB
export BASH_ENV="$STUB_DIR/notfound.sh" PATH="$STUB_DIR/bin"
use_fleet stub

# --- fixtures -----------------------------------------------------------------
# tfvars <provider> [environment line(s)]: a dev cluster, named per provider, unless told otherwise.
tfvars() {
  local f="$CLUSTER/envs/${TFROLE:-management}-$1.tfvars"
  rm -f "$f"
  { echo "cluster_name = \"lab-$1\""
    printf '%s\n' "${2-environment = \"dev\"}"
    printf 'node_distribution = {\n  %s = {\n    control_planes = 1\n  }\n}\n' "$1"; } >"$f"
}
fresh() { rm -f "$CLUSTER/envs"/* "$TREE/.no-teardown-all"; }

# What a run of teardown-all calls, by target. Each fleet-down call is preceded by the fetch of that
# target's own kubeconfig.
kind_of() { case "$1" in ovh) echo openstack ;; *) echo "$1" ;; esac; }
plan_calls()  { local r="${2:-management}"; echo "task kubeconfig PROVIDER=$1 ROLE=$r"; echo "fleet-down $1 --role $r --plan${3:+ $3}"; }
apply_calls() { local r="${2:-management}"; echo "task kubeconfig PROVIDER=$1 ROLE=$r"; echo "fleet-down $1 --role $r --plan-file destroy-$r-$1.tfplan --yes${3:+ $3}"; }
proof_calls() { echo "python3 $TREE/scripts/ops/purge-orphans/$1.py"; echo "python3 $TREE/scripts/ops/verify-provider-clean.py lab-$1-dev $(kind_of "$1")"; }

# The only things a run of teardown-all may ever execute. Anything else, a purge with --apply, a
# bucket or image deletion, a tofu call, a command outside the jail, fails the run that issued it.
P="(scaleway|ovh|outscale|proxmox)"
ALLOWED_RE="^(task kubeconfig PROVIDER=$P ROLE=[a-z0-9]+"
ALLOWED_RE+="|fleet-down $P --role [a-z0-9]+ --plan( --force-no-edges)?"
ALLOWED_RE+="|fleet-down $P --role [a-z0-9]+ --plan-file destroy-[a-z0-9]+-$P\.tfplan --yes( --force-no-edges)?"
ALLOWED_RE+="|python3 $TREE/scripts/ops/purge-orphans/(scaleway|ovh|outscale)\.py"
ALLOWED_RE+="|python3 $TREE/scripts/ops/verify-provider-clean\.py [a-z0-9-]+ (scaleway|openstack|outscale))\$"
RUNS=0 STRAYS=0
ALL_CALLS="$STUB_DIR/all-calls"

audit() {
  local stray
  RUNS=$((RUNS + 1))
  cat "$CALLS" >>"$ALL_CALLS"
  stray="$(grep -Ev "$ALLOWED_RE" "$CALLS" || true)"
  if [ -n "$stray" ]; then STRAYS=$((STRAYS + 1)); bad "a run issued a command outside the allowed set: $(tr '\n' ';' <<<"$stray")"; fi
}

run() { # <args...>: captures output in OUT and status in RC; stdin is not a terminal
  : >"$CALLS"; : >"$KC_LOG"; : >"$TTY_LOG"
  if OUT="$("$SCRIPT" "$@" </dev/null 2>&1)"; then RC=0; else RC=$?; fi
  audit
}
pty() { # <typed | <EOF>> <args...>: the transcript of a run on a pseudo-terminal that answers <typed>, or hits end of input
  local typed="$1" cmd; shift
  cmd="$(printf '%q ' "$SCRIPT" "$@")"
  if [ "$typed" = '<EOF>' ]
    then script -qec "$cmd" /dev/null </dev/null 2>&1
    else printf '%s\n' "$typed" | script -qec "$cmd" /dev/null 2>&1
  fi
}
run_tty() { # <typed | <EOF>> <args...>
  local typed="$1"; shift
  : >"$CALLS"; : >"$KC_LOG"; : >"$TTY_LOG"
  if OUT="$(pty "$typed" "$@")"; then RC=0; else RC=$?; fi
  OUT="${OUT//$'\r'/}"
  audit
}

flat() { printf '%s' "${OUT//$'\n'/ | }"; }
expect_rc()  { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2 (exit $RC: $(flat))"; fi; }
expect_out() { case "$OUT" in *"$1"*) ok "$2" ;; *) bad "$2 (no '$1' in: $(flat))" ;; esac; }
refute_out() { case "$OUT" in *"$1"*) bad "$2 (found '$1' in: $(flat))" ;; *) ok "$2" ;; esac; }
calls_are() { # <label> <expected lines...>: the exact sequence of what ran
  local label="$1" want; shift
  want="$(printf '%s\n' "$@")"
  if [ "$(cat "$CALLS")" = "$want" ]; then ok "$label"; else bad "$label (ran: $(tr '\n' ';' <"$CALLS"))"; fi
}
no_calls() { if [ -s "$CALLS" ]; then bad "$1 (it ran: $(tr '\n' ';' <"$CALLS"))"; else ok "$1"; fi; }
# <label> <reason>: refused FOR THAT REASON (another guard refusing would hide a missing one),
# with the way out named, and not one command ran.
refused() {
  if [ "$RC" -ne 0 ] && grep -q 'teardown-all refused' <<<"$OUT" && grep -q 'task cluster-down' <<<"$OUT" \
     && grep -qF -- "$2" <<<"$OUT" && [ ! -s "$CALLS" ]
    then ok "$1"
    else bad "$1 (exit $RC, ran: $(tr '\n' ';' <"$CALLS"), wanted '$2', said: $(flat))"
  fi
}
# <label> <reason>: the operator's input was wrong, not the cluster: one line that says what to fix,
# without the production footer, and not one command ran.
needed() {
  if [ "$RC" -eq 1 ] && grep -q '^✗ teardown-all: ' <<<"$OUT" && ! grep -q 'task cluster-down' <<<"$OUT" \
     && grep -qF -- "$2" <<<"$OUT" && [ ! -s "$CALLS" ]
    then ok "$1"
    else bad "$1 (exit $RC, ran: $(tr '\n' ';' <"$CALLS"), wanted '$2', said: $(flat))"
  fi
}
# After a plan ran: nothing was destroyed, but the plan is not read-only, and the output must say so.
untracked_warned() { expect_out "may have untracked the Talos secrets" "$1: it says the plan may have untracked the Talos secrets"; }

ID_OVH=lab-ovh-dev-ovh

echo "=== the happy path: plan, then destroy exactly that plan, then prove ==="
fresh; tfvars ovh
run ovh --confirm "$ID_OVH"
expect_rc 0 "a dev cluster with its id typed is torn down"
calls_are "kubeconfig, plan, kubeconfig, then --yes and the plan file only, then both proofs, nothing else" \
  "$(plan_calls ovh)" "$(apply_calls ovh)" "$(proof_calls ovh)"
expect_out "teardown-all complete" "and it says so"
expect_out "$ID_OVH" "the banner names the cluster id"
expect_out "keep billing" "and that the buckets, images and keypairs it left are billed"

echo
echo "=== the children follow the guarded cluster, not the caller's KUBECONFIG ==="
# fleet-down deletes the CAPI children of whichever cluster its kubeconfig reaches.
fresh; tfvars ovh
KUBECONFIG=/ambient/prod.kubeconfig run ovh --confirm "$ID_OVH"
expect_rc 0 "a run with another cluster's KUBECONFIG exported"
if [ "$(sort -u "$KC_LOG")" = "$CLUSTER/kubeconfig" ]
  then ok "fleet-down was given the target's own kubeconfig, never the exported one (both calls)"
  else bad "fleet-down saw: $(tr '\n' ';' <"$KC_LOG")"
fi
STUB_KUBECONFIG_RC=1 KUBECONFIG=/ambient/prod.kubeconfig run ovh --confirm "$ID_OVH"
expect_out "no kubeconfig for ovh" "a kubeconfig that cannot be fetched is said"
if [ "$(sort -u "$KC_LOG")" = "$CLUSTER/kubeconfig.unavailable" ]
  then ok "…and fleet-down is pointed at nothing, not at what was left there or exported"
  else bad "fleet-down saw: $(tr '\n' ';' <"$KC_LOG")"
fi

# The real fleet-down on that tree, with only task and kubectl stubbed and edge-down a recorder.
# The stub kubectl lists a CAPI child only when the kubeconfig it is given belongs to a "prod" cluster.
use_fleet real
FD="$STUB_DIR/fd"; export FD_KUBECONFIG="$CLUSTER/kubeconfig"
cat >"$FD/task" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FD_LOG"
if [ "$1" = kubeconfig ]; then [ "${STUB_KUBECONFIG_RC:-0}" = 0 ] || exit 1; echo dev >"$FD_KUBECONFIG"; fi
STUB
cat >"$FD/kubectl" <<'STUB'
#!/usr/bin/env bash
kc="$(tr -d '\n' <"$KUBECONFIG" 2>/dev/null)"
printf 'kubectl %s\n' "${kc:-none}" >>"$FD_LOG"
case "$*" in *clusters.cluster.x-k8s.io*) [ "$kc" != prod ] || echo "prod-client-a capi-clusters" ;; esac
exit 0
STUB
cat >"$TREE/scripts/ops/edge-down.sh" <<'STUB'
#!/usr/bin/env bash
printf 'EDGE-DOWN %s\n' "$*" >>"$CALLS"
STUB
chmod +x "$FD/task" "$FD/kubectl" "$TREE/scripts/ops/edge-down.sh"
echo prod >"$STUB_DIR/prod.kubeconfig"
real_run() { : >"$FD_LOG"; PATH="$FD:$PATH" run "$@"; }
tasks_run() { grep -v '^kubectl ' "$FD_LOG" | tr '\n' ';'; }

fresh; tfvars ovh
real_run ovh --confirm "$ID_OVH"
expect_rc 0 "the real fleet-down accepts the plan and landing calls"
if [ "$(tasks_run)" = "kubeconfig PROVIDER=ovh ROLE=management;infra-down-plan ROLE=management PROVIDER=ovh OUT=destroy-management-ovh.tfplan;kubeconfig PROVIDER=ovh ROLE=management;infra-down ROLE=management PROVIDER=ovh PLAN=destroy-management-ovh.tfplan;" ]
  then ok "it plans to a file, then lands that same file, and nothing else is called"
  else bad "the real fleet-down ran: $(tasks_run)"
fi
KUBECONFIG="$STUB_DIR/prod.kubeconfig" real_run ovh --confirm "$ID_OVH"
expect_rc 0 "the real fleet-down, with a PROD management's kubeconfig exported"
if grep -q '^kubectl dev$' "$FD_LOG" && ! grep -q '^kubectl prod$' "$FD_LOG" && ! grep -q 'EDGE-DOWN' "$CALLS"
  then ok "…asks this cluster's management, finds no child, and deletes nothing of the exported cluster's"
  else bad "…it asked: $(tr '\n' ';' <"$FD_LOG") and ran: $(tr '\n' ';' <"$CALLS")"
fi
# fleet-down honors OA_ENVS_DIR too (its backend probe and its report): a leftover one must not reach it.
mkdir -p "$STUB_DIR/other-envs"; printf 'cluster_name = "other"\nenvironment = "dev"\n' >"$STUB_DIR/other-envs/management-ovh.tfvars"
OA_ENVS_DIR="$STUB_DIR/other-envs" real_run ovh --confirm "$ID_OVH"
expect_out "$(printf 's3-lab-ovh-%s-dev' tfstate)" "the real fleet-down reports this tree's buckets"
refute_out "s3-other-" "…not those of another tfvars named by a leftover OA_ENVS_DIR"
echo prod >"$FD_KUBECONFIG"   # a stale file at the shared path, left by whatever ran last
STUB_KUBECONFIG_RC=1 KUBECONFIG="$STUB_DIR/prod.kubeconfig" real_run ovh --confirm "$ID_OVH"
expect_rc 1 "when this cluster's kubeconfig cannot be fetched, fleet-down stops as for an unreachable management"
if ! grep -q 'kubectl prod' "$FD_LOG" && ! grep -q 'EDGE-DOWN' "$CALLS" && grep -q 'management cluster is unreachable' <<<"$OUT"
  then ok "…and never reads the stale or exported one, nor deletes its children"
  else bad "…it asked: $(tr '\n' ';' <"$FD_LOG") and ran: $(tr '\n' ';' <"$CALLS"), said: $(flat)"
fi
untracked_warned "…and the plan that failed"
STUB_KUBECONFIG_RC=1 KUBECONFIG="$STUB_DIR/prod.kubeconfig" real_run ovh --confirm "$ID_OVH" -- --force-no-edges
expect_rc 0 "--force-no-edges, typed, goes on without a kubeconfig"
if ! grep -q 'EDGE-DOWN' "$CALLS"; then ok "…and still deletes no child"; else bad "…it ran: $(tr '\n' ';' <"$CALLS")"; fi
rm -f "$FD_KUBECONFIG"
use_fleet stub

echo
echo "=== tfv_strict: what tofu would read, or a refusal ==="
# Direct calls: the guard also compares the value to "dev", which would hide a parser that
# let a duplicate or an unparseable line through. <content> <rc> <value> <label>
strict() {
  local got rc
  printf '%b' "$1" >"$STUB_DIR/strict.tfvars"
  got="$(tfv_strict "$STUB_DIR/strict.tfvars" environment)"; rc=$?
  if [ "$rc" = "$2" ] && [ "$got" = "$3" ]; then ok "$4"; else bad "$4 (rc=$rc value='$got', wanted rc=$2 value='$3')"; fi
}
strict 'environment = "dev"\n' 0 dev "a plain assignment"
strict 'environment="dev"   # lab\n' 0 dev "no spaces, a trailing comment"
strict 'environment = "dev "\n' 0 "dev " "whitespace inside the quotes is kept, not trimmed as tfv does"
strict 'environment = ""\n' 0 "" "an empty string is a value, not an absence"
strict 'environment = dev\n' 2 "" "an unquoted value is refused"
strict 'environment = "dev"\nenvironment = var.x\n' 2 "" "a second assignment is refused even when it does not parse"
strict '# environment = "dev"\n' 1 "" "a commented-out line is an absence"
strict 'environment_x = "dev"\n' 1 "" "another key is an absence"
strict 'foo-environment = "x"\nenvironment = "dev"\n' 0 dev "a key that only ends in environment is another key"
strict '/*\nenvironment = "dev"\n*/\n' 2 "" "a block comment is doubt"
strict 'environment = "dev" # environment = "prod"\n' 0 dev "a mention in a trailing comment is not an assignment"
strict 'environment = "dev" // environment = "prod"\n' 0 dev "nor is one after //"
strict '// environment = "prod"\nenvironment = "dev"\n' 0 dev "a // comment line is not an assignment"
strict 'url = "https://example.invalid/x"\nenvironment = "dev"\n' 0 dev "a // inside a string hides nothing"
strict 'environment = "d\\ev"\n' 2 "" "a backslash escape is refused"
strict 'environment = "dev" environment = "prod"\n' 2 "" "two assignments on one line are refused"
strict '  environment = "dev"\n' 2 "" "an indented assignment is refused: it may sit inside a map"
strict 'tags = {\n  environment = "dev"\n}\n' 2 "" "an assignment nested in a map is refused"
strict 'note = <<EOT\nenvironment = "dev"\nEOT\n' 2 "" "a heredoc is doubt: its body is not an assignment"
tfv_strict "$STUB_DIR/nowhere.tfvars" environment
if [ $? -eq 2 ]; then ok "a missing file is refused"; else bad "a missing file was not refused"; fi

echo
echo "=== guard 2: environment must be EXACTLY \"dev\" ==="
refuse_env() { # <label> <environment line(s)>
  fresh; tfvars ovh "$2"
  run ovh --confirm "$ID_OVH"
  refused "$1" "environment:"
}
refuse_env 'prod is refused' 'environment = "prod"'
refuse_env 'DEV is refused (string equality, not case folding)' 'environment = "DEV"'
refuse_env '"dev " is refused (a trailing space inside the quotes)' 'environment = "dev "'
refuse_env '" dev" is refused' 'environment = " dev"'
refuse_env '"development" is refused (no prefix match)' 'environment = "development"'
refuse_env 'an empty environment is refused' 'environment = ""'
refuse_env 'a missing environment is refused' ''
refuse_env 'an environment_x key is not environment' 'environment_x = "dev"'
refuse_env 'a commented-out dev is not a dev' '# environment = "dev"'
refuse_env 'an unquoted dev is refused (tofu would reject it too)' 'environment = dev'
refuse_env 'dev then prod is refused (duplicated key)' $'environment = "dev"\nenvironment = "prod"'
refuse_env 'prod then dev is refused (duplicated key, either order)' $'environment = "prod"\nenvironment = "dev"'
refuse_env 'a dev inside a block comment, prod after it' $'/*\nenvironment = "dev"\n*/\nenvironment = "prod"'
refuse_env 'a dev that only exists inside a block comment' $'/*\nenvironment = "dev"\n*/'
refuse_env 'a block comment before a prod, a commented dev after it' $'/* x */ environment = "prod"\n# environment = "dev"'
refuse_env 'a dev with trailing junk is refused' 'environment = "dev" environment = "prod"'
refuse_env 'a dev that only exists inside a heredoc (tofu would take the environment from elsewhere)' $'note = <<EOT\nenvironment = "dev"\nEOT'
refuse_env 'a dev that only exists inside a map' $'tags = {\n  environment = "dev"\n}'
refuse_env 'an indented dev is refused' ' environment = "dev"'

fresh; tfvars ovh; chmod 000 "$CLUSTER/envs/management-ovh.tfvars"
if [ -r "$CLUSTER/envs/management-ovh.tfvars" ]
  then skip "unreadable tfvars by mode: this user can read a mode-000 file (root); the dangling link below still runs"
  else run ovh --confirm "$ID_OVH"; refused "a tfvars that cannot be read is refused" "missing or unreadable"
fi
fresh; ln -s "$STUB_DIR/nowhere.tfvars" "$CLUSTER/envs/management-ovh.tfvars"
run ovh --confirm "$ID_OVH"
refused "a dangling tfvars link is refused" "missing or unreadable"
fresh
run ovh --confirm "$ID_OVH"
refused "a missing tfvars is refused" "missing or unreadable"
fresh; tfvars scaleway; mv "$CLUSTER/envs/management-scaleway.tfvars" "$CLUSTER/envs/management-ovh.tfvars"
run ovh --confirm "$ID_OVH"
refused "a dev tfvars that declares another provider than its name is refused" "declares"

# The environment the guard reads is the tree's own: a leftover OA_ENVS_DIR, which fleet-down honors, is dropped.
fresh; tfvars ovh 'environment = "prod"'
mkdir -p "$STUB_DIR/other-envs"; sed 's/"prod"/"dev"/' "$CLUSTER/envs/management-ovh.tfvars" >"$STUB_DIR/other-envs/management-ovh.tfvars"
OA_ENVS_DIR="$STUB_DIR/other-envs" run ovh --confirm "$ID_OVH"
refused "an OA_ENVS_DIR with a dev file does not stand in for the prod one the destroy reads" "not exactly"

# The other direction, or the refusals above are a script that never works.
fresh; tfvars ovh 'environment   =   "dev"   # the lab'
run ovh --confirm "$ID_OVH"
expect_rc 0 "dev with spacing and a trailing comment is accepted"
fresh; tfvars ovh $'environment = "dev"\n# environment = "prod" is for the real thing'
run ovh --confirm "$ID_OVH"
expect_rc 0 "a comment that mentions prod does not fool it either way"
fresh; { echo 'cluster_name = "lab-ovh"'; printf 'environment = "dev"\r\nnode_distribution = {\r\n  ovh = {\r\n  }\r\n}\r\n'; } >"$CLUSTER/envs/management-ovh.tfvars"
run ovh --confirm "$ID_OVH"
expect_rc 0 "CRLF line endings are read like tofu reads them"

fresh; tfvars ovh $'environment = "dev"\ns3_replica_endpoint = "https://s3.example.invalid" # prod crosses providers, or drop to environment = "dev"'
run ovh --confirm "$ID_OVH"
expect_rc 0 "a trailing comment that mentions environment = is not a second assignment (as in the shipped examples)"

# The shipped examples are the shapes real tfvars take: each, flipped to dev, must pass the guard,
# or the guard refuses files it should read. Only the environment line is edited.
SHIPPED="$ROOT/infrastructure/opentofu/cluster/envs"
for ex in "$SHIPPED"/*.tfvars.example; do
  base="$(basename "$ex" .tfvars.example)"; role="${base%%-*}"; prov="${base#*-}"
  fresh; sed -E 's/^(environment[[:space:]]*=[[:space:]]*)"[a-z]+"/\1"dev"/' "$ex" >"$CLUSTER/envs/$base.tfvars"
  name="$(tfv "$CLUSTER/envs/$base.tfvars" cluster_name)"
  run "$prov" --role "$role" --confirm "$name-dev-$prov"
  want=0; [ "$prov" = proxmox ] && want=4   # no provider-side check to run: the guard passed, the proof says so
  if [ "$RC" -eq "$want" ]; then ok "the shipped $base example, as dev, passes the guard"; else bad "the shipped $base example, as dev, was refused: $(flat)"; fi
done

# Without a cluster_name tofu takes the variable's default, and so must the confirmation.
fresh; printf 'environment = "dev"\nnode_distribution = {\n  ovh = {\n  }\n}\n' >"$CLUSTER/envs/management-ovh.tfvars"
run ovh --confirm "openaether-dev-ovh"
expect_rc 0 "an absent cluster_name names the cluster by the variable's default"
# But one that is there and unreadable must not degenerate into an id like "-dev-ovh".
fresh; printf 'cluster_name = ""\nenvironment = "dev"\nnode_distribution = {\n  ovh = {\n  }\n}\n' >"$CLUSTER/envs/management-ovh.tfvars"
run ovh --confirm "-dev-ovh"
refused "an empty cluster_name is refused" "cluster_name"
fresh; printf 'cluster_name = var.x\nenvironment = "dev"\nnode_distribution = {\n  ovh = {\n  }\n}\n' >"$CLUSTER/envs/management-ovh.tfvars"
run ovh --confirm "-dev-ovh"
refused "a cluster_name that is not a plain string is refused" "cluster_name"

echo
echo "=== guard 1: the kill switch ==="
fresh; tfvars ovh
OA_NO_TEARDOWN_ALL=1 run ovh --confirm "$ID_OVH"
refused "set to 1, a dev cluster is still refused" "kill switch"
OA_NO_TEARDOWN_ALL=yes run ovh --confirm "$ID_OVH"
refused "any other value locks it too" "OA_NO_TEARDOWN_ALL"
OA_NO_TEARDOWN_ALL='' run ovh --confirm "$ID_OVH"
refused "an empty value locks it as well (a half-filled export must not leave a host open)" "OA_NO_TEARDOWN_ALL"
touch "$TREE/.no-teardown-all"
run ovh --confirm "$ID_OVH"
refused "a .no-teardown-all file at the repo root locks every shell of the checkout" ".no-teardown-all"
rm -f "$TREE/.no-teardown-all"
run ovh --confirm "$ID_OVH"
expect_rc 0 "and with neither, a dev cluster goes"

echo
echo "=== guard 1: nothing in TF_CLI_ARGS* may override the tfvars the guard read ==="
fresh; tfvars ovh
for v in TF_CLI_ARGS TF_CLI_ARGS_plan TF_CLI_ARGS_apply TF_CLI_ARGS_destroy; do
  for a in '-var environment=prod' '-var=environment=prod' '-var-file=/elsewhere.tfvars'; do
    export "$v=$a"; run ovh --confirm "$ID_OVH"; unset "$v"
    refused "$v='$a' is refused, and named" "$v carries -var"
  done
  export "$v=-no-color"; run ovh --confirm "$ID_OVH"; unset "$v"
  expect_rc 0 "$v=-no-color, which overrides nothing, is accepted"
done

echo
echo "=== guard 3: nothing lifts a refusal, and nothing steers the destroy ==="
fresh; tfvars ovh 'environment = "prod"'
APPROVE=auto FORCE=1 YES=1 OA_YES=1 CONFIRM="$ID_OVH" run ovh --confirm "$ID_OVH"
refused "APPROVE, FORCE, YES and CONFIRM in the environment do not lift a prod refusal" "not exactly"
run ovh --confirm "$ID_OVH" -- --yes --force-no-edges
expect_rc 2 "--yes after -- is rejected, prod or not"
refute_out "teardown-all complete" "it did not run"
no_calls "…having called nothing"
fresh; tfvars ovh
for f in --yes --plan --plan-file --role --keep-images --apply --force-no-edge --force-no-edges=1 --force-no-edgesX --fish; do
  run ovh --confirm "$ID_OVH" -- "$f"
  if [ "$RC" -eq 2 ] && [ ! -s "$CALLS" ]; then ok "$f is not forwarded to fleet-down"; else bad "$f got through (exit $RC, ran: $(tr '\n' ';' <"$CALLS"))"; fi
done
run ovh --confirm "$ID_OVH" -- --force-no-edges --role other
expect_rc 2 "a forwarded flag next to an unforwardable one is rejected whole"
for args in "ovh --confirm $ID_OVH --yes" "ovh scaleway --confirm $ID_OVH" "ovh --confirm" "ovh --role" "--confirm $ID_OVH"; do
  # shellcheck disable=SC2086  # the words are the point
  run $args
  if [ "$RC" -eq 2 ] && [ ! -s "$CALLS" ]; then ok "usage error, nothing ran: $args"; else bad "'$args' was not a usage error (exit $RC, ran: $(tr '\n' ';' <"$CALLS"))"; fi
done
for role in 'management/..' 'a/../management' Management 'management x' 'management;x' ''; do
  run ovh --role "$role" --confirm "$ID_OVH"
  if [ "$RC" -eq 2 ] && [ ! -s "$CALLS" ]; then ok "the role '$role' is rejected"; else bad "the role '$role' got through (exit $RC, ran: $(tr '\n' ';' <"$CALLS"))"; fi
done
run bogus --confirm "$ID_OVH"
expect_rc 2 "an unknown provider is a usage error"
run
expect_rc 2 "no provider is a usage error"

echo
echo "=== guard 4: the cluster id is typed, and a wrong one destroys nothing ==="
fresh; tfvars ovh
run ovh
needed "no terminal and no CONFIRM: refused before any plan" "no terminal to ask"
refute_out "$ID_OVH" "…and the refusal does not hand over the id to re-run with"
run ovh --confirm "lab-scaleway-dev-scaleway"
needed "the id of another cloud is refused before any plan" "is not the cluster id"
refute_out "$ID_OVH" "…without naming the right one"
run ovh --confirm "lab-ovh-dev"
needed "the id without its provider is refused (it must tell the clouds apart)" "is not the cluster id"
run ovh --confirm "$ID_OVH "
needed "an id with a trailing space is refused" "is not the cluster id"
run ovh --confirm all
needed "'all' does not confirm a single provider" "is not the cluster id"
CONFIRM="$ID_OVH" run ovh
needed "a CONFIRM inherited from the environment is not a typed confirmation" "CONFIRM is exported"
CONFIRM="$ID_OVH" run ovh --confirm "$ID_OVH"
needed "…even when --confirm agrees with it" "CONFIRM is exported"

echo
echo "=== guard 4, on a terminal: typed AFTER the plan ==="
if ! command -v script >/dev/null 2>&1; then
  skip "interactive confirmation: util 'script' is not installed, so no pseudo-terminal"
else
  fresh; tfvars ovh
  run_tty "$ID_OVH" ovh
  expect_rc 0 "the right id typed on a terminal destroys"
  calls_are "kubeconfig, plan, kubeconfig, destroy, proof" "$(plan_calls ovh)" "$(apply_calls ovh)" "$(proof_calls ovh)"
  case "$OUT" in
    *"STUB PLAN"*"Type its cluster id"*) ok "the prompt comes after the plan was printed" ;;
    *) bad "the prompt did not follow the plan: $(flat)" ;;
  esac
  expect_out "Ignore the 'task cluster-down' line" "it tells the operator to ignore the cluster-down line a plan prints, which would skip the guard"
  if [ ! -s "$TTY_LOG" ]; then ok "fleet-down is never given the terminal: its own prompt cannot answer for the operator"; else bad "fleet-down read the terminal: $(cat "$TTY_LOG")"; fi
  for wrong in "wrong-id" "" "lab-ovh-dev" "LAB-OVH-DEV-OVH" "$ID_OVH-x" "l" "<EOF>"; do
    run_tty "$wrong" ovh
    expect_rc 1 "'$wrong' typed on a terminal aborts"
    calls_are "…having planned and destroyed nothing" "$(plan_calls ovh)"
    untracked_warned "…and the abort"
  done
  run_tty "$ID_OVH" ovh --confirm "lab-scaleway-dev-scaleway"
  needed "a wrong --confirm on a terminal is refused before any plan" "is not the cluster id"
  run_tty "" ovh --confirm "$ID_OVH"
  expect_rc 1 "--confirm does not stand in for reading the plan: a terminal still asks"
  calls_are "…and the plan was all that ran" "$(plan_calls ovh)"
  tfvars ovh 'environment = "prod"'
  run_tty "lab-ovh-prod-ovh" ovh
  refused "a prod cluster is refused on a terminal whatever is typed" "not exactly"
fi

echo
echo "=== a non-default role is guarded, planned, destroyed and looked up as itself ==="
fresh; TFROLE=workload tfvars ovh
run ovh --role workload --confirm "$ID_OVH"
expect_rc 0 "a workload cluster is torn down"
calls_are "…and every call carries the workload role and its own plan file" \
  "$(plan_calls ovh workload)" "$(apply_calls ovh workload)" "$(proof_calls ovh)"
tfvars ovh 'environment = "prod"'   # the management one of the same provider is prod: it must not be read
run ovh --role workload --confirm "$ID_OVH"
expect_rc 0 "the prod management tfvars next to it is not what the workload run guards"
fresh; tfvars ovh 'environment = "prod"'; TFROLE=workload tfvars ovh 'environment = "prod"'
run ovh --role workload --confirm "$ID_OVH"
refused "a prod workload tfvars is refused" "workload-ovh.tfvars"
fresh; TFROLE=workload tfvars scaleway; TFROLE=workload tfvars ovh; tfvars outscale 'environment = "prod"'
run all --role workload --confirm all
expect_rc 0 "all looks for <role>-<provider>.tfvars: the prod management outscale one is not a target"
calls_are "…and both targets run as workload" \
  "$(plan_calls scaleway workload)" "$(plan_calls ovh workload)" \
  "$(apply_calls scaleway workload)" "$(apply_calls ovh workload)" \
  "$(proof_calls scaleway)" "$(proof_calls ovh)"

echo
echo "=== guard 5: PROVIDER=all, one refusal and nothing at all is destroyed ==="
fresh; tfvars scaleway; tfvars ovh; tfvars outscale
run all --confirm all
expect_rc 0 "all three dev clusters are torn down with CONFIRM=all"
calls_are "every plan before any destroy, destroys in order, then every proof, each on its own cluster" \
  "$(plan_calls scaleway)" "$(plan_calls ovh)" "$(plan_calls outscale)" \
  "$(apply_calls scaleway)" "$(apply_calls ovh)" "$(apply_calls outscale)" \
  "$(proof_calls scaleway)" "$(proof_calls ovh)" "$(proof_calls outscale)"
for id in lab-scaleway-dev-scaleway lab-ovh-dev-ovh lab-outscale-dev-outscale; do
  expect_out "$id" "the banner names $id"
done
if command -v script >/dev/null 2>&1; then
  run_tty all all
  expect_rc 0 "'all' typed on a terminal, after every plan, destroys every target"
  case "$OUT" in
    *"STUB PLAN outscale"*"Type 'all'"*) ok "…and the prompt came after the last plan" ;;
    *) bad "the prompt did not follow the plans: $(flat)" ;;
  esac
  for wrong in "$ID_OVH" "<EOF>"; do
    run_tty "$wrong" all
    expect_rc 1 "'$wrong' typed for all aborts"
    calls_are "…after the three plans, with nothing destroyed" "$(plan_calls scaleway)" "$(plan_calls ovh)" "$(plan_calls outscale)"
    untracked_warned "…and the abort"
    expect_out "lab-scaleway-dev-scaleway lab-ovh-dev-ovh lab-outscale-dev-outscale" "…naming all three plans that ran"
  done
else
  skip "interactive confirmation of all: util 'script' is not installed"
fi
for prod in scaleway ovh outscale; do
  fresh; tfvars scaleway; tfvars ovh; tfvars outscale; tfvars "$prod" 'environment = "prod"'
  run all --confirm all
  refused "a prod $prod among dev clusters: nothing is planned or destroyed" "$prod: environment: \"prod\""
done
fresh; tfvars scaleway 'environment = "prod"'; tfvars ovh 'environment = "prod"'; tfvars outscale
run all --confirm all
refused "two prod clusters: the first is named" "scaleway: environment"
expect_out "ovh: environment" "…and so is the second"
fresh; tfvars scaleway; tfvars ovh; ln -s "$STUB_DIR/nowhere" "$CLUSTER/envs/management-outscale.tfvars"
run all --confirm all
refused "an unreadable tfvars among dev clusters refuses them all" "outscale: "
fresh; tfvars scaleway; tfvars ovh
OA_NO_TEARDOWN_ALL=1 run all --confirm all
refused "the kill switch refuses all" "OA_NO_TEARDOWN_ALL"
run all --confirm "$ID_OVH"
needed "a single id does not confirm all" "is not all"
run all
needed "all without CONFIRM is refused before any plan" "pass CONFIRM=<value>"
fresh
run all --confirm all
refused "all with no tfvars at all has no target" "no target"
fresh; tfvars proxmox; tfvars ovh
run all --confirm all
expect_rc 4 "a provider with no provider-side check is torn down, and ends with a code of its own"
expect_out "no provider-side check exists for proxmox" "and says it could not look"
expect_out "NOT proven clean on: proxmox." "and does not claim it was proven clean, nor name it twice"
refute_out "teardown-all complete" "…and there is no completion line"
fresh; tfvars proxmox
run proxmox --confirm lab-proxmox-dev-proxmox
expect_rc 4 "proxmox alone: destroyed, not proven, a non-zero exit"
# One destroy fails: stop, no proof for anything, the one not reached is not touched.
fresh; tfvars scaleway; tfvars ovh; tfvars outscale
STUB_FAIL_APPLY_ON=ovh run all --confirm all
expect_rc 3 "a destroy that fails stops the run with the code for a half-done teardown"
calls_are "…outscale was never destroyed, and no proof ran" \
  "$(plan_calls scaleway)" "$(plan_calls ovh)" "$(plan_calls outscale)" "$(apply_calls scaleway)" "$(apply_calls ovh)"
expect_out "destroying lab-ovh-dev-ovh FAILED" "…it names the one that failed"
expect_out "destroyed before it, NOT proven clean: lab-scaleway-dev-scaleway" "…what was destroyed before it, and that it was not proven"
expect_out "not attempted: outscale" "…what was never attempted"
expect_out "task teardown-all PROVIDER=ovh" "…the command to re-run the failed one, on its own"
expect_out "task teardown-all PROVIDER=outscale" "…and the one never reached"
expect_out "read what scaleway left" "…and how to look at the one that was destroyed"
# One plan fails: nothing has been destroyed yet, and nothing is.
STUB_FAIL_PLAN_ON=ovh run all --confirm all
expect_rc 1 "a plan that fails stops the run"
calls_are "…before any destroy" "$(plan_calls scaleway)" "$(plan_calls ovh)"
untracked_warned "…and it does not say 'nothing was destroyed' alone"
expect_out "lab-scaleway-dev-scaleway lab-ovh-dev-ovh" "…and names the plans that ran, the failed one included"
expect_out "task teardown-all PROVIDER=ovh -- --force-no-edges" "…and the way on that this lane has"

echo
echo "=== --force-no-edges: forwarded when typed, never synthesised ==="
fresh; tfvars ovh
run ovh --confirm "$ID_OVH"
if grep -q -- '--force-no-edges' "$CALLS"; then bad "the flag was added though nobody typed it: $(tr '\n' ';' <"$CALLS")"; else ok "not typed, not passed (the plan output mentioning it changes nothing)"; fi
run ovh --confirm "$ID_OVH" -- --force-no-edges
calls_are "typed, it goes to both fleet-down calls and nowhere else" \
  "$(plan_calls ovh management --force-no-edges)" "$(apply_calls ovh management --force-no-edges)" "$(proof_calls ovh)"

echo
echo "=== the proof, and what it never does ==="
fresh; tfvars ovh
STUB_PURGE_RC=1 run ovh --confirm "$ID_OVH"
expect_rc 3 "leftovers found by the purge dry-run fail the command"
expect_out "NOT proven clean" "and it says so"
expect_out "purge-orphans/ovh.py --apply" "it prints the manual apply for the operator"
expect_out "WHOLE project" "with the whole-project warning"
expect_out "WHOLE PROJECT (dry-run): LEFTOVERS" "and the listing is labelled with its scope"
STUB_PURGE_RC=1 STUB_VERIFY_RC=1 run ovh --confirm "$ID_OVH"
if [ "$(grep -c 'purge-orphans/ovh.py --apply' <<<"$OUT")" -eq 1 ]; then ok "two failing checks of one provider print its hint once"; else bad "the hint was printed $(grep -c 'purge-orphans/ovh.py --apply' <<<"$OUT") times"; fi
if grep -q -- '--apply' "$CALLS"; then bad "purge-orphans was called with --apply"; else ok "purge-orphans is only ever called as a dry-run"; fi
STUB_VERIFY_RC=1 run ovh --confirm "$ID_OVH"
expect_rc 3 "leftovers found by verify-provider-clean fail the command"
STUB_PURGE_RC=2 run ovh --confirm "$ID_OVH"
expect_rc 3 "a purge that could not check is not read as clean"
expect_out "purge-orphans/ovh.py --apply" "…and the manual command is printed too"
STUB_VERIFY_RC=2 run ovh --confirm "$ID_OVH"
expect_rc 3 "a verification that could not check is not read as clean"
STUB_PURGE_RC=1 STUB_PY_LINES=3000 run ovh --confirm "$ID_OVH"
expect_rc 3 "a long listing that ends in leftovers still fails"
expect_out "stub listing line 2999" "and the whole listing was read, not the head of it"
STUB_PY_STDERR="stub could not reach the provider" STUB_VERIFY_RC=2 run ovh --confirm "$ID_OVH"
expect_out "stub could not reach the provider" "the reason a check could not run is shown, not dropped"
for gone in verify-provider-clean.py purge-orphans/ovh.py; do
  mv "$TREE/scripts/ops/$gone" "$TREE/scripts/ops/$gone.away"
  run ovh --confirm "$ID_OVH"
  mv "$TREE/scripts/ops/$gone.away" "$TREE/scripts/ops/$gone"
  expect_rc 3 "a cloud whose $gone is missing does not end 'complete': the check that cannot run is a failure"
  refute_out "teardown-all complete" "…and no completion line"
done
fresh; tfvars outscale
STUB_PURGE_RC=1 run outscale --confirm lab-outscale-dev-outscale
expect_rc 0 "outscale: the whole-project listing is read, not gated on (its pre-fix Net, #43)"
expect_out "does not gate on them" "…and it says so"
STUB_PURGE_RC=2 run outscale --confirm lab-outscale-dev-outscale
expect_rc 3 "…but a listing that could not run is a failure"
STUB_VERIFY_RC=1 run outscale --confirm lab-outscale-dev-outscale
expect_rc 3 "…and the cluster's own check still gates"
fresh; tfvars ovh
STUB_FAIL_APPLY_ON=ovh run ovh --confirm "$ID_OVH"
expect_rc 3 "a failing destroy fails the command, with the code for a half-done teardown"
calls_are "…and the proof is skipped" "$(plan_calls ovh)" "$(apply_calls ovh)"
expect_out "skipping the proof" "it says it skipped it"
STUB_FAIL_PLAN_ON=ovh run ovh --confirm "$ID_OVH"
expect_rc 1 "a failing plan fails the command, with the code for nothing destroyed"
calls_are "…and nothing is destroyed" "$(plan_calls ovh)"

echo
echo "=== the guards are plain functions: no output, no network, no state ==="
fresh; tfvars ovh
: >"$CALLS"
# shellcheck source=/dev/null
UNIT="$(source "$SCRIPT"
  oa_require_fn teardown_guard teardown_guard_env main || exit 1
  teardown_guard "$CLUSTER/envs/management-ovh.tfvars" ovh; echo "dev rc=$? id=$GUARD_ID cluster=$GUARD_CLUSTER"
  tfvars ovh 'environment = "prod"' 2>/dev/null
  teardown_guard "$CLUSTER/envs/management-ovh.tfvars" ovh; echo "prod rc=$? why=$GUARD_WHY"
  OA_NO_TEARDOWN_ALL=1 teardown_guard_env; echo "switch rc=$? why=$GUARD_WHY")"
case "$UNIT" in
  *"dev rc=0 id=$ID_OVH cluster=lab-ovh-dev"*) ok "a dev tfvars passes and yields the cluster id" ;;
  *) bad "the dev guard answered: $UNIT" ;;
esac
case "$UNIT" in *"prod rc=1 why="*"not exactly"*) ok "a prod tfvars refuses, with its reason" ;; *) bad "the prod guard answered: $UNIT" ;; esac
case "$UNIT" in *"switch rc=1 why=the kill switch"*) ok "the kill switch refuses, with its reason" ;; *) bad "the switch answered: $UNIT" ;; esac
if [ -s "$CALLS" ]; then bad "calling the guards ran something: $(tr '\n' ';' <"$CALLS")"; else ok "and none of them ran a command"; fi

echo
echo "=== the task lane: the command it renders, and a CONFIRM it did not get from the command line ==="
LINE="$(PATH="$ORIG_PATH" "$REAL_TASK" --color=false --dry teardown-all PROVIDER=ovh CONFIRM="$ID_OVH" -- --force-no-edges 2>&1 | grep 'teardown-all.sh' | sed 's/^task: \[teardown-all\] //')"
case "$LINE" in
  "./scripts/ops/teardown-all.sh ovh --role management --confirm $ID_OVH -- --force-no-edges") ok "the rendered command is the script, with no test seam to clear" ;;
  *) bad "the task renders: $LINE" ;;
esac
# Task turns an exported CONFIRM into its own variable, so it renders as --confirm; run what it renders
# (the script swapped for the tree's copy) with that CONFIRM still exported, as a leftover one would be.
LINE="$(CONFIRM="$ID_OVH" PATH="$ORIG_PATH" "$REAL_TASK" --color=false --dry teardown-all PROVIDER=ovh 2>&1 | grep 'teardown-all.sh' | sed 's/^task: \[teardown-all\] //')"
fresh; tfvars ovh
: >"$CALLS"
OUT="$(CONFIRM="$ID_OVH" bash -c "${LINE/.\/scripts\/ops\/teardown-all.sh/$SCRIPT}" </dev/null 2>&1)"; RC=$?
needed "an exported CONFIRM that Task rendered into --confirm does not confirm a destroy" "CONFIRM is exported"
TASKOUT="$(PATH="$ORIG_PATH" "$REAL_TASK" --color=false --dry teardown-all PROVIDER=local 2>&1 || true)"
case "$TASKOUT" in *"not for this family"*) ok "PROVIDER=local is refused by the shared precondition" ;; *) bad "PROVIDER=local was not refused: $TASKOUT" ;; esac

echo
# Over EVERY run above, not the last one: what this lane may execute is the kubeconfig fetch, fleet-down
# and the two checks. No --apply, no deletion verb, no bucket, image or keypair, nothing outside the jail.
if [ "$STRAYS" -eq 0 ]; then ok "none of the $RUNS runs issued a command outside the allowed set (kubeconfig fetch, fleet-down, the dry-run purge, the verifier)"; fi
if grep -Eq -- '--apply|NOTFOUND|(^|[ /-])(rb|rm|delete|prune|s3|keypair|image)( |$)' "$ALL_CALLS"
  then bad "some run issued a deletion, an --apply or a command outside the jail: $(grep -Em3 -- '--apply|NOTFOUND|(^|[ /-])(rb|rm|delete|prune|s3|keypair|image)( |$)' "$ALL_CALLS" | tr '\n' ';')"
  else ok "across $RUNS runs: no purge --apply, no bucket, image or keypair deletion, no tofu or cloud CLI call"
fi
printf '%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
# A skip is a gap: where CI is set, it fails the run instead of passing quietly.
if [ -n "${CI:-}" ] && [ "$SKIP" -gt 0 ]; then echo "CI is set and $SKIP check(s) were skipped: a pty or a non-root user is missing" >&2; exit 1; fi
# A floor, not just a verdict: FAIL -eq 0 is also true when the harness died before asserting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
