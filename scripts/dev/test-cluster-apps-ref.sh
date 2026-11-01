#!/usr/bin/env bash
# ==============================================================================
# cluster-apps-ref.sh (infra #408): the apps ref of a live cluster, the two Flux objects and the tfvars are brought together,
# and nothing else is touched.
#
# The real script runs in a throwaway copy of the layout. kubectl is a stub that keeps the GitRepository and the Kustomization
# in JSON files, applies a merge patch with jq, and (unless told not to) makes Flux "report" the revision after a patch, so the
# wait is exercised. What a real Flux reports (the exact revision string for ref.name, the timing) is an assumption taken from
# the Flux API docs; nothing here measures a cluster. Offline, no credentials.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

SCRIPT=scripts/ops/cluster-apps-ref.sh
[ -f "$SCRIPT" ] || { echo "✗ $SCRIPT does not exist — nothing was checked" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }
BASH_BIN="$(command -v bash)"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"; FX="$W/fx"
mkdir -p "$C/envs" "$W/scripts/ops" "$W/scripts/lib" "$W/bin" "$FX"
cp "$SCRIPT" "$W/scripts/ops/"; cp scripts/lib/common.sh scripts/lib/pins.sh "$W/scripts/lib/"
A="$W/scripts/ops/cluster-apps-ref.sh"
echo "apiVersion: v1" >"$C/kubeconfig"
TFV="$C/envs/management-stub.tfvars"
printf 'variable "git_ref" {\n  default = "refs/tags/0.0.1"\n}\n' >"$C/variables.tf"

OLD=refs/tags/0.3.2; NEW=refs/tags/0.4.0
GR_JSON='{"metadata":{"name":"openaether","generation":3},"spec":{"url":"https://example.invalid/apps.git","ref":{"name":"refs/tags/0.3.2"},"verify":{"mode":"HEAD","secretRef":{"name":"git-signers"}}},"status":{"observedGeneration":3,"conditions":[{"type":"Ready","status":"True","message":"stored artifact"}],"artifact":{"revision":"refs/tags/0.3.2@sha1:aaa"}}}'
KS_JSON='{"metadata":{"name":"openaether-platform"},"spec":{"path":"./apps/flux/management","postBuild":{"substitute":{"GIT_REF":"refs/tags/0.3.2","OTHER":"keep"}}}}'

cat >"$W/stub" <<STUB
#!/usr/bin/env bash
echo "kubectl \$*" >>"$W/calls.log"
echo "\$KUBECONFIG" >>"$W/kubeconfig.seen"
[ -f "$FX/api.rc" ] && { echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit 1; }
f=""; case "\$*" in *gitrepositories*) f="$FX/gr.json" ;; *kustomizations*) f="$FX/ks.json" ;; esac
case "\$3" in
  get)
    [ -f "\$f" ] || { echo 'Error from server (NotFound): not found' >&2; exit 1; }
    cat "\$f" ;;
  patch)
    p=""; prev=""; for a; do [ "\$prev" = -p ] && p="\$a"; prev="\$a"; done
    echo "PATCH \$p" >>"$W/patches.log"
    [ -f "$FX/patch.rc" ] && { echo "forbidden" >&2; exit 1; }
    [ -f "$FX/noop-patch" ] && exit 0
    jq -c --argjson p "\$p" '. * \$p' "\$f" >"\$f.new" && mv "\$f.new" "\$f"
    if [ "\$f" = "$FX/gr.json" ] && [ ! -f "$FX/never-ready" ]; then
      n="\$(jq -r .spec.ref.name "\$f")"
      jq -c --arg r "\$n@sha1:bbb" '.metadata.generation += 1 | .status.observedGeneration = .metadata.generation | .status.artifact.revision = \$r' "\$f" >"\$f.new" && mv "\$f.new" "\$f"
    fi ;;
  annotate) exit 0 ;;
  *) echo "UNEXPECTED \$*" >>"$W/calls.log"; exit 99 ;;
esac
STUB
chmod +x "$W/stub"; ln -s "$W/stub" "$W/bin/kubectl"

reset() {
  rm -rf "$FX"; mkdir -p "$FX"; : >"$W/calls.log"; : >"$W/patches.log"; : >"$W/kubeconfig.seen"
  printf '%s' "$GR_JSON" >"$FX/gr.json"; printf '%s' "$KS_JSON" >"$FX/ks.json"
  rm -f "$TFV".*
  printf '# cluster\ngit_ref            = "%s"   # apps\nother = "x"\n' "${1:-$OLD}" >"$TFV"
}
run() { ( cd "$C" && env -i PATH="$W/bin:$PATH" HOME="$W" KUBECONFIG=/nonexistent/other ${EXTRA:-} OA_REF_TIMEOUT=2 OA_REF_POLL=1 "$BASH_BIN" "$A" --tfvars "$TFV" "$@" ) </dev/null >"$W/out" 2>"$W/err"; }
calls() { grep -c "$1" "$W/calls.log"; }
said() { grep -qF -- "$1" "$W/out" "$W/err"; }
grref() { jq -r '.spec.ref.name' "$FX/gr.json"; }
ksref() { jq -r '.spec.postBuild.substitute.GIT_REF' "$FX/ks.json"; }
tfref() { sed -nE 's/^git_ref[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$TFV"; }
nowrites() { [ ! -s "$W/patches.log" ] && [ "$(calls annotate)" = 0 ]; }

echo "--- in sync: the three agree, nothing is written ---"
reset; run; rc=$?
[ "$rc" = 0 ] && said "in sync" && nowrites && ok "exit 0, no patch, no annotate" || bad "rc $rc"
[ -s "$W/kubeconfig.seen" ] && ! grep -qv "^$C/kubeconfig\$" "$W/kubeconfig.seen" && ok "the cluster directory's kubeconfig is used, not the caller's" || bad "kubeconfig: $(tr '\n' ' ' <"$W/kubeconfig.seen")"

echo "--- mutation: each of the three differing alone FAILS the dry run (exit 3) and writes nothing ---"
reset; jq -c '.spec.ref.name = "refs/tags/9.9.9"' "$FX/gr.json" >"$FX/x" && mv "$FX/x" "$FX/gr.json"; run; rc=$?
[ "$rc" = 3 ] && said "the GitRepository follows 'refs/tags/9.9.9'" && said "task cluster-apps-ref" && nowrites && ok "live GitRepository differs from the tfvars: exit 3 with the command" || bad "rc $rc: $(cat "$W/out" "$W/err")"
reset; jq -c '.spec.postBuild.substitute.GIT_REF = "refs/tags/9.9.9"' "$FX/ks.json" >"$FX/x" && mv "$FX/x" "$FX/ks.json"; run; rc=$?
[ "$rc" = 3 ] && said "GIT_REF is 'refs/tags/9.9.9'" && nowrites && ok "live GIT_REF differs from the tfvars: exit 3" || bad "rc $rc"
reset "$NEW"; run; rc=$?
[ "$rc" = 3 ] && said "the GitRepository follows 'refs/tags/0.3.2', wanted 'refs/tags/0.4.0'" && nowrites && ok "tfvars ahead of the cluster: exit 3" || bad "rc $rc"
reset; jq -c 'del(.spec.ref) | .spec.ref = {"tag":"0.3.2"}' "$FX/gr.json" >"$FX/x" && mv "$FX/x" "$FX/gr.json"; run; rc=$?
[ "$rc" = 3 ] && said "tag:0.3.2" && ok "another ref form on the GitRepository is shown and counts as different" || bad "rc $rc"

echo "--- the tfvars default is read when the key is absent ---"
reset; printf 'other = "x"\n' >"$TFV"; run; rc=$?
[ "$rc" = 3 ] && said "refs/tags/0.0.1" && ok "variables.tf default is the declared ref" || bad "rc $rc"

echo "--- APPLY with REF: tfvars (backup, diff), both objects, reconcile, wait for the revision ---"
reset; run --apply --ref "$NEW"; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "rc $rc: $(cat "$W/err")"
[ "$(tfref)" = "$NEW" ] && grep -q '^other = "x"' "$TFV" && grep -q '# apps' "$TFV" && ok "git_ref rewritten in the tfvars, the rest and the comment kept" || bad "tfvars: $(cat "$TFV")"
[ -f "$TFV.apps-ref-bak" ] && grep -q "$OLD" "$TFV.apps-ref-bak" && said "-git_ref" && said "+git_ref" && ok "a backup is kept and the diff is shown" || bad "no backup or no diff"
[ "$(grref)" = "$NEW" ] && [ "$(ksref)" = "$NEW" ] && ok "both live objects carry the new ref" || bad "gr $(grref) ks $(ksref)"
[ "$(jq -r '.spec.postBuild.substitute.OTHER' "$FX/ks.json")" = keep ] && [ "$(jq -r '.spec.verify.mode' "$FX/gr.json")" = HEAD ] && [ "$(jq -r '.spec.url' "$FX/gr.json")" != null ] \
  && ok "other substitutes, spec.verify and the url are untouched" || bad "collateral change"
! grep -qi 'verify' "$W/patches.log" && [ "$(grep -c PATCH "$W/patches.log")" = 2 ] && ok "two patches, neither mentions verify" || bad "patches: $(cat "$W/patches.log")"
[ "$(calls annotate)" = 2 ] && said "Flux reports the revision of $NEW" && ok "reconcile requested on both, the revision is waited for" || bad "annotate $(calls annotate)"
run --apply --ref "$NEW"; rc=$?
{ [ "$rc" = 0 ] && said "in sync"; } && ok "idempotent: a second apply finds nothing to do" || bad "second run rc $rc"

echo "--- APPLY without REF: the cluster is moved to the tfvars ---"
reset "$NEW"; run --apply; rc=$?
[ "$rc" = 0 ] && [ "$(grref)" = "$NEW" ] && [ "$(ksref)" = "$NEW" ] && [ ! -f "$TFV.apps-ref-bak" ] && ok "live objects follow the tfvars; the tfvars is not rewritten" || bad "rc $rc gr $(grref) ks $(ksref)"
reset; jq -c '.spec.ref.name = "refs/tags/9.9.9"' "$FX/gr.json" >"$FX/x" && mv "$FX/x" "$FX/gr.json"; run --apply; rc=$?
[ "$rc" = 0 ] && [ "$(grref)" = "$OLD" ] && [ "$(grep -c PATCH "$W/patches.log")" = 1 ] && ok "only the object that differs is patched" || bad "rc $rc patches $(grep -c PATCH "$W/patches.log")"

echo "--- the wait has a timeout and a clear failure ---"
reset; : >"$FX/never-ready"; run --apply --ref "$NEW"; rc=$?
[ "$rc" = 1 ] && said "does not report the revision of $NEW" && said "Revert: task cluster-apps-ref" && ok "Flux never reports: exit 1 with the last state and the way back" || bad "rc $rc: $(cat "$W/err")"
reset; : >"$FX/never-ready"; run --apply --ref "$NEW" --no-wait; rc=$?
[ "$rc" = 0 ] && said "not waiting" && ok "--no-wait skips the wait" || bad "rc $rc"

echo "--- a branch: warned loudly; as REF it is refused without ALLOW ---"
reset; run --apply --ref refs/heads/main; rc=$?
[ "$rc" = 2 ] && nowrites && [ "$(tfref)" = "$OLD" ] && said "WARNING" && said "MOVING" && ok "REF=branch refused (exit 2) with the warning, nothing written" || bad "rc $rc"
reset; run --ref refs/heads/main; rc=$?
[ "$rc" = 3 ] && said "BRANCH" && ok "the dry run of a branch warns too" || bad "rc $rc"
reset; run --apply --ref refs/heads/lab/x --allow-branch; rc=$?
[ "$rc" = 0 ] && said "WARNING" && [ "$(grref)" = refs/heads/lab/x ] && ok "--allow-branch: warned and applied" || bad "rc $rc"
reset refs/heads/lab/x; run --apply; rc=$?
[ "$rc" = 0 ] && said "WARNING" && [ "$(ksref)" = refs/heads/lab/x ] && ok "a branch already declared in the tfvars: warned, applied" || bad "rc $rc"

echo "--- malformed refs are refused before any call that writes ---"
for r in main "refs/tags/" "refs/tags/a b" "refs/tags/x'y" 'refs/tags/$(id)' "refs/heads/../x" "refs/remotes/o/x" "tags/0.4.0" "refs/tags/0.4.0\"" ; do
  reset; run --apply --ref "$r"; rc=$?
  [ "$rc" = 2 ] && nowrites && [ "$(tfref)" = "$OLD" ] || bad "'$r' was not refused (rc $rc)"
done
ok "main, empty tag, space, quote, command substitution, .., refs/remotes, no refs/, trailing quote: all refused (exit 2), nothing written"

echo "--- other refusals and failures ---"
reset; EXTRA=TF_VAR_git_ref=$OLD run --apply --ref "$NEW"; rc=$?
[ "$rc" = 2 ] && nowrites && said "TF_VAR_git_ref" && ok "TF_VAR_git_ref in the way: refused, nothing written" || bad "rc $rc"
reset; printf 'x = {\n  git_ref = "%s"\n}\n' "$OLD" >"$TFV"; run --apply --ref "$NEW"; rc=$?
[ "$rc" = 2 ] && nowrites && said "not a plain top-level" && ok "an indented git_ref is not rewritten: refused before the cluster is touched" || bad "rc $rc"
reset; rm -f "$FX/gr.json"; run --apply; rc=$?
[ "$rc" = 4 ] && nowrites && ok "no GitRepository: exit 4, nothing created" || bad "rc $rc"
reset; : >"$FX/api.rc"; run --apply; rc=$?
[ "$rc" = 1 ] && nowrites && said "cannot read" && ok "API unreachable is not NotFound: exit 1" || bad "rc $rc"
reset; : >"$FX/patch.rc"; run --apply --ref "$NEW"; rc=$?
[ "$rc" = 1 ] && said "refused" && [ "$(tfref)" = "$OLD" ] && ok "a refused patch fails (exit 1) and the tfvars is restored" || bad "rc $rc tfvars $(tfref)"
reset; : >"$FX/noop-patch"; run --apply --ref "$NEW"; rc=$?
[ "$rc" = 1 ] && said "still differ" && ok "a patch that did not land is caught by the read-back" || bad "rc $rc"
reset; rm -f "$C/kubeconfig"; run; rc=$?
[ "$rc" = 1 ] && said "no kubeconfig" && ok "no kubeconfig: exit 1" || bad "rc $rc"
echo "apiVersion: v1" >"$C/kubeconfig"
reset; run --bogus; rc=$?
[ "$rc" = 1 ] && ok "unknown argument: exit 1" || bad "rc $rc"
reset; ( cd "$C" && env -i PATH="$W/bin:$PATH" HOME="$W" "$BASH_BIN" "$A" ) </dev/null >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" = 1 ] && said "--tfvars" && ok "no --tfvars: exit 1" || bad "rc $rc"

echo
echo "cluster-apps-ref: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
