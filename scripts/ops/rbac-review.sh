#!/usr/bin/env bash
# ==============================================================================
# rbac-review.sh — who can do what, as a dated file a human reads (ANSSI/NSA hardening AUTH-03)
#
# Lists every (Cluster)RoleBinding with its subjects, writes it to rbac-review-<UTC date>.tsv, and FLAGS:
#   HUMAN  a User or Group subject that is not a built-in system: identity. The shared admin kubeconfig is a
#          system:masters certificate; named people come through kubeconfig-new.sh and the two bindings of the apps
#          platform-rbac brick (oa-admins -> cluster-admin for Group oa:admins, oa-readers -> view for Group oa:readers),
#          which are the only ones not flagged. Any other such binding is a new decision or something to remove
#   ANON   system:anonymous or system:unauthenticated bound to anything
#   ADMIN  cluster-admin granted by a binding outside the allowlist below
# Exit 1 when anything is flagged. READ-ONLY: kubectl get, and one file written locally.
#
# The filter is scripts/ops/rbac-review.jq (in the repository, not downloaded: no new dependency to pin).
# The allowlist is the one of cluster-security-tests.sh 3.7: cluster-admin and cluster-reconciler (Flux) plus
# the vendor prefixes. Review it at every staff change: docs/admin-access.md, "Review at staff change".
#
# Usage:  rbac-review.sh [outdir]       (default: ./rbac-review, gitignored)
#         task rbac-review
# ==============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${1:-rbac-review}"
ALLOW='{"exact":["cluster-admin","cluster-reconciler"],"prefixes":["system:","cnpg-","external-secrets-","longhorn-","istio-","cert-manager-","kyverno-","capi-","cluster-api-"]}'

for t in kubectl jq; do command -v "$t" >/dev/null 2>&1 || { echo "✗ $t not found" >&2; exit 2; }; done
json="$(timeout 120 kubectl get clusterrolebinding,rolebinding -A -o json 2>/dev/null)" \
  || { echo "✗ kubectl could not list the bindings — check KUBECONFIG" >&2; exit 2; }
# `kubectl get a,b -o json` wraps both kinds in one List; an empty one is a broken answer, not a clean cluster.
[ "$(jq '.items | length' <<<"$json" 2>/dev/null || echo 0)" -gt 0 ] || { echo "✗ no binding returned — refusing to call that a clean review" >&2; exit 2; }

mkdir -p "$OUTDIR"
OUT="$OUTDIR/rbac-review-$(date -u +%F).tsv"
{
  printf 'scope\tnamespace\tbinding\trole\tsubject_kind\tsubject\tverdict\n'
  jq -r --argjson allow "$ALLOW" -f "$HERE/rbac-review.jq" <<<"$json" | LC_ALL=C sort
} >"$OUT" || { echo "✗ the filter failed" >&2; exit 2; }

total=$(($(wc -l <"$OUT") - 1))
flagged="$(awk -F'\t' 'NR > 1 && $7 != "-"' "$OUT")"
echo "▶ RBAC review: ${total} (binding, subject) line(s) written to ${OUT}"
if [ -z "$flagged" ]; then
  echo "  ✓ nothing flagged: no named User/Group, no anonymous binding, no cluster-admin outside the allowlist"
  exit 0
fi
echo "  ✗ flagged:"
awk -F'\t' '{printf "    [%s] %s binding %s%s -> %s %s (%s)\n", $7, $1, ($2 == "-" ? "" : $2 "/"), $3, $4, $6, $5}' <<<"$flagged"
echo "  Decide each one: keep it (record why in the review), or delete the binding."
exit 1
