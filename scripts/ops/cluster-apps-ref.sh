#!/usr/bin/env bash
# ==============================================================================
# cluster-apps-ref.sh keeps the apps ref (git_ref) of a LIVE cluster, the ref Flux follows and the tfvars in one piece
# (infra #408; lab 25 patched the Kustomization by hand).
#
# WHY IT EXISTS. The GitRepository `openaether` (spec.ref.name) and the Kustomization `openaether-platform` (postBuild
# substitute GIT_REF) are objects of the Talos inline manifest `flux-bootstrap`. Talos creates an inline-manifest object when
# it is missing and does not update one that exists (docs/upgrade.md "From 0.3.x to 0.4.0"; upstream source read, not yet
# shown on a node). So changing git_ref in the tfvars and running `cluster-up` does NOT move a running cluster. This is the
# command that does, and `cluster-verify` fails when the three disagree.
#
# WHAT IT DOES. Reads the declared git_ref (TF_VAR_git_ref, else the tfvars, else the default of variables.tf), the ref the
# live GitRepository follows and the live GIT_REF, and prints the three. With --apply it
#   1. rewrites git_ref in the tfvars when it differs from the wanted ref (a backup <tfvars>.apps-ref-bak is kept, the diff is shown),
#   2. merge-patches ONLY spec.ref.name of the GitRepository and ONLY postBuild.substitute.GIT_REF of the Kustomization
#      (spec.verify, the signature settings, and everything else are never written),
#   3. asks Flux to reconcile both and waits (timeout) for the GitRepository to report the revision of that ref.
# The wanted ref is --ref (task: REF=refs/tags/X), else the declared one. The ref must be refs/(heads|tags)/<name> as in
# variables.tf. A branch is a MOVING ref (Flux applies whatever lands on it, with cluster-admin): it is warned about loudly,
# and a branch given with --ref is refused unless --allow-branch.
#
# Usage: cluster-apps-ref.sh --tfvars FILE [--ref REF] [--apply] [--allow-branch] [--no-wait]
#   exit 0  the three agree (or were made to agree and Flux reports the revision)
#   exit 3  dry run found a difference (nothing written)
#   exit 4  the GitRepository or the Kustomization does not exist (Flux bootstrap not applied: nothing to move)
#   exit 2  refused: malformed ref, a branch without --allow-branch, a tfvars that cannot be rewritten safely, TF_VAR_git_ref in the way
#   exit 1  any other failure (no kubeconfig, API unreachable, patch refused, read-back differs, Flux did not report the revision in time)
# Env: OA_FLUX_NAMESPACE (flux-system), OA_REF_TIMEOUT (300 s), OA_REF_POLL (5 s). KUBECONFIG is the cluster directory's.
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
NS="${OA_FLUX_NAMESPACE:-flux-system}"
TIMEOUT="${OA_REF_TIMEOUT:-300}"; POLL="${OA_REF_POLL:-5}"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=../lib/pins.sh
source "$ROOT/scripts/lib/pins.sh"

APPLY=0; WANT_REF=""; ALLOW_BRANCH=0; WAIT=1; TFVARS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --allow-branch) ALLOW_BRANCH=1 ;;
    --no-wait) WAIT=0 ;;
    --ref) shift; WANT_REF="${1:-}" ;;
    --tfvars) shift; TFVARS="${1:-}" ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown argument: $1 (usage: cluster-apps-ref.sh --tfvars FILE [--ref REF] [--apply] [--allow-branch] [--no-wait])" >&2; exit 1 ;;
  esac
  shift
done

fail()   { echo "✗ $*" >&2; exit 1; }
refuse() { echo "✗ $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -n "$TFVARS" ] || fail "--tfvars FILE is required (task cluster-apps-ref passes envs/<ROLE>-<PROVIDER>.tfvars)"
case "$TIMEOUT$POLL" in *[!0-9]*|"") fail "OA_REF_TIMEOUT and OA_REF_POLL must be whole seconds" ;; esac

export KUBECONFIG="$CLUSTER_DIR/kubeconfig"
[ -s "$KUBECONFIG" ] || fail "no kubeconfig at infrastructure/opentofu/cluster/kubeconfig (task kubeconfig PROVIDER=… ROLE=…)"

DECLARED="$(oa_declared_git_ref "$CLUSTER_DIR" "$TFVARS")"
if [ -z "$WANT_REF" ]; then WANT_REF="$DECLARED"; FROM_TFVARS=1; else FROM_TFVARS=0; fi
[ -n "$WANT_REF" ] || fail "no git_ref is declared (TF_VAR_git_ref, $TFVARS, variables.tf) and none was given with --ref"
oa_ref_valid "$WANT_REF" || refuse "'$WANT_REF' is not a ref this repository accepts: it must be refs/tags/<name> or refs/heads/<name> (variables.tf), with letters, digits and . _ / + - only."
if [ -n "$DECLARED" ] && ! oa_ref_valid "$DECLARED"; then
  echo "~ the declared git_ref '$DECLARED' is not a valid ref (variables.tf would refuse it); it is compared as written." >&2
fi
if oa_ref_is_branch "$WANT_REF"; then
  {
    echo "⚠⚠ WARNING: $WANT_REF is a BRANCH, a MOVING ref. Flux applies whatever lands on it within the reconcile interval, with"
    echo "   cluster-admin rights, and nothing here verifies who pushed it. Pin a tag (refs/tags/<version>) on anything that is not a throwaway lab."
  } >&2
fi

ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
read_obj() { # <kind> <name> — JSON on stdout; NotFound is exit 4 of the whole script, anything else is a failure
  local out
  if ! out="$(kubectl -n "$NS" get "$1" "$2" -o json 2>"$ERR")"; then
    if grep -qi "notfound\|not found" "$ERR"; then
      echo "✗ $1 $NS/$2 does not exist: the Flux bootstrap manifest has not been applied on this cluster, so there is no ref to move." >&2
      exit 4
    fi
    fail "cannot read $1 $NS/$2: $(head -c 300 "$ERR")"
  fi
  printf '%s' "$out"
}
GR_KIND=gitrepositories.source.toolkit.fluxcd.io; KS_KIND=kustomizations.kustomize.toolkit.fluxcd.io
GR="$(read_obj "$GR_KIND" openaether)"
KS="$(read_obj "$KS_KIND" openaether-platform)"

# The ref the GitRepository follows. spec.ref.name is what the bootstrap template writes; another form (tag, branch, semver,
# commit) is shown as it is and counts as different, because this script compares names.
describe_gr() {
  jq -r '.spec.ref // {} | if .name then .name elif .tag then "tag:" + .tag elif .semver then "semver:" + .semver
         elif .branch then "branch:" + .branch elif .commit then "commit:" + .commit else "" end' <<<"$1"
}
LIVE_GR="$(describe_gr "$GR")"
LIVE_KS="$(jq -r '.spec.postBuild.substitute.GIT_REF // ""' <<<"$KS")"

echo "Apps ref (git_ref) of $NS:"
echo "  tfvars / declared     : ${DECLARED:-(none)}"
echo "  GitRepository openaether      spec.ref.name : ${LIVE_GR:-(empty)}"
echo "  Kustomization openaether-platform GIT_REF   : ${LIVE_KS:-(empty)}"
[ "$FROM_TFVARS" = 1 ] || echo "  wanted (--ref)        : $WANT_REF"

DIFFS=0
[ "$LIVE_GR" = "$WANT_REF" ] || { echo "  ~ the GitRepository follows '${LIVE_GR:-(empty)}', wanted '$WANT_REF'"; DIFFS=$((DIFFS + 1)); }
[ "$LIVE_KS" = "$WANT_REF" ] || { echo "  ~ GIT_REF is '${LIVE_KS:-(empty)}', wanted '$WANT_REF'"; DIFFS=$((DIFFS + 1)); }
TFDIFF=0
[ "$DECLARED" = "$WANT_REF" ] || { echo "  ~ the tfvars declares '${DECLARED:-(none)}', wanted '$WANT_REF'"; TFDIFF=1; DIFFS=$((DIFFS + 1)); }

if [ "$DIFFS" -eq 0 ]; then
  echo "✓ in sync: the tfvars, the GitRepository and GIT_REF all say $WANT_REF."
  exit 0
fi

if [ "$APPLY" -ne 1 ]; then
  echo "✗ $DIFFS difference(s). NOTHING was written (dry run)." >&2
  if [ "$FROM_TFVARS" = 1 ]; then
    echo "  Move the cluster to the tfvars: task cluster-apps-ref PROVIDER=… ROLE=… APPLY=1" >&2
    echo "  or keep the cluster's ref and change the tfvars to it: task cluster-apps-ref PROVIDER=… ROLE=… REF=${LIVE_GR:-refs/tags/<tag>} APPLY=1" >&2
  else
    echo "  Apply: task cluster-apps-ref PROVIDER=… ROLE=… REF=$WANT_REF APPLY=1" >&2
  fi
  exit 3
fi

# --- --apply: every refusal comes BEFORE the first write ---------------------------------------------------------------
if oa_ref_is_branch "$WANT_REF" && [ "$FROM_TFVARS" = 0 ] && [ "$ALLOW_BRANCH" -ne 1 ]; then
  refuse "REF=$WANT_REF is a branch and a branch was not already the declared ref: refused. A branch moves under Flux. Pin a tag, or say you mean it (ALLOW_BRANCH=1)."
fi
if [ "$TFDIFF" = 1 ]; then
  if [ -n "${TF_VAR_git_ref:-}" ]; then
    refuse "TF_VAR_git_ref is set in this shell and wins over the tfvars: this script cannot change an environment variable. Unset it, then run again."
  fi
  [ -f "$TFVARS" ] || refuse "$TFVARS does not exist, so git_ref cannot be written there."
  rc=0; tfv_strict "$TFVARS" git_ref >/dev/null || rc=$?
  if [ "$rc" = 2 ]; then
    refuse "git_ref in $TFVARS is not a plain top-level quoted string (indented, repeated, in a heredoc or a comment block): it is not rewritten here. Edit it by hand to $WANT_REF, then run again."
  fi
fi

# 1. The tfvars. Backup first; show exactly what changed; read it back.
if [ "$TFDIFF" = 1 ]; then
  BAK="${TFVARS}.apps-ref-bak"
  cp -p "$TFVARS" "$BAK"
  if tfv_strict "$TFVARS" git_ref >/dev/null; then
    sed -i -E "s|^(git_ref[[:space:]]*=[[:space:]]*)\"[^\"]*\"|\1\"${WANT_REF}\"|" "$TFVARS"
  else
    printf '\ngit_ref = "%s"\n' "$WANT_REF" >>"$TFVARS"
  fi
  echo "tfvars changed (backup: $BAK):"
  diff -u "$BAK" "$TFVARS" | sed 's/^/  /' || true
  [ "$(tfv_strict "$TFVARS" git_ref || true)" = "$WANT_REF" ] || { cp -p "$BAK" "$TFVARS"; fail "git_ref in $TFVARS does not read back as $WANT_REF after the rewrite; the file was restored from the backup."; }
fi

# 2. The two live objects. Only the field each one owns; a merge patch leaves every other field (spec.verify included) alone.
restore_tfvars() { [ "$TFDIFF" = 1 ] && [ -f "${TFVARS}.apps-ref-bak" ] && cp -p "${TFVARS}.apps-ref-bak" "$TFVARS" && echo "  the tfvars was restored from ${TFVARS}.apps-ref-bak" >&2 || true; }
if [ "$LIVE_KS" != "$WANT_REF" ]; then
  P="$(jq -nc --arg r "$WANT_REF" '{spec: {postBuild: {substitute: {GIT_REF: $r}}}}')"
  kubectl -n "$NS" patch "$KS_KIND" openaether-platform --type merge -p "$P" >/dev/null 2>"$ERR" || { m="$(head -c 300 "$ERR")"; restore_tfvars; fail "patch of the Kustomization refused: $m"; }
fi
if [ "$LIVE_GR" != "$WANT_REF" ]; then
  P="$(jq -nc --arg r "$WANT_REF" '{spec: {ref: {name: $r}}}')"
  kubectl -n "$NS" patch "$GR_KIND" openaether --type merge -p "$P" >/dev/null 2>"$ERR" || { m="$(head -c 300 "$ERR")"; fail "patch of the GitRepository refused: $m (the Kustomization may already carry the new GIT_REF; run again or: task cluster-apps-ref … REF=<previous ref> APPLY=1)"; }
fi

# 3. Read back: applied means the cluster holds the values.
GR="$(read_obj "$GR_KIND" openaether)"; KS="$(read_obj "$KS_KIND" openaether-platform)"
[ "$(describe_gr "$GR")" = "$WANT_REF" ] && [ "$(jq -r '.spec.postBuild.substitute.GIT_REF // ""' <<<"$KS")" = "$WANT_REF" ] \
  || fail "the live objects still differ from $WANT_REF after the patch (something else rewrites them?). Read: kubectl -n $NS get gitrepository,kustomization"
echo "✓ GitRepository openaether and Kustomization openaether-platform now say $WANT_REF (read back)."

# 4. Reconcile now, then wait for the revision of THAT ref.
TS="$(date +%s)"
kubectl -n "$NS" annotate "$GR_KIND" openaether --overwrite "reconcile.fluxcd.io/requestedAt=$TS" >/dev/null 2>"$ERR" \
  || echo "⚠ the reconcile request on the GitRepository failed ($(head -c 200 "$ERR")); Flux picks the ref up at its next interval." >&2
kubectl -n "$NS" annotate "$KS_KIND" openaether-platform --overwrite "reconcile.fluxcd.io/requestedAt=$TS" >/dev/null 2>>"$ERR" \
  || echo "⚠ the reconcile request on the Kustomization failed; Flux picks the ref up at its next interval." >&2

if [ "$WAIT" -ne 1 ]; then
  echo "~ --no-wait: not waiting for Flux. Watch: kubectl -n $NS get gitrepository openaether"
  exit 0
fi

SHORT="${WANT_REF#refs/heads/}"; SHORT="${SHORT#refs/tags/}"
deadline=$((SECONDS + TIMEOUT)); last=""
while :; do
  if GRJ="$(kubectl -n "$NS" get "$GR_KIND" openaether -o json 2>/dev/null)"; then
    rev="$(jq -r '.status.artifact.revision // ""' <<<"$GRJ")"
    ready="$(jq -r '[.status.conditions[]? | select(.type == "Ready")][0] | "\(.status // "?") \(.message // "")"' <<<"$GRJ")"
    seen="$(jq -r '(.status.observedGeneration // -1) == (.metadata.generation // 0)' <<<"$GRJ")"
    last="revision '${rev:-none}', Ready: ${ready}"
    if [ "$seen" = true ] && [[ "$ready" == True* ]] && { [[ "$rev" == "$WANT_REF@"* ]] || [[ "$rev" == "$SHORT@"* ]]; }; then
      echo "✓ Flux reports the revision of $WANT_REF: $rev"
      exit 0
    fi
  else
    last="the GitRepository could not be read"
  fi
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep "$POLL"
done
echo "✗ after ${TIMEOUT}s the GitRepository does not report the revision of $WANT_REF (last seen: $last)." >&2
echo "  The ref is written in the tfvars and on both live objects. Likely: the tag or branch does not exist, or the repository is unreachable." >&2
echo "  Read: kubectl -n $NS describe gitrepository openaether   Revert: task cluster-apps-ref … REF=<previous ref> APPLY=1" >&2
exit 1
