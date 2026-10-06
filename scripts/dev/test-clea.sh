#!/usr/bin/env bash
# Cléa's own assertions, offline, on synthetic fixtures.
#
# Every check below has a twin that must FAIL — a reader that matches nothing, a
# writer that writes nothing, a datasource that answers 403. A check only ever
# seen to pass is a check nobody has tested; it is the shape behind more than
# twenty defects here, and Cléa exists to catch that shape in other files, so it
# does not get to ship with it.
#
# Fixtures are built here rather than committed: this repository is public, and
# a version fixture is one more file that can grow a real value.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLEA="${CLEA:-$ROOT/scripts/clea/clea.py}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# expect <rc> <label> -- <command...>   : the command must exit with exactly rc
expect() {
  local want="$1" label="$2"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$label"; else
    bad "$label (exit $rc, wanted $want)"
    printf '%s\n' "$out" | sed 's/^/      /' | tail -8
  fi
}

# says <label> <needle> -- <command...>  : the output must contain needle
says() {
  local label="$1" needle="$2"; shift 3
  local out
  out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$needle"; then ok "$label"; else
    bad "$label — no '$needle' in the output"
    printf '%s\n' "$out" | sed 's/^/      /' | tail -8
  fi
}

# --- a fixture repository, one anchor per supported value form ---------------
mkfixture() { # <dir>
  local d="$1"
  mkdir -p "$d/scripts" "$d/.github/workflows" "$d/infra"
  cat > "$d/scripts/install.sh" <<'EOF'
#!/usr/bin/env bash
# clea-test: datasource=github-releases depName=acme/one extractVersion=^v(?<version>.*)$
ONE_VERSION="1.2.3"
# clea-test: datasource=github-releases depName=acme/two
TWO_VERSION="${TWO_VERSION:-v0.9.0}"
# clea-test: datasource=github-releases depName=acme/three
local THREE_VERSION="4.5.6"
EOF
  cat > "$d/.github/workflows/ci.yml" <<'EOF'
jobs:
  a:
    steps:
      - name: pip
        # clea-test: datasource=pypi depName=acme-four
        run: pip install acme-four==7.8.9
      - name: env
        env:
          # clea-test: datasource=github-releases depName=acme/five
          FIVE_VERSION: "10.11.12"
EOF
  cat > "$d/infra/variables.tf" <<'EOF'
variable "six" {
  # clea-test: datasource=github-releases depName=acme/six
  default = "v13.14.15"
}
EOF
  cat > "$d/Taskfile.yml" <<'EOF'
tasks:
  t:
    vars:
      # clea-test: datasource=github-releases depName=acme/seven
      SEVEN: '{{.SEVEN | default "16.17.18"}}'
EOF
  cat > "$d/clea.toml" <<'EOF'
[scan]
marker = "# clea-test:"
[report]
title = "t"
EOF
}

echo "=== the reader reads every form this repository actually uses ==="
mkfixture "$TMP/basic"
expect 0 "seven anchors in seven forms, all readable" \
  -- python3 "$CLEA" --root "$TMP/basic" coverage
says "the bash default form is read" "7 anchors, every one watched" \
  -- python3 "$CLEA" --root "$TMP/basic" coverage

echo
echo "=== an anchor inside a Markdown fence is an example, not a pin ==="
# Cléa's own README documents the anchor convention by showing one. Reading it
# reported go-task/task as an unwatched dependency of this repository — a
# detector matching its own documentation, which is the shape it hunts.
cp -r "$TMP/basic" "$TMP/md"
printf 'Docs.\n\n```bash\n# clea-test: datasource=github-releases depName=acme/documented\nDOC_VERSION="1.0.0"\n```\n' > "$TMP/md/README.md"
says "the fenced example is not counted" "7 anchors read" \
  -- python3 "$CLEA" --root "$TMP/md" coverage
expect 0 "and the tree is still clean" \
  -- python3 "$CLEA" --root "$TMP/md" coverage

echo
echo "=== an anchor that marks no version is a failure, with the reason ==="
mkdir -p "$TMP/tmpl"; cp "$TMP/basic/clea.toml" "$TMP/tmpl/"
cat > "$TMP/tmpl/Taskfile.yml" <<'EOF'
tasks:
  t:
    vars:
      # clea-test: datasource=github-releases depName=acme/computed
      PINNED:
        sh: ./compute-it.sh
      IMAGE: '{{.V | default .PINNED}}'
EOF
expect 1 "a template read as a version is refused" \
  -- python3 "$CLEA" --root "$TMP/tmpl" coverage
says "and it names what it read instead" "which is not a version" \
  -- python3 "$CLEA" --root "$TMP/tmpl" coverage

echo
echo "=== zero floor: nothing to check is not the same as nothing wrong ==="
mkdir -p "$TMP/empty"; cp "$TMP/basic/clea.toml" "$TMP/empty/"
echo "nothing here" > "$TMP/empty/README.md"
expect 1 "a tree with no anchor at all fails rather than reporting green" \
  -- python3 "$CLEA" --root "$TMP/empty" coverage

echo
echo "=== coverage against a Renovate config ==="
cp -r "$TMP/basic" "$TMP/cov"
cat > "$TMP/cov/renovate.json5" <<'EOF'
// A config that declares ONE manager, so six of the seven anchors are unwatched.
{
  customManagers: [
    {
      customType: "regex",
      fileMatch: ["^infra/variables\\.tf$"],
      matchStrings: [
        "# clea-test: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)\\s*\\n\\s*default\\s*=\\s*\"(?<currentValue>[^\"]+)\"",
      ],
    },
  ],
}
EOF
cat >> "$TMP/cov/clea.toml" <<'EOF'
[[inventory]]
kind = "renovate"
config = "renovate.json5"
exclude = ["renovate.json5"]
EOF
expect 1 "an inventory that sees one anchor of seven fails" \
  -- python3 "$CLEA" --root "$TMP/cov" coverage
says "and names the six it cannot see" "renovate cannot see 6 of 7" \
  -- python3 "$CLEA" --root "$TMP/cov" coverage
says "the config's own matchStrings are not counted as anchors" "7 anchors read" \
  -- python3 "$CLEA" --root "$TMP/cov" coverage

# The other direction, which must go green: a manager wide enough to see them all.
cat > "$TMP/cov/renovate.json5" <<'EOF'
{
  customManagers: [
    { customType: "regex", fileMatch: [".*"],
      matchStrings: ["# clea-test: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)"] },
  ],
}
EOF
expect 0 "widening the manager to every anchor turns it green" \
  -- python3 "$CLEA" --root "$TMP/cov" coverage

echo
echo "=== managerFilePatterns: /…/ is a regex, anything else a glob ==="
# Renovate renamed fileMatch and changed how it is read at the same time. A glob
# read as a regex matches almost nothing, so every anchor would be reported
# unwatched — and a checker that cries wolf gets muted, which is the failure
# this whole file is written against. No backslash in the patterns below: they
# would be eaten by the heredoc, and the assertion would test the escaping.
cp -r "$TMP/basic" "$TMP/mfp"
cat >> "$TMP/mfp/clea.toml" <<'EOF'
[[inventory]]
kind = "renovate"
config = "renovate.json5"
exclude = ["renovate.json5"]
EOF
mfp() { # <pattern>
  cat > "$TMP/mfp/renovate.json5" <<EOF
{
  customManagers: [
    { customType: "regex", managerFilePatterns: ["$1"],
      matchStrings: ["# clea-test: datasource=(?<datasource>[a-z-]+) depName=(?<depName>[a-z0-9/-]+)"] },
  ],
}
EOF
}
mfp 'scripts/*.sh'
says "a bare pattern is a glob, and it reaches the shell script" \
  "renovate cannot see 4 of 7" -- python3 "$CLEA" --root "$TMP/mfp" coverage
mfp '/^scripts/.+[.]sh$/'
says "slash-delimited is a regex, and reaches the same three" \
  "renovate cannot see 4 of 7" -- python3 "$CLEA" --root "$TMP/mfp" coverage
mfp '^scripts/.+[.]sh$'
says "a regex written without its slashes reaches nothing, and says so" \
  "renovate cannot see 7 of 7" -- python3 "$CLEA" --root "$TMP/mfp" coverage

echo
echo "=== a JSON5 config that does not parse stops the run ==="
cp -r "$TMP/cov" "$TMP/bad5"
printf '{ customManagers: [ { fileMatch: [".*"\n' > "$TMP/bad5/renovate.json5"
expect 1 "an unreadable inventory is an error, not an empty one" \
  -- python3 "$CLEA" --root "$TMP/bad5" coverage
says "and says which file" "renovate.json5" \
  -- python3 "$CLEA" --root "$TMP/bad5" coverage

echo
echo "=== bump: the inverse of the reader, and it refuses to write nothing ==="
cp -r "$TMP/basic" "$TMP/bump"
expect 0 "bump rewrites the pin" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/two v0.10.0
if grep -q 'TWO_VERSION:-v0.10.0' "$TMP/bump/scripts/install.sh"; then
  ok "the bash default form was rewritten in place"
else
  bad "the bash default form was not rewritten"
fi
expect 1 "bumping to the version already there is refused" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/two v0.10.0
expect 1 "bumping an unknown dependency is refused" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/nothing 1.0.0
expect 1 "bumping across a v prefix is refused" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/three v9.9.9
expect 0 "extractVersion is applied on the way in" \
  -- python3 "$CLEA" --root "$TMP/bump" bump acme/one v1.3.0
if grep -q 'ONE_VERSION="1.3.0"' "$TMP/bump/scripts/install.sh"; then
  ok "the stripped form was written, not the tag"
else
  bad "extractVersion was not applied: $(grep ONE_VERSION "$TMP/bump/scripts/install.sh" | head -1)"
fi

echo
echo "=== every site of one dependency, not the first ==="
cp -r "$TMP/basic" "$TMP/multi"
cat > "$TMP/multi/scripts/other.sh" <<'EOF'
# clea-test: datasource=github-releases depName=acme/three
OTHER_THREE="4.5.6"
EOF
python3 "$CLEA" --root "$TMP/multi" bump acme/three 4.6.0 >/dev/null 2>&1
if grep -q '4.6.0' "$TMP/multi/scripts/other.sh" && \
   grep -q '4.6.0' "$TMP/multi/scripts/install.sh"; then
  ok "both sites moved — one tool, one version, everywhere it is claimed"
else
  bad "only one of the two sites moved"
fi

echo
echo "=== the probe refuses rather than destroy or pretend ==="
# It bumps a pin and restores the tree with `git checkout -- .`. Run on a dirty
# tree that discards somebody's work, and a probe that cannot start a container
# must not exit 0 — a lane that reports success having run nothing is the whole
# failure this file is written against.
PROBE="$ROOT/scripts/clea/probe.sh"
git -C "$TMP/basic" init -q 2>/dev/null
git -C "$TMP/basic" add -A 2>/dev/null
git -C "$TMP/basic" -c user.email=t@t -c user.name=t commit -qm fixture 2>/dev/null
echo "dirty" >> "$TMP/basic/scripts/install.sh"
expect 1 "a dirty tree is refused before anything is touched" \
  -- env CLEA_ROOT="$TMP/basic" "$PROBE" acme/two v0.10.0 /bin/true "echo 0.10.0"
git -C "$TMP/basic" checkout -q -- .
if [ -n "$(git -C "$TMP/basic" status --porcelain --untracked-files=no)" ]; then
  bad "the refusal happened after the tree was already restored"
else
  ok "and the refusal came before the trap that would have discarded it"
fi
# PATH without docker: the container lanes cannot start, and that is a failure.
expect 1 "a probe that cannot start a container exits non-zero" \
  -- env CLEA_ROOT="$TMP/basic" PATH=/usr/bin:/bin "$PROBE" \
       acme/two v0.10.0 /bin/true "echo 0.10.0"

echo
echo "=== one dependency, two shapes, one bump ==="
# This repository pins fluxcd/flux2 as `v2.9.3` where the value builds a release
# URL and as `2.9.3` where it builds a filename. Both are correct, and only the
# upstream TAG can become both — `bump` re-applies extractVersion per site. The
# matrix used to carry one anchor's extracted form, chosen by whichever file
# sorted first: right by luck, wrong the moment a path changed.
cp -r "$TMP/basic" "$TMP/shapes"
cat > "$TMP/shapes/scripts/two-shapes.sh" <<'EOF'
#!/usr/bin/env bash
# clea-test: datasource=github-releases depName=acme/twoshape
URL_VERSION="${URL_VERSION:-v3.0.0}"
# clea-test: datasource=github-releases depName=acme/twoshape extractVersion=^v(?<version>.*)$
FILE_VERSION="3.0.0"
EOF
expect 0 "the tag moves both shapes at once" \
  -- python3 "$CLEA" --root "$TMP/shapes" bump acme/twoshape v3.1.0
if grep -q 'URL_VERSION:-v3.1.0' "$TMP/shapes/scripts/two-shapes.sh" &&
   grep -q 'FILE_VERSION="3.1.0"' "$TMP/shapes/scripts/two-shapes.sh"; then
  ok "each site got its own form — v3.1.0 and 3.1.0"
else
  bad "one of the two shapes was not written: $(grep VERSION "$TMP/shapes/scripts/two-shapes.sh" | tr '\n' ' ')"
fi
expect 1 "an extracted form cannot move the site that keeps the v" \
  -- python3 "$CLEA" --root "$TMP/shapes" bump acme/twoshape 3.2.0

echo
echo "=== action-sha and precommit-rev: bump cannot move the digest they also pin ==="
# Both shapes capture only the trailing comment (`# v1.0.0`) as the value — the
# commit right before it is a SEPARATE identifier the reader never touches. A
# naive bump would leave that stale: the tree would claim the new version and
# keep running the old one, silently, which is worse than not tracking it at
# all. Measured against a real anchor: this is exactly what a bare `# clea-test:`
# marker over `uses: acme/action@<sha>  # v1.0.0` would do if bump did not refuse.
cp -r "$TMP/basic" "$TMP/pin"
cat > "$TMP/pin/.github/workflows/action.yml" <<'EOF'
jobs:
  a:
    steps:
      # clea-test: datasource=github-releases depName=acme/action
      - uses: acme/action@1111111111111111111111111111111111111111  # v1.0.0
EOF
cat > "$TMP/pin/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/acme/hook
    # clea-test: datasource=github-releases depName=acme/hook
    rev: 2222222222222222222222222222222222222222  # v2.0.0
EOF
says "both new anchors are read, alongside the original seven" "9 anchors read" \
  -- python3 "$CLEA" --root "$TMP/pin" coverage
expect 1 "bumping the action refuses rather than orphan its digest" \
  -- python3 "$CLEA" --root "$TMP/pin" bump acme/action v1.1.0
says "and says why, not just that it can't" "still running" \
  -- python3 "$CLEA" --root "$TMP/pin" bump acme/action v1.1.0
if grep -q '1111111111111111111111111111111111111111.*# v1.0.0' "$TMP/pin/.github/workflows/action.yml"; then
  ok "the line is untouched — no half-bumped pin left behind"
else
  bad "the refusal still wrote something: $(grep uses: "$TMP/pin/.github/workflows/action.yml")"
fi
expect 1 "bumping the pre-commit hook refuses the same way" \
  -- python3 "$CLEA" --root "$TMP/pin" bump acme/hook v2.1.0
if grep -q '2222222222222222222222222222222222222222.*# v2.0.0' "$TMP/pin/.pre-commit-config.yaml"; then
  ok "the hook's rev is untouched too"
else
  bad "the refusal still wrote something: $(grep rev: "$TMP/pin/.pre-commit-config.yaml")"
fi

# With the commit the tag points at (the scan records it), an action-sha pin CAN be bumped:
# the commit and the comment move together, or nothing moves.
cp -r "$TMP/pin" "$TMP/pin0"
NEW=3333333333333333333333333333333333333333
fresh_pin() { rm -rf "$TMP/p2"; cp -r "$TMP/pin0" "$TMP/p2"; }
ACT="$TMP/p2/.github/workflows/action.yml"
fresh_pin
expect 0 "an action-sha pin bumps when it is given the commit its tag points at" \
  -- python3 "$CLEA" --root "$TMP/p2" bump --sha "$NEW" acme/action v1.1.0
if grep -qx "      - uses: acme/action@${NEW}  # v1.1.0" "$ACT"; then
  ok "the commit and the comment both moved, spacing kept"
else
  bad "the line is: $(grep uses: "$ACT")"
fi
SHA41=11111111111111111111111111111111111111111
SHA64=1111111111111111111111111111111111111111111111111111111111111111
for bogus in abc 111111111111111111111111111111111111111 "$SHA41" "$SHA64" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 'not-a-commit-sha-at-all-not-a-commit-sha-xx'; do
  fresh_pin
  expect 1 "a --sha of '${bogus:0:12}…' (${#bogus} chars) is refused" -- python3 "$CLEA" --root "$TMP/p2" bump --sha "$bogus" acme/action v1.1.0
  grep -q '1111111111111111111111111111111111111111.*# v1.0.0' "$ACT" || bad "a refused --sha still wrote: $(grep uses: "$ACT")"
done
fresh_pin
says "without any --sha the refusal says what to pass" "Pass --sha" -- python3 "$CLEA" --root "$TMP/p2" bump acme/action v1.1.0
for other in other/action acme/other; do
  fresh_pin; sed -i "s|uses: acme/action@|uses: $other@|" "$ACT"
  says "a uses: naming $other never takes this dependency's commit" "another repository" \
    -- python3 "$CLEA" --root "$TMP/p2" bump --sha "$NEW" acme/action v1.1.0
  grep -q "$other@1111111111111111111111111111111111111111  # v1.0.0" "$ACT" \
    && ok "…and the line is untouched" || bad "wrote through a repository mismatch: $(grep uses: "$ACT")"
done
fresh_pin; sed -i 's|uses: acme/action@|uses: Acme/Action/sub@|' "$ACT"
expect 0 "the repository compare ignores case and a subpath (Acme/Action/sub for acme/action)" \
  -- python3 "$CLEA" --root "$TMP/p2" bump --sha "$NEW" acme/action v1.1.0
grep -q "Acme/Action/sub@${NEW}  # v1.1.0" "$ACT" && ok "…and keeps what the line named" || bad "the line is: $(grep uses: "$ACT")"
fresh_pin; sed -i "s|uses: acme/action@1111111111111111111111111111111111111111|uses: 'acme/action@1111111111111111111111111111111111111111'|" "$ACT"
says "a line shape it does not recognise is refused as that, not as a repository mismatch" "not in the shape" \
  -- python3 "$CLEA" --root "$TMP/p2" bump --sha "$NEW" acme/action v1.1.0
fresh_pin
says "a pre-commit rev still refuses with a --sha, and says why" "pins a commit" \
  -- python3 "$CLEA" --root "$TMP/p2" bump --sha "$NEW" acme/hook v2.1.0
fresh_pin
expect 0 "a --sha given for a dependency with no action site is harmless" \
  -- python3 "$CLEA" --root "$TMP/p2" bump --sha "$NEW" acme/one v1.3.0
grep -q 'ONE_VERSION="1.3.0"' "$TMP/p2/scripts/install.sh" && ok "…and the plain site is rewritten as usual" || bad "$(grep ONE_VERSION "$TMP/p2/scripts/install.sh")"

# All or nothing across sites: the plain site sorts BEFORE the action site, so a
# write-as-you-go loop would have changed it by the time the action site refuses.
rm -rf "$TMP/p3"; cp -r "$TMP/pin0" "$TMP/p3"
printf 'env:\n  # clea-test: datasource=github-releases depName=acme/pair extractVersion=^v(?<version>.*)$\n  PAIR_VERSION: "1.0.0"\n' > "$TMP/p3/.github/workflows/a-env.yml"
printf 'jobs:\n  b:\n    steps:\n      # clea-test: datasource=github-releases depName=acme/pair\n      - uses: acme/pair@1111111111111111111111111111111111111111  # v1.0.0\n' > "$TMP/p3/.github/workflows/b-action.yml"
expect 1 "one dependency, a plain site and an action site: no --sha, refused" \
  -- python3 "$CLEA" --root "$TMP/p3" bump acme/pair v1.1.0
grep -q 'PAIR_VERSION: "1.0.0"' "$TMP/p3/.github/workflows/a-env.yml" \
  && ok "…and the plain site was not rewritten before the refusal" \
  || bad "partial write: $(grep PAIR_VERSION "$TMP/p3/.github/workflows/a-env.yml")"
expect 0 "with the --sha, the same bump rewrites both sites" \
  -- python3 "$CLEA" --root "$TMP/p3" bump --sha "$NEW" acme/pair v1.1.0
grep -q 'PAIR_VERSION: "1.1.0"' "$TMP/p3/.github/workflows/a-env.yml" \
  && grep -q "acme/pair@${NEW}  # v1.1.0" "$TMP/p3/.github/workflows/b-action.yml" \
  && ok "plain site 1.1.0, action site at the new commit and v1.1.0" \
  || bad "after the bump: $(grep -h 'PAIR_VERSION\|uses:' "$TMP/p3/.github/workflows/a-env.yml" "$TMP/p3/.github/workflows/b-action.yml")"
# The v-prefix refusal is a refusal too: it must not leave the first site rewritten either.
rm -rf "$TMP/p4"; cp -r "$TMP/pin0" "$TMP/p4"
printf '# clea-test: datasource=github-releases depName=acme/shape extractVersion=^v(?<version>.*)$\nA_VERSION="1.0.0"\n' > "$TMP/p4/scripts/aa.sh"
printf '# clea-test: datasource=github-releases depName=acme/shape\nZ_VERSION="1.0.0"\n' > "$TMP/p4/scripts/zz.sh"
expect 1 "two sites that read a v prefix differently: refused" -- python3 "$CLEA" --root "$TMP/p4" bump acme/shape v1.1.0
grep -q 'A_VERSION="1.0.0"' "$TMP/p4/scripts/aa.sh" && ok "…and the first site is untouched" || bad "partial write: $(grep A_VERSION "$TMP/p4/scripts/aa.sh")"
# A site whose COMMENT is already at the target may still hold another commit.
rm -rf "$TMP/p5"; cp -r "$TMP/pin0" "$TMP/p5"
printf 'env:\n  # clea-test: datasource=github-releases depName=acme/mix extractVersion=^v(?<version>.*)$\n  MIX_VERSION: "1.0.0"\n' > "$TMP/p5/.github/workflows/a-env.yml"
printf 'jobs:\n  b:\n    steps:\n      # clea-test: datasource=github-releases depName=acme/mix\n      - uses: acme/mix@2222222222222222222222222222222222222222  # v1.1.0\n' > "$TMP/p5/.github/workflows/b-action.yml"
expect 0 "a site already at the target tag but on another commit" -- python3 "$CLEA" --root "$TMP/p5" bump --sha "$NEW" acme/mix v1.1.0
grep -q "acme/mix@${NEW}  # v1.1.0" "$TMP/p5/.github/workflows/b-action.yml" \
  && ok "…is moved onto the commit of its tag" || bad "left on another commit: $(grep uses: "$TMP/p5/.github/workflows/b-action.yml")"

# The seam from the matrix to bump: the two lines that run it, taken out of the workflow and probe.sh
# and executed, so that dropping --sha from either goes red here and not on a runner.
grep -qF 'CLEA_SHA: ${{ matrix.entry.sha }}' "$ROOT/.github/workflows/clea.yml" \
  && ok "the probe job hands the matrix's commit to its steps as CLEA_SHA" || bad "the probe job does not export CLEA_SHA"
seam() { # <label> <script> <fixed pattern> <how to run the extracted line>
  local label="$1" file="$2" pat="$3" mode="$4" line
  line="$(grep -F -- "$pat" "$file" | head -1 | sed 's/^[[:space:]]*//; s/^if ! //; s/; then$//')"
  [ -n "$line" ] || { bad "$label: the bump line is gone from $file"; return; }
  fresh_pin
  mkdir -p "$TMP/p2/scripts/clea"; ln -sf "$CLEA" "$TMP/p2/scripts/clea/clea.py"
  ( cd "$TMP/p2" && DEP=acme/action VERSION=v1.1.0 CLEA_SHA="$NEW" CLEA="$CLEA" ROOT="$TMP/p2" bash -c "$line" ) >/dev/null 2>&1
  if grep -q "acme/action@${NEW}  # v1.1.0" "$ACT"; then ok "$label"; else bad "$label: the pin did not move ($line)"; fi
}
seam "clea.yml's bump step passes CLEA_SHA through, and the pin moves" "$ROOT/.github/workflows/clea.yml" 'clea.py bump' run
seam "probe.sh's bump passes CLEA_SHA through, and the pin moves" "$ROOT/scripts/clea/probe.sh" 'bump ${CLEA_SHA' probe

echo
echo "=== an action-sha pin's commit is resolved at scan time and carried to the bump ==="
COUNTFILE="$TMP/count" python3 - "$CLEA" "$TMP/pin0" <<'PY'
import contextlib, importlib.util, io, json, os, sys, tempfile
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)
C1, C2 = "a" * 40, "b" * 40
calls = []
def fake(path, token):
    calls.append((path, token))
    if "/repos/acme/fails/" in path: raise clea.CleaError("boom: lookup failed for acme/fails")
    tag = path.rsplit("/", 1)[-1]
    if path.endswith("/git/ref/tags/v1.1.0"): return {"ref": "refs/tags/v1.1.0", "object": {"type": "commit", "sha": C1}}
    if path.endswith("/git/ref/tags/v2.0.0"): return {"ref": "refs/tags/v2.0.0", "object": {"type": "tag", "sha": C2}}
    if path.endswith("/git/tags/" + C2): return {"object": {"type": "commit", "sha": C1}}
    if path.endswith("/git/ref/tags/tree"): return {"ref": "refs/tags/tree", "object": {"type": "tree", "sha": C1}}
    if path.endswith("/git/ref/tags/short"): return {"ref": "refs/tags/short", "object": {"type": "commit", "sha": "abc"}}
    if path.endswith("/git/ref/tags/empty"): return {"ref": "refs/tags/empty"}
    if path.endswith("/git/ref/tags/mismatch"): return {"ref": "refs/tags/mismatch-rc1", "object": {"type": "commit", "sha": C1}}
    if path.endswith("/git/ref/tags/v1%232"): return {"ref": "refs/tags/v1#2", "object": {"type": "commit", "sha": C1}}
    raise clea.CleaError("unexpected " + path)
clea._gh_json = fake
# OSV must never be reached from here: every scan asks it, and this harness stays offline.
osv_posts = []
clea.http_post_json = lambda url, payload: osv_posts.append(payload) or b"{}"

def refuses(tag):
    try: clea.resolve_commit("acme/action", tag, None); return False
    except clea.CleaError: return True
checks = [("a lightweight tag resolves to its commit", clea.resolve_commit("acme/action", "v1.1.0", "tk") == C1)]
checks.append(("…by asking the dependency's own repository, with the token it was given",
               calls[-1] == ("/repos/acme/action/git/ref/tags/v1.1.0", "tk")))
calls.clear()
checks.append(("an annotated tag is peeled to the commit it names", clea.resolve_commit("acme/action", "v2.0.0", "tk") == C1))
checks.append(("…in the same repository, with the same token",
               calls == [("/repos/acme/action/git/ref/tags/v2.0.0", "tk"), ("/repos/acme/action/git/tags/" + C2, "tk")]))
checks += [
    ("a tag that names a tree is refused", refuses("tree")),
    ("a commit id that is not 40 lowercase hex is refused", refuses("short")),
    ("an answer with no object is refused", refuses("empty")),
    ("an answer for another ref than the one asked is refused", refuses("mismatch")),
]
calls.clear(); got = clea.resolve_commit("acme/action", "v1#2", None)
checks.append(("a tag with a '#' is percent-encoded in the path, never cut at the fragment",
               got == C1 and calls[0][0].endswith("/git/ref/tags/v1%232")))
try:
    clea.http_get("http://127.0.0.1:9/v1\u00e9")
    checks.append(("a non-ASCII tag in the path becomes a Cléa error, not a crash", False))
except clea.CleaError:
    checks.append(("a non-ASCII tag in the path becomes a Cléa error, not a crash", True))
except Exception:
    checks.append(("a non-ASCII tag in the path becomes a Cléa error, not a crash", False))

# the scan, end to end, on a copy of the fixture
work = tempfile.mkdtemp(); os.system(f"cp -r {sys.argv[2]}/. {work}/")
def add(path, text): open(os.path.join(work, path), "w").write(text)
add(".github/workflows/action2.yml", "jobs:\n  b:\n    steps:\n      # clea-test: datasource=github-releases depName=acme/action\n"
    "      - uses: acme/action@" + "2" * 40 + "  # v1.0.0\n")
add(".github/workflows/fails.yml", "jobs:\n  c:\n    steps:\n      # clea-test: datasource=github-releases depName=acme/fails\n"
    "      - uses: acme/fails@" + "3" * 40 + "  # v1.0.0\n")
add(".github/workflows/current.yml", "jobs:\n  d:\n    steps:\n      # clea-test: datasource=github-releases depName=acme/current\n"
    "      - uses: acme/current@" + "4" * 40 + "  # v1.1.0\n")
add(".github/workflows/notgh.yml", "jobs:\n  e:\n    steps:\n      # clea-test: datasource=pypi depName=acme-notgh\n"
    "      - uses: acme-notgh@" + "5" * 40 + "  # v1.0.0\n")
clea.DATASOURCES["github-releases"] = lambda dep, token, **_: {"tag": "v1.1.0", "released_at": None, "notes_url": None}
clea.DATASOURCES["pypi"] = lambda dep, token, **_: {"tag": "v1.1.0", "released_at": None, "notes_url": None}
calls.clear(); state_path = os.path.join(work, "state.json")
os.environ["GITHUB_TOKEN"] = "tok-scan"
clea.main(["--root", work, "scan", "--state", state_path])
state = json.load(open(state_path))
by = {}
for d in state["deps"]: by.setdefault(d["dep"], []).append(d)
looked = [c for c in calls if "/git/ref/tags/" in c[0]]
checks += [
    ("the scan records the commit on every action-sha anchor of the dependency",
     [d.get("sha") for d in by["acme/action"]] == [C1, C1]),
    ("…and on no other anchor", all("sha" not in d for d in state["deps"] if d["form"] != "action-sha")),
    ("one lookup of the bump's tag per action pin, not one per anchor, with the scan's own token",
     [c for c in looked if c[0].endswith("/repos/acme/action/git/ref/tags/v1.1.0")]
     == [("/repos/acme/action/git/ref/tags/v1.1.0", "tok-scan")]),
    # The pinned tag IS looked up now (OSV is asked by commit), but it is no commit to bump with.
    ("an action pin that is not behind has no commit to bump with, and only its own tag is looked up",
     all("sha" not in d for d in by["acme/current"])
     and [c[0] for c in calls if "/repos/acme/current/" in c[0]] == ["/repos/acme/current/git/ref/tags/v1.1.0"]),
    ("OSV is asked by the commit the scan resolved, and never reached for real", {"commit": C1} in osv_posts),
    ("an action pin on a datasource that is not GitHub is never looked up",
     not any("acme-notgh" in c[0] for c in calls) and "sha" not in by["acme-notgh"][0]),
    ("a failed lookup is an error in the report…", any("boom: lookup failed" in e for e in state["errors"])),
    ("…the dependency is still behind, with no commit recorded",
     by["acme/fails"][0]["behind"] is True and "sha" not in by["acme/fails"][0]),
]
# the matrix hands the commit to the probe, only for the tag the entry bumps to
def matrix(deps):
    p = os.path.join(work, "m.json"); open(p, "w").write(json.dumps({"deps": deps}))
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf): clea.main(["--root", work, "matrix", "--state", p])
    return {e["dep"]: e for e in json.loads(buf.getvalue())}
def row(dep, tag, sha=None):
    r = {"dep": dep, "behind": True, "pinned": True, "tag": tag, "latest": tag.lstrip("v"),
         "released_at": "2000-01-01T00:00:00Z"}
    if sha: r["sha"] = sha
    return r
checks += [
    ("the matrix carries the commit of the real case: the action anchor sorts first",
     matrix([row("p/q", "v2", C1), row("p/q", "v2")])["p/q"]["sha"] == C1),
    ("…of a dependency with one action anchor", matrix([row("p/q", "v2", C1)])["p/q"]["sha"] == C1),
    ("…when it sits on a later anchor", matrix([row("p/q", "v2"), row("p/q", "v2", C1)])["p/q"]["sha"] == C1),
    ("…the first one is kept when a later anchor holds another", matrix([row("p/q", "v2", C1), row("p/q", "v2", C2)])["p/q"]["sha"] == C1),
    ("…and empty for a dependency without any", matrix([row("p/q", "v2")])["p/q"]["sha"] == ""),
    ("a commit resolved for ANOTHER tag is never paired with this entry's version",
     matrix([row("p/q", "v1"), row("p/q", "v2", C1)])["p/q"]["sha"] == ""),
]
# without the commit, the bump of that dependency refuses and says what to pass
err = io.StringIO()
with contextlib.redirect_stderr(err):
    rc = clea.main(["--root", work, "bump", "acme/fails", "v1.1.0"])
checks.append(("…and bump then refuses and says to pass --sha", rc == 1 and "Pass --sha" in err.getvalue()))
for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + name)
open(os.environ["COUNTFILE"], "w").write(str(len(checks)))
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
rc=$?
if [ "$rc" -eq 0 ]; then PASS=$((PASS + $(cat "$TMP/count"))); else FAIL=$((FAIL + 1)); fi

echo
echo "=== renovate-native: an explicit, per-form claim, not a blanket exemption ==="
# The two forms above can't be safely covered by a customManagers cross-check
# (that's the point of the section above), so a project may instead vouch for
# them by FORM: "Renovate's own github-actions / pre-commit managers already
# read this shape, with no anchor at all." coverage must accept that claim only
# for the forms actually named, and still demand the customManagers proof —
# or a real gap — for everything else.
cp -r "$TMP/pin" "$TMP/native"
cat >> "$TMP/native/clea.toml" <<'EOF'
[[inventory]]
kind = "renovate-native"
forms = ["action-sha"]
EOF
expect 1 "naming only action-sha still leaves precommit-rev, and the plain seven, unwatched" \
  -- python3 "$CLEA" --root "$TMP/native" coverage
OUT="$(python3 "$CLEA" --root "$TMP/native" coverage 2>&1)"
if printf '%s' "$OUT" | grep -q 'acme/action ='; then
  bad "the covered anchor (acme/action) still shows up as missing"
else
  ok "the covered anchor (acme/action) is not listed as missing"
fi
if printf '%s' "$OUT" | grep -q 'acme/hook ='; then
  ok "the uncovered anchor (acme/hook) is still listed as missing"
else
  bad "acme/hook should still be reported unwatched"
fi

# Widen the customManagers side to the plain seven ONLY (excluded by filename,
# not by luck): if it also reached the two pinned files, renovate-native's own
# contribution to the union below would go untested.
cp -r "$TMP/pin" "$TMP/native2"
cat > "$TMP/native2/renovate.json5" <<'EOF'
{
  customManagers: [
    { customType: "regex",
      managerFilePatterns: ["scripts/*.sh", ".github/workflows/ci.yml", "infra/*.tf", "Taskfile.yml"],
      matchStrings: ["# clea-test: datasource=(?<datasource>[a-z-]+) depName=(?<depName>[a-z0-9/-]+)"] },
  ],
}
EOF
cat >> "$TMP/native2/clea.toml" <<'EOF'
[[inventory]]
kind = "renovate"
config = "renovate.json5"
exclude = ["renovate.json5"]

[[inventory]]
kind = "renovate-native"
forms = ["action-sha", "precommit-rev"]
EOF
expect 0 "renovate covers the plain seven, renovate-native covers the two pinned ones — together, everything" \
  -- python3 "$CLEA" --root "$TMP/native2" coverage
# And each kind alone would still fail, proving the union is doing the work
# rather than either kind quietly reaching everything on its own.
rm "$TMP/native2/clea.toml"
cp "$TMP/pin/clea.toml" "$TMP/native2/clea.toml"
cat >> "$TMP/native2/clea.toml" <<'EOF'
[[inventory]]
kind = "renovate"
config = "renovate.json5"
exclude = ["renovate.json5"]
EOF
expect 1 "renovate alone does not reach the two pinned anchors" \
  -- python3 "$CLEA" --root "$TMP/native2" coverage

mkdir -p "$TMP/badform"; cp -r "$TMP/pin/." "$TMP/badform/"
cat >> "$TMP/badform/clea.toml" <<'EOF'
[[inventory]]
kind = "renovate-native"
forms = ["not-a-real-form"]
EOF
expect 1 "naming a form that does not exist is refused, not silently ignored" \
  -- python3 "$CLEA" --root "$TMP/badform" coverage
says "and it names the bad form, not just failing quietly" "not-a-real-form" \
  -- python3 "$CLEA" --root "$TMP/badform" coverage

echo
echo "=== version comparison, and the pair every hand-rolled comparator gets wrong ==="
python3 - "$CLEA" <<'PY'
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)
checks = [
    ("1.13.10 > 1.13.9", clea.is_newer("1.13.9", "1.13.10")),
    ("v1.13.10 > v1.13.9", clea.is_newer("v1.13.9", "v1.13.10")),
    ("1.2.3 is not newer than itself", not clea.is_newer("1.2.3", "1.2.3")),
    ("a release beats its own rc", clea.is_newer("1.2.3-rc1", "1.2.3")),
    ("an rc does not beat the release", not clea.is_newer("1.2.3", "1.2.3-rc1")),
    ("shapes must agree", not clea.same_shape("1.2.3", "v1.2.3")),
    ("extractVersion strips the v", clea.apply_extract("v1.2.3", r"^v(?<version>.*)$") == "1.2.3"),
    ("no extractVersion keeps the tag", clea.apply_extract("v1.2.3", None) == "v1.2.3"),
]
bad = [name for name, got in checks if not got]
for name, got in checks:
    print(("  \033[32m✓\033[0m " if got else "  \033[31m✗\033[0m ") + name)
sys.exit(1 if bad else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 8)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== the bot heartbeat: silence only means something when crossed ==="
python3 - "$CLEA" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)

def state(days, behind=True, watched=True):
    return {"generated_at": "now", "deps": [{
        "dep": "helm/helm", "file": "scripts/setup.sh", "line": 225,
        "current": "4.2.3", "latest": "4.2.4", "pinned": True, "released_at": "2000-01-01T00:00:00Z",
        "behind": behind, "watched": watched, "shape_ok": True}],
        "bot": {"bot": "renovate[bot]", "number": 11, "at": "2026-07-30",
                "days": days, "scanned": 100, "silent_after_days": 8}}

warn = "and it has proposed nothing"
checks = [
    ("behind, watched, 24 days silent -> the report says so",
     warn in clea.render_report(state(24))),
    ("behind but within the window -> nothing concluded",
     warn not in clea.render_report(state(3))),
    ("silent but nothing behind -> silence proves nothing",
     "proves\nnothing either way" in clea.render_report(state(24, behind=False))
     or "proves nothing either way" in clea.render_report(state(24, behind=False))),
    ("behind but the bot cannot see it -> not the bot's fault",
     warn not in clea.render_report(state(24, watched=False))),
]

# The query itself: a bot with no pull request at all, and one that answers.
PRS = [{"number": 40, "user": {"login": "a-human"}, "created_at": "2026-08-20T00:00:00Z"},
       {"number": 11, "user": {"login": "renovate[bot]"}, "created_at": "2026-07-30T05:50:28Z"}]
clea._gh_json = lambda path, token: PRS
got = clea.bot_activity("o/r", "renovate[bot]", None)
checks.append(("the newest pull request by the bot is found, not the newest overall",
               got["number"] == 11 and got["days"] is not None and got["days"] > 20))
clea._gh_json = lambda path, token: [PRS[0]]
none = clea.bot_activity("o/r", "renovate[bot]", None)
checks.append(("a bot with no pull request at all is reported, not assumed fine",
               none["number"] is None and none["scanned"] == 1))
checks.append(("and the report says which", "No pull request from" in
               clea.render_report({"deps": [], "bot": dict(none, silent_after_days=8)})))

for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + name)
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 7)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== a probe that passed but never reached its branch is named, not read as 'not probed' ==="
python3 - "$CLEA" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)

def dep(name, tag, behind=True):
    return {"dep": name, "tag": tag, "latest": tag.lstrip("v"), "current": "0", "file": "f", "line": 1,
            "pinned": True, "behind": behind, "watched": True, "shape_ok": True}
def job(name, conclusion): return {"name": name, "conclusion": conclusion, "html_url": "https://example.invalid/" + name}

state = {"generated_at": "now",
         "deps": [dep("opentofu/opentofu", "v1.13.0"), dep("kubernetes/kubernetes", "v1.37.1"),
                  dep("getplumber/plumber", "v0.5.16"), dep("helm/helm", "v4.3.0", behind=False)],
         "probes": [{"dep": "kubernetes/kubernetes", "version": "v1.37.1", "green": False, "branch": "b", "run": "r"}]}
jobs = [job("Probe opentofu/opentofu", "success"), job("Probe kubernetes/kubernetes", "success"),
        job("Probe getplumber/plumber", "failure"), job("Probe helm/helm", "success")]
lost = {l["dep"] for l in clea.lost_verdicts(state, jobs)}
old = dict(state, probes=[{"dep": "opentofu/opentofu", "version": "v1.12.9", "green": True, "branch": "b", "run": "r"}])

def render(**extra): return clea.render_report(dict(state, lost_verdicts=clea.lost_verdicts(state, jobs), **extra))
checks = [
    ("passed, no record at its tag -> lost", lost == {"opentofu/opentofu"}),
    ("passed, recorded at its exact tag -> not lost", "kubernetes/kubernetes" not in lost),
    ("a failed job is 'stalled', not 'lost'", "getplumber/plumber" not in lost),
    ("a dependency that is not behind is not lost", "helm/helm" not in lost),
    ("an OLDER record of the same dependency is not this run's",
     {l["dep"] for l in clea.lost_verdicts(old, jobs)} >= {"opentofu/opentofu"}),
    ("a failed push opens the report with a warning that names the cause and the secret",
     "(the push job ended `failure`)" in render(push_result="failure") and "Invalid username or token" in render(push_result="failure")),
    ("…and names the dependency whose verdict was lost", "- `opentofu/opentofu` — [Probe opentofu/opentofu]" in render(push_result="failure")),
    ("a lost verdict warns even when the push job reports success", "did not record all" in render(push_result="success")),
    ("no loss and a clean push -> no warning",
     "did not record all" not in clea.render_report(dict(state, push_result="success", lost_verdicts=[]))
     and "did not record all" not in clea.render_report(dict(state, push_result="skipped", lost_verdicts=[]))),
    ("the first line is still the one pick-issue recognises",
     bool(clea.REPORT_MARKER_RE.match(render(push_result="failure").splitlines()[0]))),
    # The push job also carries the cluster lane's patch, which lost_verdicts never lists.
    ("a failed push warns on its own, with nothing listed as lost",
     "(the push job ended `failure`)" in clea.render_report(dict(state, push_result="failure", lost_verdicts=[]))
     and "verdict not recorded:" not in clea.render_report(dict(state, push_result="failure", lost_verdicts=[]))),
    ("a dependency without a `tag` key is matched on its `latest`",
     clea.lost_verdicts({"deps": [dict(dep("x/y", "v1.0.0"), tag=None, latest="1.0.0")],
                         "probes": [{"dep": "x/y", "version": "1.0.0"}]}, [job("Probe x/y", "success")]) == []),
    ("one dependency behind in two rows, one of them recorded, is not lost",
     clea.lost_verdicts({"deps": [dep("x/y", "v1.0.0"), dep("x/y", "v1.0.1")],
                         "probes": [{"dep": "x/y", "version": "v1.0.1"}]}, [job("Probe x/y", "success")]) == []),
]
for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + name)
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 13)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== a rate-limited datasource is an error, never 'up to date' ==="
python3 - "$CLEA" <<'PY'
import http.server, importlib.util, socket, sys, threading

spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = 403 if "limited" in self.path else 200
        body = b'{"message":"API rate limit exceeded"}' if code == 403 else b'v9.9.9\n'
        self.send_response(code); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

sock = socket.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
server = http.server.HTTPServer(("127.0.0.1", port), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{port}"

failures = []
try:
    clea.http_get(f"{base}/limited")
    failures.append("a 403 did not raise")
except clea.CleaError as exc:
    if "GITHUB_TOKEN" not in str(exc):
        failures.append(f"the 403 message does not name the fix: {exc}")

got = clea.latest_url_text("k8s", None, url=f"{base}/ok",
                           extract=r"^(?P<v>v[0-9][0-9A-Za-z.-]*)$")
if got["tag"] != "v9.9.9":
    failures.append(f"url-text read {got['tag']!r}")
try:
    clea.latest_url_text("k8s", None, url=f"{base}/ok", extract=r"^(?P<v>NOPE)$")
    failures.append("an extract that matches nothing did not raise")
except clea.CleaError:
    pass
server.shutdown()
for f in failures:
    print("  \033[31m✗\033[0m " + f)
if not failures:
    print("  \033[32m✓\033[0m a 403 raises and names GITHUB_TOKEN")
    print("  \033[32m✓\033[0m url-text extracts, and refuses to invent a version")
sys.exit(1 if failures else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 2)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== the helm index: indent is the only structure a line scanner has ==="
python3 - "$CLEA" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)
# Built from the real shape of https://helm.cilium.io/index.yaml, which is
# 1.7 MB and embeds Kubernetes CRD listings inside an annotation. Reading every
# `version:` line collected `v2` from depth 10, and (2,) outranks (1,20,1), so
# the newest chart of a repository serving 1.20 came back as v2. Following the
# annotation's own list items then re-based the scan and it came back 1.8.13.
# Both were seen against the live index before this fixture existed.
INDEX = b'''apiVersion: v1
entries:
  cilium:
  - annotations:
      artifacthub.io/crds: "- kind: CiliumNetworkPolicy\\n  version: v2\\n  name: x\\n"
      artifacthub.io/links: |
        - name: a
          version: v2
        - name: b
          version: v2
      artifacthub.io/prerelease: |
          version: 99.9.9
    apiVersion: v2
    appVersion: 1.20.1
    name: cilium
    version: 1.20.1
  - annotations:
      deep:
          version: v2
    apiVersion: v2
    version: 1.19.2
  - apiVersion: v2
    version: 1.21.0-rc.1
  - apiVersion: v2
    version: 1.8.13
  zzz-other-chart:
  - version: 99.0.0
'''
clea.http_get = lambda url, *a, **k: INDEX
got = clea.latest_helm("cilium", None, registry_url="https://example.invalid")["tag"]
checks = [
    ("v2 at depth 10 is not a chart version", got != "v2"),
    ("the annotation's own list items do not re-base the scan", got != "1.8.13"),
    ("1.20.1 beats 1.19.2, 1.8.13 and the rc", got == "1.20.1"),
    ("the next entry is not read", got != "99.0.0"),
    # Load-bearing on its own: 99.9.9 IS semver, so only the indent says no.
    ("a semver-shaped value at the wrong depth is not a chart version",
     got != "99.9.9"),
]
for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + f"{name} (got {got})")
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 5)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== a probe that failed before it could push is named, not silent ==="
# GITHUB_TOKEN cannot push a change to a workflow file, in any repository —
# measured 2026-08-24 on this workflow's first real run, three probes
# (commitizen, opentofu/opentofu, siderolabs/talos, all anchored inside
# .github/workflows/ci.yml) failed at exactly that step. Without this section
# they would just be ABSENT from the report — indistinguishable from a
# dependency that was never behind at all.
python3 - "$CLEA" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)
state = {"generated_at": "now", "deps": [], "probes": [],
         "stalled_probes": [{"dep": "commitizen", "job": "Probe commitizen",
                             "url": "https://example.invalid/run/1"}]}
report = clea.render_report(state)
checks = [
    ("the section header appears", "could not record a verdict" in report),
    ("the dependency is named", "commitizen" in report),
    ("the job's own URL is linked, not just asserted", "example.invalid/run/1" in report),
    ("an empty list produces no section at all — not just the standing "
     "disclaimer bullet, which names the same section on purpose",
     "## Probes that could not record a verdict"
     not in clea.render_report({**state, "stalled_probes": []})),
]
for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + name)
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 4)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== a probe matches its anchor by the SAME tag the matrix used to bump it ==="
# cmd_matrix hands the probe dep.get("tag") or dep["latest"] — the raw upstream
# tag, unstripped, because a dependency can be pinned in two shapes across its
# anchors and only the tag becomes both (see fluxcd/flux2 above). render_report
# used to compare a probe's recorded version against `latest` — THIS anchor's
# own extracted form — which is a DIFFERENT STRING whenever extractVersion
# actually strips something. opentofu/opentofu, go-task/task and
# cloudnative-pg/cloudnative-pg all ran green and pushed a verdict on this
# workflow's sixth real run (2026-08-24) and were reported "not probed" anyway
# — three of seven, silently wrong in the direction that hides success.
python3 - "$CLEA" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)

# acme/stripped: extractVersion strips the v, so tag ("v9.0.0") and latest
# ("9.0.0") are different strings for the same real version — exactly the
# opentofu/go-task/cloudnative-pg shape.
state = {
    "generated_at": "now",
    "deps": [{"dep": "acme/stripped", "file": "f", "line": 1, "current": "8.0.0",
              "latest": "9.0.0", "tag": "v9.0.0", "pinned": True, "behind": True,
              "released_at": "2000-01-01T00:00:00Z", "shape_ok": True, "notes_url": None}],
    # The matrix bumped it with the TAG, so that is what the probe recorded —
    # matching cmd_matrix's own dep.get("tag") or dep["latest"] expression.
    "probes": [{"dep": "acme/stripped", "version": "v9.0.0", "green": True,
               "branch": "clea/probe/acme-stripped", "run": "x", "log": ""}],
}
report = clea.render_report(state)
checks = [
    ("a stripped-tag dependency's real probe is found",
     "✅ probed green" in report),
    ("and it is not reported as unprobed",
     "not probed" not in report),
]
for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + name)
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 2)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== pick-issue: Cléa's OWN report, not just the newest labelled issue (#127) ==="
# #104 clobbered #91 for real on 2026-08-28: #104, human-authored and labelled
# clea to cross-reference a finding, was NEWER than #91 (the actual report) and
# won a naive created-desc/per_page=1 read — then got PATCHed over wholesale on
# the next scheduled run. Fixture reproduces the exact shape: same two issues,
# same order (newest first, as the API's default sort hands them over).
REPORT_BODY="_Generated 2026-08-24T14:01:45+00:00 by [Cléa](../blob/main/scripts/clea/README.md). This issue is rewritten in place; do not open another._ ## Behind upstream"
cat > "$TMP/basic/issues.json" <<EOF
[
  {"number": 104, "user": {"login": "vde-dis"},
   "body": "Prove Talos v1.13.9 + Kubernetes v1.37.0 before bumping kubernetes_version."},
  {"number": 91, "user": {"login": "github-actions[bot]"},
   "body": "${REPORT_BODY}"}
]
EOF
says "the actual report (#91) is picked over the newer human-authored issue" "91" \
  -- python3 "$CLEA" --root "$TMP/basic" pick-issue --issues "$TMP/basic/issues.json" --body-out "$TMP/basic/previous.md"
says "its body is carried to previous.md, for the next scan's --previous diff" "Behind upstream" \
  -- cat "$TMP/basic/previous.md"

python3 - "$CLEA" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)

REPORT_BODY = ("_Generated 2026-08-24T14:01:45+00:00 by "
              "[Cléa](../blob/main/scripts/clea/README.md). "
              "This issue is rewritten in place; do not open another._")
issue_104 = {"number": 104, "user": {"login": "vde-dis"}, "body": "unrelated write-up"}
issue_91 = {"number": 91, "user": {"login": "github-actions[bot]"}, "body": REPORT_BODY}

checks = [
    ("the report wins regardless of list order",
     clea.pick_report_issue([issue_104, issue_91], "github-actions[bot]")["number"] == 91
     and clea.pick_report_issue([issue_91, issue_104], "github-actions[bot]")["number"] == 91),
    ("no match among the label-fetched issues -> None, not a guess",
     clea.pick_report_issue([issue_104], "github-actions[bot]") is None),
    ("the marker alone, from the wrong author, is not enough",
     clea.pick_report_issue([{"number": 200, "user": {"login": "someone-else"},
                              "body": REPORT_BODY}], "github-actions[bot]") is None),
    ("the right author alone, without the marker, is not enough",
     clea.pick_report_issue([{"number": 201, "user": {"login": "github-actions[bot]"},
                              "body": "some other bot-authored issue"}],
                            "github-actions[bot]") is None),
    ("multiple matches (should not happen) fall back to the lowest issue number",
     clea.pick_report_issue([
         {"number": 300, "user": {"login": "github-actions[bot]"}, "body": REPORT_BODY},
         issue_91,
     ], "github-actions[bot]")["number"] == 91),
]
for name, ok in checks:
    print(("  \033[32m✓\033[0m " if ok else "  \033[31m✗\033[0m ") + name)
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 5)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== ANSI color has no reason to survive into stored data ==="
# GitHub's own issue-body storage does not return raw terminal escape sequences
# unchanged — \u001b[32m came back as the literal three characters \^[ on a
# real run, which is not valid JSON and broke the embedded state entirely. The
# strip has to happen before the log ever reaches json.dump, not after.
python3 - <<'PY'
import re, sys
ansi = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
sample = "\x1b[32m\u2713\x1b[0m the dependency is named\n  \x1b[31m\u2717\x1b[0m one failed"
stripped = ansi.sub("", sample)
checks = [
    ("no ESC byte survives", "\x1b" not in stripped),
    ("the readable text is untouched", "the dependency is named" in stripped
     and "one failed" in stripped),
]
for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + name)
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 2)); else FAIL=$((FAIL + 1)); fi

echo
echo "=== a bump is offered only if old enough, not withdrawn, not retagged, not advised against (#263) ==="
# A fresh release can be yanked, retagged or found vulnerable within days, so Cléa
# does not put one in the action list or the probe matrix until it has aged and
# OSV has had a look. Offline: PyPI and OSV are a local server that the real HTTP
# code talks to, and GitHub is a patched `_gh_json`.
RENOVATE_CFG="${RENOVATE_CFG:-$ROOT/renovate.json5}" CLEA_TOML="${CLEA_TOML:-$ROOT/clea.toml}" COUNTFILE="$TMP/count-offer" python3 - "$CLEA" <<'PY'
import contextlib, http.server, importlib.util, io, json, os, re, socket, sys, tempfile, threading
from datetime import datetime, timedelta, timezone

spec = importlib.util.spec_from_file_location("clea", sys.argv[1])
clea = importlib.util.module_from_spec(spec); spec.loader.exec_module(clea)

NOW = datetime.now(timezone.utc)
def ago(**kw): return (NOW - timedelta(**kw)).isoformat(timespec="seconds").replace("+00:00", "Z")
checks = []
def check(name, ok): checks.append((name, bool(ok)))

# --- the rules, on a bare row ------------------------------------------------
def row(**kw):
    d = {"dep": "x/y", "tag": "v2", "latest": "2", "current": "1", "pinned": True,
         "behind": True, "released_at": ago(days=30)}
    d.update(kw); return d
def holds(d, days=7, now=NOW): return clea.assess(d, now, days)["holds"]

three = NOW - timedelta(days=3)
check("a release 3 days old is held, with the date it becomes eligible",
      holds(row(released_at=three.isoformat())) == [f"too young, eligible on {(three + timedelta(days=7)).date()}"])
check("its age is reported in whole days", clea.assess(row(released_at=ago(days=3)), NOW, 7)["age"] == 3)
clock = datetime(2026, 1, 15, tzinfo=timezone.utc)
check("a release exactly N days old is eligible, on the clock's own tick",
      holds(row(released_at="2026-01-08T00:00:00Z"), now=clock) == []
      and len(holds(row(released_at="2026-01-08T00:00:01Z"), now=clock)) == 1)
check("one second short of N days is still held",
      len(holds(row(released_at=(NOW - timedelta(days=7) + timedelta(seconds=2)).isoformat()))) == 1)
check("an old release with nothing against it is not held", holds(row()) == [])
for label, value in (("missing", None), ("unreadable", "last tuesday")):
    check(f"a {label} date is `age unknown`, never eligible",
          holds(row(released_at=value)) == ["age unknown"])
check("a date with no `released_at` key at all is unknown too",
      holds({k: v for k, v in row().items() if k != "released_at"}) == ["age unknown"])
check("a helm date with nine fractional digits is read", holds(row(released_at="2000-04-10T13:11:52.123456789Z")) == [])
check("0 days switches the age rule off: young and undated are offered",
      holds(row(released_at=ago(days=0)), days=0) == [] and holds(row(released_at=None), days=0) == [])
check("…and still holds a yanked one", holds(row(withdrawn="yanked on PyPI"), days=0) == ["yanked on PyPI"])
check("a withdrawn release is held, with the reason it carries",
      holds(row(withdrawn="yanked on PyPI: broken wheel")) == ["yanked on PyPI: broken wheel"])
check("a tag that moved is held, naming both commits",
      holds(row(tag_moved={"from": "a" * 40, "to": "b" * 40})) == ["tag v2 moved since last scan (aaaaaaa → bbbbbbb)"])
check("an advisory against the candidate holds it, ids listed",
      holds(row(osv={"candidate": {"ids": ["GHSA-1", "GHSA-2"]}})) == ["advisory GHSA-1, GHSA-2 against v2"])
check("an advisory against the CURRENT pin does not hold the candidate",
      holds(row(osv={"current": {"ids": ["GHSA-1"]}, "candidate": {"ids": []}})) == [])
check("`advisories unknown` does not hold it either, and is never printed as none",
      holds(row(osv={"candidate": {"unknown": "OSV did not answer"}})) == []
      and clea.advisory_text({"unknown": "x"}) == "advisories unknown"
      and clea.advisory_text(None) == "advisories unknown"
      and clea.advisory_text({"ids": []}) == "none")
check("every cause is listed, not only the first",
      len(holds(row(released_at=ago(days=1), withdrawn="w", tag_moved={"from": "a", "to": "b"},
                    osv={"candidate": {"ids": ["G"]}}))) == 4)
check("a state without a policy is judged by the default, not waved through",
      clea.policy_of({"generated_at": ago(days=0)})[1] == 7
      and clea.policy_of({"policy": {"min_release_age_days": True}})[1] == 7
      and clea.policy_of({"policy": {"min_release_age_days": 3}})[1] == 3)

# --- the report and the matrix, on a hand-made state -------------------------
def state(*deps, **extra):
    return {"generated_at": ago(days=0), "policy": {"min_release_age_days": 7}, "deps": list(deps), **extra}
def dep(name, **kw):
    d = row(dep=name, file="f", line=1, shape_ok=True, notes_url=None, watched=True); d.update(kw); return d
def offered_part(report): return report.split("## Behind upstream")[1].split("## ")[0]

only_young = state(dep("a/young", released_at=ago(days=2)))
check("when every dependency behind is held, the report says nothing is offered",
      "Nothing is offered" in clea.render_report(only_young) and "## Held back" in clea.render_report(only_young))
check("…and `Nothing is behind` is kept for the case where nothing is",
      "Nothing is behind" in clea.render_report(state()))
beat = lambda days, *deps: clea.render_report(state(*deps, bot={"bot": "renovate[bot]", "number": 1, "at": "x", "days": days,
                                                                "scanned": 9, "silent_after_days": 8}))
check("a release too young for Renovate does not make its silence a fault",
      "and it has proposed nothing" not in beat(30, dep("a/young", released_at=ago(days=2))))
check("an old one still does", "and it has proposed nothing" in beat(30, dep("a/old")))
check("so does one held for a reason Renovate cannot know (yanked)",
      "and it has proposed nothing" in beat(30, dep("a/yanked", withdrawn="yanked on PyPI")))
check("an undated one is not blamed on the bot either",
      "and it has proposed nothing" not in beat(30, dep("a/undated", released_at=None)))

hit = dep("a/pin", osv={"current": {"ids": ["GHSA-pin"]}, "candidate": {"ids": []}}, latest="2")
rep = clea.render_report(state(hit, dep("b/clean", osv={"current": {"ids": []}, "candidate": {"ids": []}}),
                               dep("c/helm", behind=False, osv={"current": {"unknown": "no OSV mapping for datasource helm"}})))
check("an advisory against the current pin is its own line, with the argument to bump",
      re.search(r"`a/pin` `1` — GHSA-pin\. `2` is offered above: an argument for bumping sooner", rep) is not None)
check("a pin OSV could not be asked about is named as unknown, with why",
      "advisories unknown for `c/helm`: no OSV mapping for datasource helm" in rep)
check("a clean pin gets no advisory line", "`b/clean` `1` —" not in rep)
check("when the fix is held back, the line says why",
      "is held back (too young" in clea.render_report(state(dep("a/pin", released_at=ago(days=1),
          osv={"current": {"ids": ["GHSA-pin"]}, "candidate": {"ids": []}}))))
check("with no OSV answer at all the report does not claim there is none",
      "None against" not in clea.render_report(state(dep("a/x", osv={"current": {"unknown": "OSV did not answer"}}))))

# --- the network layer: a local server speaking PyPI's and OSV's shapes ------
SERVER = {"pypi": lambda name: (404, b""), "osv": lambda body: (200, b"{}")}
POSTS = []
class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, status, body):
        self.send_response(status); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        m = re.fullmatch(r"/pypi/([^/]+)/json", self.path)
        self._reply(*(SERVER["pypi"](m.group(1)) if m else (404, b"")))
    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        POSTS.append((self.path, self.headers.get("Content-Type"), json.loads(raw)))
        self._reply(*SERVER["osv"](json.loads(raw)))
    def log_message(self, *a): pass
sock = socket.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{port}"
clea.PYPI_API, clea.OSV_QUERY_URL = BASE + "/pypi", BASE + "/osv/v1/query"
sock = socket.socket(); sock.bind(("127.0.0.1", 0)); dead = f"http://127.0.0.1:{sock.getsockname()[1]}/v1/query"; sock.close()

def pypi_file(at, yanked=False, reason=None):
    return {"filename": "x.whl", "upload_time": at[:19], "upload_time_iso_8601": at, "yanked": yanked, "yanked_reason": reason}
def pypi_doc(version, files, yanked=False, reason=None, urls=True):
    return json.dumps({"info": {"version": version, "yanked": yanked, "yanked_reason": reason}, "last_serial": 1,
                       "urls": files if urls else [], "releases": {version: files}, "vulnerabilities": []}).encode()
def pypi(doc): SERVER["pypi"] = lambda name: (200, doc)
def latest(): return clea.latest_pypi("acme-py", None)

pypi(pypi_doc("2.0.0", [pypi_file("2026-01-13T07:47:53.276685Z"), pypi_file("2026-01-13T07:47:51.343950Z")]))
got = latest()
check("PyPI: the release date is its EARLIEST file upload, not the first listed",
      got["released_at"] == "2026-01-13T07:47:51.343950Z" and got["tag"] == "2.0.0" and got["withdrawn"] is None)
pypi(pypi_doc("2.0.0", [pypi_file("2026-01-13T07:47:51Z")], urls=False))
check("PyPI: with no `urls`, the date comes from `releases[version]`", latest()["released_at"] == "2026-01-13T07:47:51Z")
pypi(pypi_doc("2.0.0", []))
check("PyPI: no file at all means no date, not today", latest()["released_at"] is None)
pypi(pypi_doc("2.0.0", [pypi_file("2026-01-13T07:47:51Z")], yanked=True, reason="broken build"))
check("PyPI: a yanked release is withdrawn, with PyPI's own reason", latest()["withdrawn"] == "yanked on PyPI: broken build")
pypi(pypi_doc("2.0.0", [pypi_file("2026-01-13T07:47:51Z", True), pypi_file("2026-01-13T07:47:52Z", True, "bad")]))
check("PyPI: every file yanked is yanked, even when `info` says nothing", latest()["withdrawn"] == "yanked on PyPI: bad")
pypi(pypi_doc("2.0.0", [pypi_file("2026-01-13T07:47:51Z", True), pypi_file("2026-01-13T07:47:52Z")]))
check("PyPI: one file yanked out of two is not a yanked release", latest()["withdrawn"] is None)
SERVER["pypi"] = lambda name: (200, b"<html>maintenance</html>")
try: latest(); check("PyPI: an answer that is not JSON is a Cléa error", False)
except clea.CleaError: check("PyPI: an answer that is not JSON is a Cléa error", True)

# GitHub: the release flags, and a tag's date
def release(**kw): return {"tag_name": "v1", "published_at": "2026-01-01T00:00:00Z", "html_url": "u", "draft": False, "prerelease": False, **kw}
for label, kw, want in (("a draft", {"draft": True}, "GitHub release is a draft"),
                        ("a pre-release", {"prerelease": True}, "GitHub release is marked pre-release"),
                        ("a plain release", {}, None)):
    clea._gh_json = lambda path, token, kw=kw: release(**kw)
    check(f"GitHub: {label} -> withdrawn is {want!r}", clea.latest_github_releases("a/b", None)["withdrawn"] == want)
C1, C2 = "1" * 40, "2" * 40
def gh_tags(path, token):
    if path.endswith("/git/ref/tags/ann"): return {"ref": "refs/tags/ann", "object": {"type": "tag", "sha": C2}}
    if path.endswith("/git/tags/" + C2): return {"tagger": {"date": "2026-02-02T00:00:00Z"}, "object": {"type": "commit", "sha": C1}}
    if path.endswith("/git/ref/tags/light"): return {"ref": "refs/tags/light", "object": {"type": "commit", "sha": C1}}
    if path.endswith("/git/commits/" + C1): return {"committer": {"date": "2026-03-03T00:00:00Z"}}
    raise clea.CleaError("unexpected " + path)
clea._gh_json = gh_tags
check("GitHub: an annotated tag's date is the tagger's, and its commit is peeled",
      clea.tag_facts("a/b", "ann", None) == {"commit": C1, "date": "2026-02-02T00:00:00Z"})
check("GitHub: a lightweight tag has no date of its own; the commit's is read",
      clea.tag_facts("a/b", "light", None)["date"] is None and clea.commit_date("a/b", C1, None) == "2026-03-03T00:00:00Z")

# Helm: `created` of the chart item that is the newest, not of the item above it
INDEX = b'''entries:
  cilium:
  - apiVersion: v2
    created: "2000-01-01T00:00:00.123456789Z"
    version: 1.19.2
  - annotations:
      artifacthub.io/links: |
        - name: a
          created: 1999-01-01T00:00:00Z
    apiVersion: v2
    created: "2000-02-02T00:00:00.5Z"
    version: 1.20.1
  - apiVersion: v2
    created: "2000-03-03T00:00:00Z"
    version: 1.21.0-rc.1
'''
real_get = clea.http_get
clea.http_get = lambda url, *a, **k: INDEX
helm = clea.latest_helm("cilium", None, registry_url="https://example.invalid")
clea.http_get = real_get
check("helm: the date is the newest chart's `created`, not a neighbour's or a nested one",
      helm["tag"] == "1.20.1" and helm["released_at"] == "2000-02-02T00:00:00.5Z")
clea.http_get = lambda url, *a, **k: INDEX.replace(b'    created: "2000-02-02T00:00:00.5Z"\n', b"")
helm = clea.latest_helm("cilium", None, registry_url="https://example.invalid")
clea.http_get = real_get
check("helm: a newest chart with no `created` has no date, it does not borrow the one above",
      helm["tag"] == "1.20.1" and helm["released_at"] is None)

# OSV, on the wire
Q = {"package": {"name": "acme-py", "ecosystem": "PyPI"}, "version": "1.0.0"}
def osv(fn): SERVER["osv"] = fn
def jbody(o): return 200, json.dumps(o).encode()
POSTS.clear(); osv(lambda body: jbody({}))
check("OSV: `{}` is none", clea.osv_ids(Q) == [])
check("OSV: the query goes out as a JSON POST with exactly the package, ecosystem and version",
      POSTS == [("/osv/v1/query", "application/json", Q)])
osv(lambda body: jbody({"vulns": [{"id": "B"}, {"id": "A"}, {"id": "A"}, {"id": "W", "withdrawn": "2025-01-01T00:00:00Z"}]}))
check("OSV: ids are deduplicated and sorted, and a withdrawn advisory is not one", clea.osv_ids(Q) == ["A", "B"])
POSTS.clear()
osv(lambda body: jbody({"vulns": [{"id": "P2" if body.get("page_token") else "P1"}],
                        **({} if body.get("page_token") else {"next_page_token": "tok2"})}))
check("OSV: a second page is fetched with its token and merged",
      clea.osv_ids(Q) == ["P1", "P2"] and POSTS[1][2] == dict(Q, page_token="tok2"))
osv(lambda body: jbody({"vulns": [{"id": "X"}], "next_page_token": "again"}))
def fails(fn):
    try: fn(); return False
    except clea.CleaError: return True
check("OSV: pagination that never ends is an error, not an endless loop", fails(lambda: clea.osv_ids(Q)))
for label, answer in (("HTTP 500", (500, b"oops")), ("HTTP 429", (429, b"slow down")), ("a 200 that is not JSON", (200, b"<html>")),
                      ("a JSON list", jbody([])), ("vulns that is not a list", jbody({"vulns": "x"})),
                      ("a vuln with no id", jbody({"vulns": [{"summary": "s"}]}))):
    osv(lambda body, a=answer: a)
    check(f"OSV: {label} is a Cléa error, never an empty list", fails(lambda: clea.osv_ids(Q)))
osv(lambda body: (429, b"slow down"))
try: clea.osv_ids(Q)
except clea.CleaError as exc: check("OSV: a 429 does not tell the reader to export GITHUB_TOKEN", "GITHUB_TOKEN" not in str(exc) and "429" in str(exc))
clea.OSV_QUERY_URL = dead
check("OSV: an unreachable server is a Cléa error, never an empty list", fails(lambda: clea.osv_ids(Q)))
clea.OSV_QUERY_URL = BASE + "/osv/v1/query"

# Osv.ask: what each datasource is asked, and what unknown looks like
errs = []; session = clea.Osv(errs); POSTS.clear(); osv(lambda body: jbody({"vulns": [{"id": "GHSA-x"}]}))
check("OSV: a PyPI package is asked by name, ecosystem and exact version",
      session.ask("pypi", "acme-py", "1.0.0", None) == {"ids": ["GHSA-x"]} and POSTS[-1][2] == Q)
check("OSV: a GitHub-hosted release is asked by commit",
      session.ask("github-releases", "a/b", "v1", C1) == {"ids": ["GHSA-x"]} and POSTS[-1][2] == {"commit": C1})
n = len(POSTS)
check("OSV: a GitHub release whose commit is unknown is unknown, and nothing is sent",
      session.ask("github-tags", "a/b", "v1", None) == {"unknown": "commit of v1 unknown"} and len(POSTS) == n)
check("OSV: a datasource with no mapping is unknown, and nothing is sent",
      session.ask("helm", "cilium", "1.0.0", None) == {"unknown": "no OSV mapping for datasource helm"} and len(POSTS) == n)
session.ask("pypi", "acme-py", "1.0.0", None)
check("OSV: the same query is not sent twice", len(POSTS) == n)
errs = []; session = clea.Osv(errs); POSTS.clear(); osv(lambda body: (500, b"down"))
answers = [session.ask("pypi", f"p{i}", "1", None) for i in range(6)]
check("OSV: a failed query is unknown, and lands in the errors", answers[0] == {"unknown": "OSV did not answer"} and errs)
check("OSV: after three failures in a row it is not asked again", len(POSTS) == 3 and all("unknown" in a for a in answers))
errs = []; session = clea.Osv(errs); POSTS.clear()
script = iter([(500, b""), (500, b""), jbody({}), (500, b""), (500, b""), jbody({})])
osv(lambda body: next(script))
for i in range(6): session.ask("pypi", f"p{i}", "1", None)
check("OSV: an answer resets the count of failures", len(POSTS) == 6)

# --- a whole scan, offline: GitHub patched, PyPI and OSV on the local server --
C = {c: c * 40 for c in "abcdef98"}
DEPS = {  # dep: (published, candidate commit, current commit)
    "acme/ok": (ago(days=30), C["a"], C["b"]), "acme/mid": (ago(days=6), C["a"], C["b"]),
    "acme/young": (ago(days=2), C["a"], C["b"]), "acme/retagged": (ago(days=30), C["c"], C["b"]),
    "acme/advised": (ago(days=30), C["d"], C["b"]), "acme/pinadv": (ago(days=30), C["a"], C["e"]),
    "acme/undated": (None, C["a"], C["b"]), "acme/tagged": (None, C["f"], C["b"]),
    "acme/novee": (ago(days=30), C["a"], C["8"]),  # tags 1.0.0 / 1.1.0, no leading v
}
TAGS = {"acme/novee": ("1.1.0", "1.0.0")}
STATE = {"retag": C["c"], "retag_tag": "v1.1.0"}
def gh(path, token):
    m = re.match(r"/repos/(acme/[a-z]+)/(.*)", path)
    if not m or m.group(1) not in DEPS: raise clea.CleaError("unexpected " + path)
    name, rest = m.groups(); published, cand, cur = DEPS[name]
    tag, pinned = TAGS.get(name, ("v1.1.0", "v1.0.0"))
    if name == "acme/retagged": tag, cand = STATE["retag_tag"], STATE["retag"]
    if rest == "releases/latest":
        return {"tag_name": tag, "published_at": published, "html_url": "u", "draft": False, "prerelease": False}
    if rest == "tags?per_page=100": return [{"name": tag}]
    m = re.match(r"git/ref/tags/(.*)", rest)
    if m and m.group(1) in (tag, pinned):  # any other spelling of a tag is a 404, as on GitHub
        return {"ref": "refs/tags/" + m.group(1), "object": {"type": "commit", "sha": cand if m.group(1) == tag else cur}}
    if rest.startswith("git/commits/") and name == "acme/tagged": return {"committer": {"date": ago(days=40)}}
    raise clea.CleaError(f"{path}: no such thing in this fixture")
clea._gh_json = gh
PYDEPS = {"acme-py-ok": (ago(days=30), False), "acme-py-yanked": (ago(days=30), True), "acme-py-adv": (ago(days=30), False)}
def pypi_by_name(name):
    if name not in PYDEPS: return 404, b""
    at, yanked = PYDEPS[name]
    return 200, pypi_doc("1.1.0", [pypi_file(at, yanked, "broken build" if yanked else None)], yanked, "broken build" if yanked else None)
SERVER["pypi"] = pypi_by_name
ADVISED = {C["d"]: ["GHSA-aaaa-bbbb-cccc"], C["e"]: ["GHSA-pppp-pppp-pppp"], C["8"]: ["GHSA-novee"]}
def osv_by(body):
    if "commit" in body: ids = ADVISED.get(body["commit"], [])
    else: ids = ["PYSEC-2099-1"] if body["package"]["name"] == "acme-py-adv" and body["version"] == "1.1.0" else []
    return jbody({"vulns": [{"id": i} for i in ids]} if ids else {})
osv(osv_by)

work = tempfile.mkdtemp()
os.makedirs(work + "/.github/workflows")
sh = "".join(f'# clea-test: datasource={"github-tags" if n == "acme/tagged" else "github-releases"} depName={n} '
             f'extractVersion=^v(?<version>.*)$\n{n.split("/")[1].upper()}_V="1.0.0"\n' for n in DEPS)
open(work + "/install.sh", "w").write(sh)
open(work + "/.github/workflows/ci.yml", "w").write("jobs:\n  a:\n    steps:\n" + "".join(
    f"      # clea-test: datasource=pypi depName={n}\n      - run: pip install {n}==1.0.0\n" for n in PYDEPS))
open(work + "/clea.toml", "w").write('[scan]\nmarker = "# clea-test:"\n[policy]\nmin_release_age_days = 5\n')
os.environ["GITHUB_TOKEN"] = "t"

def scan(previous=None):
    path = work + "/state.json"
    argv = ["--root", work, "scan", "--state", path] + (["--previous", previous] if previous else [])
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        rc = clea.main(argv)
    out = io.StringIO()
    with contextlib.redirect_stdout(out): clea.main(["--root", work, "matrix", "--state", path])
    st = json.load(open(path)); snap = work + f"/state{len(os.listdir(work))}.json"
    json.dump(st, open(snap, "w"))
    return rc, st, clea.render_report(st), {e["dep"] for e in json.loads(out.getvalue())}, snap
def by(st, name): return next(d for d in st["deps"] if d["dep"] == name)

rc, st1, rep1, probed1, snap1 = scan()
OFFERED = {"acme/ok", "acme/mid", "acme/pinadv", "acme/retagged", "acme/tagged", "acme/novee", "acme-py-ok"}
check("scan: the policy is recorded in the state, from clea.toml (5, not the default 7)", st1["policy"] == {"min_release_age_days": 5})
check("scan: a 6-day-old release is offered under a 5-day policy, a 2-day-old one is not",
      "`acme/mid`" in offered_part(rep1) and "`acme/young`" not in offered_part(rep1))
held = rep1.split("## Held back")[1].split("## ")[0]
HELD = {"acme/young", "acme/undated", "acme-py-yanked", "acme/advised", "acme-py-adv"}
check("scan: the held-back table has exactly the young, undated, yanked and advised ones",
      {d["dep"] for d in st1["deps"] if f"`{d['dep']}`" in held} == HELD)
check("scan: a young release reads `too young, eligible on <date>`",
      f"too young, eligible on {(datetime.fromisoformat(DEPS['acme/young'][0].replace('Z', '+00:00')) + timedelta(days=5)).date()}" in held)
check("scan: an undated release reads `age unknown`", "age unknown" in held and by(st1, "acme/undated")["released_at"] is None)
check("scan: a yanked PyPI release is held with PyPI's reason", "yanked on PyPI: broken build" in held)
check("scan: an advisory against a candidate holds it and names the id",
      "advisory GHSA-aaaa-bbbb-cccc against v1.1.0" in held and "advisory PYSEC-2099-1 against 1.1.0" in held)
check("scan: a tag's date is read when upstream gives none (github-tags -> its commit's date)",
      by(st1, "acme/tagged")["released_at"] is not None and "`acme/tagged`" in offered_part(rep1))
check("scan: the age column shows the age", re.search(r"`acme/ok` \| `1\.0\.0` \| `1\.1\.0` \| 30 days \| none \|", rep1) is not None)
check("scan: the current pin's advisory is its own line, and the fix is offered",
      "`acme/pinadv` `1.0.0` — GHSA-pppp-pppp-pppp. `1.1.0` is offered above" in rep1)
check("scan: the pinned tag is found whether upstream's tags carry a v (v1.0.0) or not (1.0.0)",
      "`acme/novee` `1.0.0` — GHSA-novee" in rep1 and "`acme/pinadv` `1.0.0` — GHSA-pppp-pppp-pppp" in rep1)
check("scan: the probe matrix carries the offered ones only", probed1 == OFFERED)
check("scan: every pinned row records what OSV said for its pin",
      len([d for d in st1["deps"] if "current" in d.get("osv", {})]) == len(DEPS) + len(PYDEPS))

STATE["retag"] = C["9"]  # the same tag, another commit
rc, st2, rep2, probed2, snap2 = scan(snap1)
moved = by(st2, "acme/retagged")
check("scan: a tag that now points elsewhere is flagged, with both commits", moved["tag_moved"] == {"from": C["c"], "to": C["9"]})
check("scan: `moved_since_last_scan` alone does NOT see it (the version string is the same)", moved["moved_since_last_scan"] is False)
check("scan: the retagged release is held back and not probed",
      "moved since last scan (ccccccc → 9999999)" in rep2 and "acme/retagged" not in probed2 and probed2 == OFFERED - {"acme/retagged"})
rc, st3, rep3, probed3, snap3 = scan(snap2)
check("scan: the hold survives the next scan, where the commit no longer changes",
      by(st3, "acme/retagged")["tag_moved"] == {"from": C["c"], "to": C["9"]} and "acme/retagged" not in probed3)
STATE["retag_tag"], STATE["retag"] = "v1.2.0", C["f"]
rc, st4, rep4, probed4, snap4 = scan(snap3)
check("scan: a new tag is a new release: the hold is gone", "tag_moved" not in by(st4, "acme/retagged") and "acme/retagged" in probed4)
old_state = json.load(open(snap1)); old_state["deps"] = [{k: v for k, v in d.items() if k != "tag_commit"} for d in old_state["deps"]]
json.dump(old_state, open(work + "/legacy.json", "w"))
STATE["retag_tag"], STATE["retag"] = "v1.1.0", C["9"]
rc, st5, rep5, probed5, _ = scan(work + "/legacy.json")
check("scan: a previous state with no recorded commit flags nothing (it cannot know)", "tag_moved" not in by(st5, "acme/retagged"))

clea.OSV_QUERY_URL = dead
rc, st6, rep6, probed6, _ = scan()
check("scan, OSV unreachable: every row says its advisories are unknown",
      all(d["osv"]["current"] == {"unknown": "OSV did not answer"} for d in st6["deps"])
      and all(d["osv"]["candidate"] == {"unknown": "OSV did not answer"} for d in st6["deps"] if d.get("behind")))
check("scan, OSV unreachable: the report reads `advisories unknown` and never `none` for a candidate",
      "advisories unknown |" in offered_part(rep6) and "| none |" not in offered_part(rep6) and "None against" not in rep6)
check("scan, OSV unreachable: the failure is in the errors, so --strict fails", any(clea.OSV_QUERY_URL in e for e in st6["errors"]))
check("scan, OSV unreachable: unknown holds nothing back (the two advised ones are probed, as OSV cannot say)",
      probed6 == OFFERED | {"acme/advised", "acme-py-adv"})
clea.OSV_QUERY_URL = BASE + "/osv/v1/query"

for bad in ("-1", '"7"', "true", "7.5"):
    open(work + "/clea.toml", "w").write(f'[scan]\nmarker = "# clea-test:"\n[policy]\nmin_release_age_days = {bad}\n')
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        rc = clea.main(["--root", work, "scan", "--state", work + "/x.json"])
    check(f"scan: min_release_age_days = {bad} is refused, naming the key", rc == 1 and "min_release_age_days" in err.getvalue())

# --- Renovate and Cléa read one number ---------------------------------------
from pathlib import Path
cfg = clea.load_json5(Path(os.environ["RENOVATE_CFG"]))
import tomllib  # the file itself, not load_config: a deleted knob must not hide behind the default
days_set = tomllib.loads(Path(os.environ["CLEA_TOML"]).read_text()).get("policy", {}).get("min_release_age_days")
m = re.fullmatch(r"(\d+) days?", str(cfg.get("minimumReleaseAge", "")))
check("renovate.json5 sets minimumReleaseAge, in days", m is not None)
check("…to the same number clea.toml sets, so the two agree",
      m is not None and days_set is not None and int(m.group(1)) == days_set and days_set > 0)

httpd.shutdown()
for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + name)
open(os.environ["COUNTFILE"], "w").write(str(len(checks)))
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
rc=$?
if [ "$rc" -eq 0 ]; then PASS=$((PASS + $(cat "$TMP/count-offer"))); else FAIL=$((FAIL + 1)); fi

echo "=== renovate.json5 reads every SHA-pinned pre-commit hook (#88) ==="
# The native pre-commit manager reads the SHA in `rev: <sha>  # vX` as a tag and
# can never bump it (hosted job log 2026-10-03: "Tag <sha> not found", five times),
# so a custom manager carries them. Run against the real files; RENOVATE_CFG and
# PRECOMMIT_CFG point the same checks at a mutated copy.
RENOVATE_CFG="${RENOVATE_CFG:-$ROOT/renovate.json5}" PRECOMMIT_CFG="${PRECOMMIT_CFG:-$ROOT/.pre-commit-config.yaml}" python3 - <<'PY'
import json, os, re, sys
cfg = open(os.environ["RENOVATE_CFG"]).read()
hooks = open(os.environ["PRECOMMIT_CFG"]).read()
lits = re.findall(r'"((?:[^"\\\n]|\\.)*currentDigest(?:[^"\\\n]|\\.)*)"', cfg)
pat = re.compile(re.sub(r"\(\?<(\w+)>", r"(?P<\1>", json.loads('"' + lits[0] + '"'))) if lits else None
found = list(pat.finditer(hooks)) if pat else []
pinned = len(re.findall(r"^\s*rev:\s*[0-9a-f]{40}\b", hooks, re.M))
checks = [
    ("a custom manager names currentDigest and a tag", pat is not None),
    ("it reads every SHA-pinned hook of .pre-commit-config.yaml", pinned > 0 and len(found) == pinned),
    ("each match carries owner/repo, a 40-hex digest and a version tag",
     bool(found) and all("/" in m["depName"] and re.fullmatch(r"[0-9a-f]{40}", m["currentDigest"])
                         and re.match(r"v?\d", m["currentValue"]) for m in found)),
    ("the `repo: local` block is not read as a dependency", all(m["depName"] != "local" for m in found)),
    ("it looks the tags up as github-tags", re.search(r'datasourceTemplate:\s*"github-tags"', cfg) is not None),
    ("the native pre-commit manager is off, so it cannot fail on the same lines",
     re.search(r'"pre-commit":\s*\{\s*enabled:\s*false\s*\}', cfg) is not None),
]
for name, ok in checks:
    print(("  \033[32m\u2713\033[0m " if ok else "  \033[31m\u2717\033[0m ") + name)
sys.exit(1 if [c for c in checks if not c[1]] else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 6)); else FAIL=$((FAIL + 1)); fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
