#!/usr/bin/env bash
# Scan EVERY ref the remote serves (branches, tags, pull-request heads) with the environment-data rules, which
# include the default credential ones. A purge rewrites branches and tags, but GitHub keeps refs/pull/*, so purged
# history stays fetchable there: what to do then is in the public-repo-safety skill.
#
# Findings already served are listed in .gitleaks-history.sha256 as the sha256 of their gitleaks fingerprint, so
# the list points at nothing. A finding not on it fails; a listed one no longer served is counted.
#
# Usage: scan-all-refs.sh [--update] [remote-url]   (default: this checkout's origin; --update rewrites the list)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${CONFIG:-$ROOT/.gitleaks-envdata.toml}"
IGNORE="${IGNORE:-$ROOT/.gitleaksignore}"
KNOWN="${KNOWN:-$ROOT/.gitleaks-history.sha256}"
UPDATE=0
if [ "${1:-}" = --update ]; then UPDATE=1; shift; fi
URL="${1:-$(git -C "$ROOT" remote get-url origin)}"
command -v gitleaks >/dev/null || { echo "✗ gitleaks not on PATH" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# A mirror fetches +refs/*:refs/*, the pull-request heads included; a normal clone does not.
git clone --quiet --mirror "$URL" "$tmp/repo.git"
REFS="$(git -C "$tmp/repo.git" for-each-ref | wc -l)"
[ "$REFS" -gt 0 ] || { echo "✗ $URL serves no ref: nothing was scanned" >&2; exit 1; }

rc=0
gitleaks git --no-banner --redact -c "$CONFIG" --gitleaks-ignore-path "$IGNORE" --log-opts="--all" \
  --report-format json --report-path "$tmp/report.json" "$tmp/repo.git" >"$tmp/gitleaks.log" 2>&1 || rc=$?
# 1 means findings, which the list below judges; anything else is a scan that did not happen.
if [ "$rc" -gt 1 ] || [ ! -s "$tmp/report.json" ]; then
  cat "$tmp/gitleaks.log" >&2; echo "✗ gitleaks failed (exit $rc)" >&2; exit 1
fi

REFS="$REFS" UPDATE="$UPDATE" python3 - "$tmp/report.json" "$KNOWN" <<'PY'
import hashlib, json, os, sys
findings = json.load(open(sys.argv[1]))
seen = {hashlib.sha256(f["Fingerprint"].encode()).hexdigest(): f for f in findings}
if os.environ["UPDATE"] == "1":
    with open(sys.argv[2], "w") as out:
        out.write("# sha256 of each gitleaks fingerprint already served by a ref (scripts/dev/scan-all-refs.sh --update).\n"
                  "# Listed is not triaged: it only keeps the weekly scan red on a NEW finding.\n")
        out.writelines(h + "\n" for h in sorted(seen))
    print(f"✓ {len(seen)} finding(s) listed in {sys.argv[2]}")
    sys.exit(0)
known = set()
if os.path.exists(sys.argv[2]):
    known = {l.strip() for l in open(sys.argv[2]) if l.strip() and not l.startswith("#")}
new = [f for h, f in seen.items() if h not in known]
gone = len(known - set(seen))
print(f"{os.environ['REFS']} refs, {len(seen)} finding(s), {len(seen) - len(new)} already listed, "
      f"{gone} listed finding(s) no longer served")
for f in sorted(new, key=lambda f: f["Fingerprint"]):
    print(f"✗ new: {f['Fingerprint']} ({f['RuleID']})")
sys.exit(1 if new else 0)
PY
