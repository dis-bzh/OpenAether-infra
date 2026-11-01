#!/usr/bin/env bash
# ==============================================================================
# cluster-identity-sync.sh (lab 25, D9): the live ConfigMap is brought to what OpenTofu renders, and nothing else.
#
# The real script runs in a throwaway copy of the repository layout. tofu and kubectl are ONE stub: tofu answers the
# `cluster_identity` output from a fixture; kubectl keeps the ConfigMap in a JSON file, applies a merge patch with jq, and
# logs every call, so "dry run writes nothing", "only the rendered keys are patched" and "second run changes nothing" are
# asserted on the log and on the file. What a real apiserver answers for NotFound is an assumption (its message text);
# nothing here measures a cluster.
#
# Offline, no credentials, no cluster.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

SCRIPT=scripts/ops/cluster-identity-sync.sh
[ -f "$SCRIPT" ] || { echo "✗ $SCRIPT does not exist — nothing was checked" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }
BASH_BIN="$(command -v bash)"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"; FX="$W/fx"
mkdir -p "$C" "$W/scripts/ops" "$W/bin" "$FX"
cp "$SCRIPT" "$W/scripts/ops/"
A="$W/scripts/ops/cluster-identity-sync.sh"
echo "apiVersion: v1" >"$C/kubeconfig"

WANT_FULL='{"CLUSTER_NAME":"c-dev-ovh","BACKUP_TARGET_URL":"s3://data-bkt@eu-west-par/","BACKUP_S3_BUCKET":"data-bkt","BACKUP_S3_ENDPOINT":"https://s3.example.invalid","BACKUP_REPLICA_S3_BUCKET":"data-bkt-backup","BACKUP_REPLICA_S3_ENDPOINT":"https://s3r.example.invalid","AUDIT_SINK_HOST":"audit.example.invalid"}'
OLD_CM='{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"cluster-identity","namespace":"flux-system","labels":{"openaether.io/managed":"true"}},"data":{"CLUSTER_NAME":"c-dev-ovh","BACKUP_TARGET_URL":"s3://data-bkt@eu-west-par/","BACKUP_S3_BUCKET":"data-bkt","BACKUP_S3_ENDPOINT":"https://s3.example.invalid","LOCAL_ONLY":"keep-me"}}'

cat >"$W/stub" <<STUB
#!/usr/bin/env bash
n="\$(basename "\$0")"
echo "\$n \$*" >>"$W/calls.log"
[ "\$n" = kubectl ] && echo "\$KUBECONFIG" >>"$W/kubeconfig.seen"
case "\$n \$1 \$2 \$3 \$4" in
  "tofu output -json cluster_identity"*) [ -f "$FX/tofu.rc" ] && { echo "Error: no state" >&2; exit 1; }; cat "$FX/want.json" ;;
  "kubectl -n flux-system get configmap")
    [ -f "$FX/cm.json" ] || { echo 'Error from server (NotFound): configmaps "cluster-identity" not found' >&2; exit 1; }
    [ -f "$FX/get.rc" ] && { echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit 1; }
    cat "$FX/cm.json" ;;
  "kubectl -n flux-system patch configmap")
    [ -f "$FX/patch.rc" ] && { echo "forbidden" >&2; exit 1; }
    p=""; prev=""; for a; do [ "\$prev" = -p ] && p="\$a"; prev="\$a"; done
    [ -f "$FX/noop-patch" ] && exit 0
    jq -c --argjson p "\$p" '.data += \$p.data' "$FX/cm.json" >"$FX/cm.new" && mv "$FX/cm.new" "$FX/cm.json" ;;
  "kubectl -n flux-system annotate kustomizations.kustomize.toolkit.fluxcd.io") [ -f "$FX/annotate.rc" ] && exit 1; exit 0 ;;
  *) echo "UNEXPECTED \$n \$*" >>"$W/calls.log"; exit 99 ;;
esac
STUB
chmod +x "$W/stub"; ln -s "$W/stub" "$W/bin/tofu"; ln -s "$W/stub" "$W/bin/kubectl"

reset() { rm -rf "$FX"; mkdir -p "$FX"; : >"$W/calls.log"; : >"$W/kubeconfig.seen"; printf '%s' "$WANT_FULL" >"$FX/want.json"; printf '%s' "$OLD_CM" >"$FX/cm.json"; }
run() { ( cd "$C" && env -i PATH="$W/bin:$PATH" HOME="$W" KUBECONFIG=/nonexistent/other-cluster "$BASH_BIN" "$A" "$@" ) </dev/null >"$W/out" 2>"$W/err"; }
calls() { grep -c "$1" "$W/calls.log"; }
said() { grep -qF -- "$1" "$W/out" "$W/err"; }
data() { jq -r ".data.$1 // \"ABSENT\"" "$FX/cm.json"; }

echo "--- dry run on a 0.3.x ConfigMap: shows the three missing keys, writes nothing ---"
reset; run; rc=$?
[ "$rc" = 3 ] && ok "exit 3 (drift found)" || bad "rc $rc"
said "+ BACKUP_REPLICA_S3_ENDPOINT = https://s3r.example.invalid" && said "+ BACKUP_REPLICA_S3_BUCKET = data-bkt-backup" && said "+ AUDIT_SINK_HOST = audit.example.invalid" \
  && ok "each missing key is listed with its value" || bad "diff: $(cat "$W/out")"
said "= LOCAL_ONLY is not in the rendered map; left as it is" && ok "a live key the map lacks is reported and kept" || bad "no LOCAL_ONLY line"
said "NOTHING was written" && ok "it says nothing was written" || bad "no such line"
[ "$(calls 'patch')" = 0 ] && [ "$(calls 'annotate')" = 0 ] && ok "no patch, no annotate" || bad "calls: $(tr '\n' '|' <"$W/calls.log")"
[ "$(data BACKUP_REPLICA_S3_ENDPOINT)" = ABSENT ] && ok "the ConfigMap is as it was" || bad "dry run changed the ConfigMap"
[ -s "$W/kubeconfig.seen" ] && ! grep -qv "^$C/kubeconfig\$" "$W/kubeconfig.seen" \
  && ok "kubectl used the cluster directory's kubeconfig, not the caller's KUBECONFIG" || bad "kubeconfig seen: $(tr '\n' ' ' <"$W/kubeconfig.seen")"

echo "--- --apply: only the rendered keys are patched, others kept, read back, Flux asked ---"
reset; run --apply; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "rc $rc: $(cat "$W/err")"
[ "$(data BACKUP_REPLICA_S3_BUCKET)" = data-bkt-backup ] && [ "$(data BACKUP_REPLICA_S3_ENDPOINT)" = https://s3r.example.invalid ] && [ "$(data AUDIT_SINK_HOST)" = audit.example.invalid ] \
  && ok "the three keys are on the cluster" || bad "data: $(jq -c .data "$FX/cm.json")"
[ "$(data LOCAL_ONLY)" = keep-me ] && [ "$(jq -r '.metadata.labels["openaether.io/managed"]' "$FX/cm.json")" = true ] \
  && ok "a key and a label the map does not own are untouched" || bad "collateral change"
[ "$(calls 'patch')" = 1 ] && [ "$(grep -c -- '--type merge' "$W/calls.log")" = 1 ] && ok "one merge patch" || bad "calls: $(tr '\n' '|' <"$W/calls.log")"
! grep -E '^kubectl .*(delete|replace|create|apply)' "$W/calls.log" >/dev/null && ok "no delete, replace, create or apply" || bad "forbidden verb used"
[ "$(calls 'annotate')" = 1 ] && grep -q 'reconcile.fluxcd.io/requestedAt=' "$W/calls.log" && ok "Flux is asked to reconcile" || bad "no reconcile request"

echo "--- second --apply: in sync, nothing written ---"
: >"$W/calls.log"; run --apply; rc=$?
[ "$rc" = 0 ] && said "in sync" && [ "$(calls 'patch')" = 0 ] && [ "$(calls 'annotate')" = 0 ] \
  && ok "idempotent: exit 0, no patch, no annotate" || bad "rc $rc, calls: $(tr '\n' '|' <"$W/calls.log")"

echo "--- a changed value is reported as old -> new and fixed ---"
reset; jq -c '.data.BACKUP_S3_ENDPOINT = "https://old.example.invalid"' "$FX/cm.json" >"$FX/x" && mv "$FX/x" "$FX/cm.json"
run; said "~ BACKUP_S3_ENDPOINT: https://old.example.invalid -> https://s3.example.invalid" && ok "dry run shows old -> new" || bad "diff: $(cat "$W/out")"
run --apply; [ "$(data BACKUP_S3_ENDPOINT)" = https://s3.example.invalid ] && ok "--apply fixes it" || bad "not fixed"

echo "--- --no-reconcile: written, no annotate ---"
reset; run --apply --no-reconcile; rc=$?
[ "$rc" = 0 ] && [ "$(calls 'annotate')" = 0 ] && [ "$(data AUDIT_SINK_HOST)" = audit.example.invalid ] && ok "no reconcile request" || bad "rc $rc"

echo "--- a failed reconcile request is a warning, not a failure ---"
reset; : >"$FX/annotate.rc"; run --apply; rc=$?
[ "$rc" = 0 ] && said "reconcile request failed" && ok "exit 0 with a warning" || bad "rc $rc"

echo "--- deploy_flux off: empty output, nothing to do ---"
reset; echo '{}' >"$FX/want.json"; run --apply; rc=$?
[ "$rc" = 0 ] && said "Nothing to do" && [ "$(calls 'kubectl')" = 0 ] && ok "exit 0 and the cluster is not even asked" || bad "rc $rc"

echo "--- failures are never read as success ---"
reset; : >"$FX/tofu.rc"; run --apply; rc=$?
[ "$rc" = 1 ] && [ "$(calls 'kubectl')" = 0 ] && ok "tofu output fails: exit 1, cluster untouched" || bad "rc $rc"
reset; echo '"not a map"' >"$FX/want.json"; run --apply; rc=$?
[ "$rc" = 1 ] && [ "$(calls 'patch')" = 0 ] && ok "an output that is not a map of strings: exit 1" || bad "rc $rc"
reset; rm -f "$FX/cm.json"; run --apply; rc=$?
[ "$rc" = 4 ] && [ "$(calls 'patch')" = 0 ] && ok "ConfigMap missing: exit 4, nothing created" || bad "rc $rc"
reset; : >"$FX/get.rc"; run --apply; rc=$?
[ "$rc" = 1 ] && [ "$(calls 'patch')" = 0 ] && said "cannot read" && ok "API unreachable is not NotFound: exit 1" || bad "rc $rc"
reset; : >"$FX/patch.rc"; run --apply; rc=$?
[ "$rc" = 1 ] && said "patch refused" && ok "patch refused: exit 1" || bad "rc $rc"
reset; : >"$FX/noop-patch"; run --apply; rc=$?
[ "$rc" = 1 ] && said "still differs" && ok "a patch that did not land is caught by the read-back: exit 1" || bad "rc $rc"
reset; rm -f "$C/kubeconfig"; run; rc=$?
[ "$rc" = 1 ] && said "no kubeconfig" && ok "no kubeconfig: exit 1" || bad "rc $rc"
echo "apiVersion: v1" >"$C/kubeconfig"
reset; run --bogus; rc=$?
[ "$rc" = 1 ] && ok "unknown argument: exit 1" || bad "rc $rc"

echo "--- nothing secret is printed ---"
reset; run --apply
! grep -qiE 'secret|password|token|AKIA|BEGIN' "$W/out" "$W/err" && ok "no secret-looking text in the output" || bad "output has secret-looking text"

echo
echo "cluster-identity-sync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
