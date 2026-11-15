#!/usr/bin/env bash
# A release tag must be an ANNOTATED tag, SIGNED by a key of the signer table (docs/signed-commits.md, machine-readable
# in docs/signers/signers.txt). Verified against the public keys stored next to the table in a throwaway keyring, never the
# caller's. Prints the release commit SHA, which the release notes must carry so a client can compare it
# (`git verify-tag` + `git rev-parse <tag>^{commit}`). Exit 0 ok, 1 refused, 2 usage / cannot check.
#
# Usage: check-release-tag.sh <tag> [--signers-dir docs/signers] [--notes <file> [--apps-sha <sha>]]
#   --notes: the release notes file; refused unless it names the full release commit SHA.
#   --apps-sha: the full commit SHA of the OpenAether-apps tag that git_ref pins; the notes must name it too, so a client
#               can check both repositories (infra #385: a tag alone can be force-replaced upstream).
set -uo pipefail

tag="${1:-}"; shift || true
dir="docs/signers"; notes=""; apps_sha=""
while [ $# -gt 0 ]; do
  case "$1" in
    --signers-dir) dir="${2:-}"; shift 2 ;;
    --notes) notes="${2:-}"; shift 2 ;;
    --apps-sha) apps_sha="${2:-}"; shift 2 ;;
    *) echo "usage: check-release-tag.sh <tag> [--signers-dir <dir>] [--notes <file> [--apps-sha <sha>]]" >&2; exit 2 ;;
  esac
done
[ -n "$tag" ] || { echo "usage: check-release-tag.sh <tag> [--signers-dir <dir>] [--notes <file> [--apps-sha <sha>]]" >&2; exit 2; }
if [ -n "$apps_sha" ]; then
  [[ "$apps_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "✗ --apps-sha must be a full 40-hex commit SHA (git rev-parse <apps tag>^{commit})" >&2; exit 2; }
  [ -n "$notes" ] || { echo "✗ --apps-sha checks the notes: give --notes too" >&2; exit 2; }
fi
[ -f "$dir/signers.txt" ] || { echo "✗ $dir/signers.txt not found: no signer table to check against" >&2; exit 2; }
command -v gpg >/dev/null || { echo "✗ gpg missing: cannot verify" >&2; exit 2; }

if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "✗ tag $tag does not exist locally (git fetch --tags)" >&2; exit 1
fi
kind="$(git cat-file -t "refs/tags/$tag")"
if [ "$kind" != tag ]; then
  echo "✗ $tag is a lightweight tag ($kind object): a release tag is annotated and signed (git tag -s -m ...)" >&2; exit 1
fi

home="$(mktemp -d)"; chmod 700 "$home"
trap 'gpgconf --homedir "$home" --kill gpg-agent 2>/dev/null; rm -rf -- "$home"' EXIT
for k in "$dir"/*.asc; do
  [ -e "$k" ] || continue
  gpg --homedir "$home" --batch --quiet --import "$k" 2>/dev/null || { echo "✗ cannot import $k" >&2; exit 2; }
done

# GNUPGHOME applies to git's gpg call.
status="$(GNUPGHOME="$home" git -c gpg.program=gpg verify-tag --raw "refs/tags/$tag" 2>&1)" || true
if ! grep -q '^\[GNUPG:\] GOODSIG ' <<<"$status"; then
  if grep -q 'NO_PUBKEY\|ERRSIG' <<<"$status"; then
    echo "✗ $tag is signed by a key that is not in $dir (no public key file for it)" >&2
  else
    echo "✗ $tag carries no valid signature (unsigned, bad, or expired/revoked key)" >&2
  fi
  exit 1
fi
if ! grep -q '^\[GNUPG:\] VALIDSIG ' <<<"$status"; then
  echo "✗ $tag: signature not valid (expired or revoked key)" >&2; exit 1
fi
# VALIDSIG <signing key fpr> ... <primary key fpr> (last field)
sig="$(awk '/^\[GNUPG:\] VALIDSIG /{print toupper($NF)}' <<<"$status" | head -n1)"
if ! awk -v f="$sig" '!/^#/ && NF && toupper($1)==f {found=1} END {exit !found}' "$dir/signers.txt"; then
  echo "✗ $tag is signed by ${sig:0:16}..., which is not in the signer table ($dir/signers.txt)" >&2; exit 1
fi
sha="$(git rev-parse "refs/tags/$tag^{commit}")"
if [ -n "$notes" ]; then
  [ -f "$notes" ] || { echo "✗ notes file $notes not found" >&2; exit 2; }
  grep -q -- "$sha" "$notes" || { echo "✗ $notes does not name the release commit $sha" >&2; exit 1; }
  [ -z "$apps_sha" ] || grep -q -- "$apps_sha" "$notes" || { echo "✗ $notes does not name the OpenAether-apps release commit $apps_sha" >&2; exit 1; }
fi
echo "✓ $tag is an annotated tag signed by ${sig:0:16}... (in the signer table); release commit $sha"
