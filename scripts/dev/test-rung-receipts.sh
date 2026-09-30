#!/usr/bin/env bash
# rung-receipt.py (#120): the receipt a rung target writes, and the PR check that
# compares it with the declared rung. The receipts come from the REAL Taskfile.yml
# under go-task, copied into a throwaway repository so the sha and the dirty flag
# are known; `feint` is a stub, so nothing reaches a network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

echo "=== the Taskfile and the script agree on which targets are rungs ==="

# A defer registered after a failing command never runs, so it must come first.
if out="$(python3 - "$ROOT" <<'PY'
import importlib.util, re, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("rr", f"{root}/scripts/dev/rung-receipt.py")
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
task, first_cmd, first, anywhere, tasks = None, False, set(), set(), set()
for line in open(f"{root}/Taskfile.yml"):
    if m := re.match(r"^  ([\w:-]+):\s*$", line):
        task, first_cmd = m.group(1), False
        tasks.add(task)
    elif line.rstrip() == "    cmds:":
        first_cmd = True
    elif re.match(r"^      - ", line):
        receipt = re.match(r"^      - defer: [*&]receipt\s*$", line)
        if first_cmd and receipt:
            first.add(task)
        if receipt:
            anywhere.add(task)
        first_cmd = False
problems = [f"{t}: in TARGETS, but its first command is not `defer: *receipt`"
            for t in sorted(set(rr.TARGETS) - first)]
problems += [f"{t}: carries the receipt defer, but is not in TARGETS" for t in sorted(anywhere - set(rr.TARGETS))]
problems += [f"{t}: the receipt defer is not its first command" for t in sorted(anywhere - first)]
# A new target in a rung family must be classified, or it silently writes nothing.
family = {t for t in tasks if re.match(r"(test|feint|local|infra|cluster)(-|$)", t)}
problems += [f"{t}: neither in TARGETS nor in EXCLUDED" for t in sorted(family - set(rr.TARGETS) - set(rr.EXCLUDED))]
problems += [f"{t}: in EXCLUDED, but no such target" for t in sorted(set(rr.EXCLUDED) - tasks)]
problems += [f"{t}: in both TARGETS and EXCLUDED" for t in sorted(set(rr.TARGETS) & set(rr.EXCLUDED))]
problems += [f"{t}: in PLANS, but not a real-cloud target" for t in sorted(rr.PLANS)
             if rr.TARGETS.get(t, ("",))[0] != "real-cloud"]
print("\n".join(problems) or f"{len(first)} rung targets start with the receipt defer; "
      f"{len(rr.EXCLUDED)} family members excluded, each with a reason")
sys.exit(1 if problems else 0)
PY
)"; then ok "$out"; else bad "$out"; fi

git -C "$ROOT" check-ignore -q .receipts/mocked.jsonl &&
  ok ".receipts/ is gitignored" || bad ".receipts/ is NOT gitignored: a receipt is one \`git add -A\` from a commit"

echo
echo "=== a rung target records its outcome, red runs included ==="

repo="$TMP/repo"
mkdir -p "$repo/scripts/dev" "$TMP/bin"
# .gitignore too: an untracked file marks a run dirty, and .receipts/ is one.
cp "$ROOT/Taskfile.yml" "$ROOT/.gitignore" "$repo/"
cp "$ROOT/scripts/dev/rung-receipt.py" "$ROOT/scripts/dev/feint.sh" "$ROOT/scripts/dev/ssh-ca-check.sh" \
  "$repo/scripts/dev/"
printf 'a tracked file\n' >"$repo/notes"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q && g add -A && g commit -q -m fixture
sha="$(g rev-parse HEAD)"
# STUB_MIDRUN=commit|edit: what someone does in the repository while the run goes on.
cat >"$TMP/bin/feint" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { echo "feint v9.9.9"; exit 0; }
case "${STUB_MIDRUN:-}" in
  commit) git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m mid-run ;;
  edit) printf 'edited mid-run\n' >>notes ;;
esac
exit "${STUB_RC:-0}"
EOF
chmod +x "$TMP/bin/feint"

receipts="$repo/.receipts/emulated.jsonl"
run() { STUB_RC="$1" PATH="$TMP/bin:$PATH" task --dir "$repo" feint-evidence-verify PROVIDER=outscale >"$TMP/out" 2>&1; }
last() { tail -n 1 "$receipts" 2>/dev/null; }
field() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]).get(sys.argv[2])))' "$1" "$2" 2>/dev/null; }

PATH="$TMP/bin:$PATH" task --dir "$repo" --dry feint-evidence-verify PROVIDER=outscale >/dev/null 2>&1
[ ! -e "$receipts" ] && ok "task --dry records nothing: nothing ran" || bad "task --dry wrote a receipt: $(cat "$receipts")"

run 3; rc=$?
[ "$rc" -ne 0 ] && ok "a red run stays red with the defer (task rc=$rc)" || bad "the receipt defer turned a red run green"
RED="$(last)"
[ "$(field "$RED" rc)" = 3 ] && ok "the red run's receipt records the command's own rc, 3" ||
  bad "red run: expected rc 3 in a receipt, got '${RED:-no receipt}' — $(cat "$TMP/out")"

printf '# an uncommitted edit\n' >>"$repo/Taskfile.yml"
run 0
DIRTY="$(last)"
[ "$(field "$DIRTY" dirty)" = true ] && ok "a run over uncommitted edits is recorded dirty" || bad "dirty run: got '$DIRTY'"
g checkout -q -- Taskfile.yml

run 0; rc=$?
GREEN="$(last)"
want="{\"rung\":\"emulated\",\"target\":\"feint-evidence-verify\",\"tool\":\"feint\",\"version\":\"9.9.9\",\"rc\":0,\"sha\":\"$sha\",\"dirty\":false,"
[ "$rc" -eq 0 ] && [[ "$GREEN" == "$want"* ]] && [[ "$(field "$GREEN" utc)" =~ ^\"[0-9-]{10}T[0-9:]{8}Z\"$ ]] &&
  [ "$(field "$GREEN" provider)" = '"outscale"' ] && ok "a green run records rung, target, tool, version, rc 0, sha, utc, provider" ||
  bad "green run (rc=$rc): got '$GREEN'"
[ "$(wc -l <"$receipts")" -eq 3 ] && ok "one line per run, appended" || bad "expected 3 lines in $receipts"

shown="$(python3 "$repo/scripts/dev/rung-receipt.py" show)"
[ "$shown" = "$GREEN" ] && ok "show prints the latest receipt per target for HEAD" || bad "show printed: $shown"

# The receipt vouches for the tree the run STARTED from. HEAD must have moved, or
# the case proves nothing.
STUB_MIDRUN=commit run 0
MID="$(last)"
[ "$(g rev-parse HEAD)" != "$sha" ] && [ "$(field "$MID" sha)" = "\"$sha\"" ] && [ "$(field "$MID" dirty)" = false ] &&
  ok "a commit made mid-run: the receipt names the sha the run started on" ||
  bad "mid-run commit: HEAD is $(g rev-parse HEAD), expected a new commit and a receipt for $sha, got '$MID'"
g reset -q "$sha"
STUB_MIDRUN=edit run 0
[ "$(field "$(last)" dirty)" = false ] && ok "an edit made mid-run does not mark a clean start dirty" ||
  bad "mid-run edit: got '$(last)'"
g checkout -q -- notes
printf 'resource "null_resource" "x" {}\n' >"$repo/new.tf"
run 0
[ "$(field "$(last)" dirty)" = true ] && ok "an untracked file at the start marks the run dirty" ||
  bad "untracked file: got '$(last)'"
rm "$repo/new.tf"
# An edit, then a damaged index: rev-parse still answers, git status fails.
printf 'edited\n' >>"$repo/notes"
printf 'not an index\n' >"$repo/.git/index"
run 0
[ "$(field "$(last)" dirty)" = true ] && ok "a git status that fails at the start marks the run dirty" ||
  bad "failing git status: got '$(last)'"
rm "$repo/.git/index" && g reset -q && g checkout -q -- notes

# Without Docker the script skips with exit 0: the target must refuse instead.
mkdir -p "$TMP/nodocker"
for t in bash env dirname git grep python3; do ln -s "$(command -v "$t")" "$TMP/nodocker/$t"; done
PATH="$TMP/nodocker" "$(command -v task)" --dir "$repo" ssh-ca-check >"$TMP/out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && ! grep -qs '"ssh-ca-check"' "$repo/.receipts/local-docker.jsonl" &&
  ok "ssh-ca-check without Docker is refused and records nothing (task rc=$rc)" ||
  bad "ssh-ca-check without Docker: rc=$rc, receipts: $(cat "$repo/.receipts/local-docker.jsonl" 2>/dev/null)"

# <rung file> <target> <provider> <rc>: a receipt as the defer would write it for $sha.
rec() {
  python3 "$repo/scripts/dev/rung-receipt.py" record "$2" "$3" "$4" "$sha 0" 2>/dev/null
  tail -n 1 "$repo/.receipts/$1.jsonl"
}
MOCKED="$(rec mocked test "" "")"
[ "$(field "$MOCKED" provider)" = '"none"' ] && ok "a target with no PROVIDER records provider none" || bad "mocked: '$MOCKED'"
MOCKED_RED="$(rec mocked test-scripts "" 1)"
PLAN="$(rec real-cloud infra-plan scaleway "")"
UP="$(rec real-cloud cluster-up scaleway "")"
UP_RED="$(rec real-cloud cluster-up scaleway 201)"

g commit -q --allow-empty -m next
python3 "$repo/scripts/dev/rung-receipt.py" show >/dev/null 2>&1 &&
  bad "show printed receipts for a commit nothing ran on" || ok "show refuses when nothing ran on HEAD"

echo
echo "=== the PR check: declared rung against the pasted receipt ==="

# <name> <want rc> <want text> <author> <docs_only> <head> <body>. Any body is judged
# within 2 s: rc 124 is the timeout.
expect() {
  local name="$1" want="$2" text="$3" out rc
  out="$(PR_AUTHOR="$4" DOCS_ONLY="$5" PR_HEAD_SHA="$6" PR_BODY="$7" \
    timeout 2 python3 "$ROOT/scripts/dev/rung-receipt.py" check 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && grep -qF -- "$text" <<<"$out" && [ "$(wc -l <<<"$out")" -eq 1 ]; then
    ok "$name"
  else
    bad "$name: rc=$rc (want $want, '$text'), got: $out"
  fi
}
body() { printf 'What changes.\n\nRung: %s\n\n```receipts\n' "$1"; shift; printf '%s\n' "$@"; printf '```\n'; }
other="$(printf '%040d' 0)"
template="$(cat "$ROOT/.github/pull_request_template.md")"

expect "match: emulated declared, green emulated receipt" 0 "emulated at" h false "$sha" "$(body emulated "$GREEN")"
expect "match: the template's label 'emulated (Feint)'" 0 "emulated at" h false "$sha" "$(body 'emulated (Feint)' "$GREEN")"
expect "match: mocked declared, mocked receipt beside a higher one" 0 "mocked at" h false "$sha" "$(body mocked "$GREEN" "$MOCKED")"
expect "match: a body edited on github.com (CRLF)" 0 "emulated at" h false "$sha" "$(body emulated "$GREEN" | sed 's/$/\r/')"
expect "missing: a rung declared, no receipt" 1 "no receipt pasted" h false "$sha" "$(body emulated)"
expect "missing: the untouched template declares nothing" 1 "no rung declared" h false "$sha" "$template"
expect "missing: what GitHub does not render does not count" 1 "no rung declared" h false "$sha" \
  "<!-- $(body emulated "$GREEN") -->"
expect "wrong sha: a receipt for another commit" 1 "the PR head is" h false "$other" "$(body emulated "$GREEN")"
expect "malformed: a receipt that is not JSON" 1 "is not JSON" h false "$sha" "$(body emulated "$GREEN" '{"rung": "emulated",')"
expect "malformed: a receipt missing a field" 1 "is not a receipt" h false "$sha" \
  "$(body emulated "${GREEN/\"sha\":\"$sha\",/}")"
expect "lower rung: real cloud declared, mocked and emulated receipts" 1 "a lower rung" h false "$sha" \
  "$(body 'real cloud' "$MOCKED" "$GREEN")"
expect "higher rung only: mocked declared, only an emulated receipt" 1 "no receipt is for it" h false "$sha" \
  "$(body mocked "$GREEN")"
expect "red: the only emulated receipt is a failed run" 1 "is red: feint-evidence-verify" h false "$sha" \
  "$(body emulated "$RED")"
expect "red: a failed run beside a green one of the declared rung" 1 "is red: cluster-up" h false "$sha" \
  "$(body 'real cloud' "$UP" "$UP_RED")"
expect "red: a failed run below the declared rung" 1 "is red: test-scripts" h false "$sha" \
  "$(body emulated "$GREEN" "$MOCKED_RED")"
expect "red above the declared rung: a higher attempt that failed is allowed" 0 "mocked at" h false "$sha" \
  "$(body mocked "$MOCKED" "$RED")"
expect "plan: a plan alone does not stand for real cloud" 1 "only a plan" h false "$sha" \
  "$(body 'real cloud' "$PLAN" "$MOCKED")"
expect "plan: cluster-up stands for real cloud, the plan beside it is not named" 0 \
  "real cloud at ${sha:0:12}: cluster-up green" h false "$sha" "$(body 'real cloud' "$PLAN" "$UP")"
# Each body below went through GitHub's renderer (POST /markdown, gfm), and the verdict
# follows what it displays. Where a comment is left open with more after it, GitHub's own
# HTML parser decides where it ends: the check refuses instead of guessing.
shown() { expect "GitHub shows it: $1" 0 "emulated at" h false "$sha" "$2"; }
hidden() { expect "GitHub hides it: $1" 1 "${3:-no rung declared}" h false "$sha" "$2"; }
stricter() { expect "GitHub shows it, the check does not: $1" 1 "${3:-$left}" h false "$sha" "$2"; }
left="close the HTML comment"
rcpt() { printf '\n```receipts\n%s\n```\n' "$GREEN"; }
hidden "an unclosed comment at the top level" "$(printf 'Visible.\n\n<!-- never closed\n\n'; body emulated "$GREEN")"
hidden "an unclosed comment opening a list item" \
  "$(printf 'Visible text.\n\n- <!-- a note never closed\n  Rung: emulated\n\n  ```receipts\n  %s\n  ```\n' "$GREEN")"
hidden "an unclosed comment in a nested list item, four spaces in" \
  "$(printf -- '- a\n  - b\n\n    <!-- never closed\n\n'; body emulated "$GREEN")" "$left"
hidden "a quote that ends does not end its comment" "$(printf '> <!-- never closed\n\n'; body emulated "$GREEN")" "$left"
hidden "a --> in text after the list item is not raw" \
  "$(printf -- '- <!-- never closed\n\n-->\n'; body emulated "$GREEN")" "$left"
hidden "a comment pair split by a list item closes nothing" \
  "$(printf -- '- <!-- a\n\ntext <!-- b\n- c -->\n'; body emulated "$GREEN")" "$left"
hidden "a comment in inline code closes nothing" \
  "$(printf -- '- <!-- never closed\n\nUse `<!-- x -->` to comment.\n\n'; body emulated "$GREEN")" "$left"
hidden "an escaped comment closes nothing" \
  "$(printf -- '- <!-- never closed\n\nWrite \\<!-- x --> literally.\n\n'; body emulated "$GREEN")" "$left"
hidden "an inline comment on an indented line closes nothing" \
  "$(printf -- '- <!-- a\n# H\n    b <!-- c --> d\n\n'; body emulated "$GREEN")" "$left"
hidden "a comment in a link title closes nothing" \
  "$(printf -- '- <!-- never closed\n\nSee [the template](/x "<!-- y -->").\n\n'; body emulated "$GREEN")" "$left"
hidden "a line indented less than the item ends it" \
  "$(printf -- '- <!-- never closed\n x\n ```\n<!-- y -->\n ```\n\n'; body emulated "$GREEN")" "$left"
hidden "an unclosed comment after an HTML tag" "$(printf '<div><!-- never closed\n\n'; body emulated "$GREEN")" "$left"
hidden "a comment spanning the lines of one paragraph" \
  "$(printf 'Some text <!-- starts here\nRung: emulated\n-->\n\n```receipts\n%s\n```\n' "$GREEN")" "found 0"
hidden "a reference definition whose title spans lines" \
  "$(printf 'Text.\n\n[x]: /url "\nRung: emulated\n"\n'; rcpt)" "found 0"
hidden "a link title spanning lines" "$(printf 'See [x](/u "\nRung: emulated\n").\n'; rcpt)" "found 0"
hidden "a tag attribute spanning lines" "$(printf 'See <span title="\nRung: emulated\n">it</span>.\n'; rcpt)" "found 0"
hidden "a tag attribute spanning lines in an HTML block" "$(printf '<div title="\nRung: emulated\n">\n'; rcpt)" "found 0"
hidden "a processing instruction spanning lines" "$(printf 'Text <?x\nRung: emulated\n?> more.\n'; rcpt)" "found 0"
hidden "an unclosed <? at the top level" "$(printf '<?\n\n'; body emulated "$GREEN")"
hidden "a heading ends the paragraph a code span would close in" \
  "$(printf '# a `b\nx <!-- \nRung: emulated\n--> `\n'; rcpt)" "found 0"
hidden "a lazy line keeps the list item open" \
  "$(printf -- '- a\nb\n  ```\n<!-- y\n  ```\n\n'; body emulated "$GREEN")"
hidden "a fence ends the list item after a lazy line" \
  "$(printf -- '- a\n b\n ```\n~~~\n ```\n<!--\n'; body emulated "$GREEN")"
hidden "an image's text is its alt attribute" "$(printf 'Text ![\nRung: emulated\n](x.png) more.\n'; rcpt)" "found 0"
hidden "a reference link's label" "$(printf 'See [a][\nRung: emulated\n].\n\n[rung: emulated]: /x\n'; rcpt)" "found 0"
hidden "a label nothing defines is text: a comment in it opens" \
  "$(printf 'See [a][<!--]\nRung: emulated\n-->\n'; rcpt)" "found 0"
hidden "a link in a link's text: the outer one is text, a comment in its title opens" \
  "$(printf 'See [a [b](c) d](/x "<!--")\nRung: emulated\n-->\n'; rcpt)" "found 0"
hidden "a title after parentheses nested twice in the destination" \
  "$(printf 'See [a](/x((y)) "\nRung: emulated\n")\n'; rcpt)" "found 0"
hidden "a no-break space in a destination" "$(printf '[a](/x\302\240y "\nRung: emulated\n")\n'; rcpt)" "found 0"
hidden "a footnote nothing references, its lazy line with it" \
  "$(printf 'Text.\n\n[^n]: a note\nRung: emulated\n'; rcpt)" "found 0"
hidden "a footnote definition interrupts a paragraph" \
  "$(printf 'Text.\n[^n]: a note\n    Rung: emulated\n'; rcpt)" "found 0"
hidden "a lone CR ends a line" "$(printf 'x\r[^n]: a\n    Rung: emulated\n'; rcpt)" "found 0"
hidden "a no-break space line does not end an HTML block" \
  "$(printf '<div>\n\302\240\nsee <!-- x\n\n'; body emulated "$GREEN")" "$left"
stricter "the template's next comment closes one left open" \
  "$(printf -- '- <!-- todo\n\n## Rung\n\n<!-- The highest rung\n     more -->\n'; body emulated "$GREEN")"
stricter "an inline comment on an unindented line closes one left open" \
  "$(printf -- '- <!-- never closed\n\nsome text <!-- y --> more\n\n'; body emulated "$GREEN")"
stricter "an empty <!--> comment closes one left open" \
  "$(printf -- '- <!-- never closed\n\ntext <!--> more\n\n'; body emulated "$GREEN")"
stricter "a footnote someone references is moved to the end" \
  "$(printf 'Text[^n].\n\n[^n]: a note\n    Rung: emulated\n'; rcpt)" "found 0"
shown "an empty <!--> comment is a whole one" "$(printf '<!--> a note\n\n'; body emulated "$GREEN")"
shown "a fence indented once the list has ended holds its <!-- line" \
  "$(printf -- '- item\n\nText.\n\n  ```\n<!-- inside an indented fence\n  ```\n\n'; body emulated "$GREEN")"
shown "a fence in a list item holds its <!-- line" \
  "$(printf -- '- item\n\n  ```\n  <!-- inside\n  ```\n\n'; body emulated "$GREEN")"
shown "a fence is no lazy line: it ends the list item" \
  "$(printf -- '- a\n b\n ```\n<!-- inside\n ```\n\n'; body emulated "$GREEN")"
shown "an empty list item cannot interrupt a paragraph" \
  "$(printf 'Title\n-\n  ```\n<!-- inside\n  ```\n\n'; body emulated "$GREEN")"
shown "an ordered list starting at 2 cannot interrupt a paragraph" \
  "$(printf 'Text\n2. x\n   ```\n<!-- inside\n   ```\n\n'; body emulated "$GREEN")"
shown "* * * is a thematic break, not a list item" \
  "$(printf -- '- a\n\n* * *\n  ```\n<!-- inside\n  ```\n\n'; body emulated "$GREEN")"
shown "a list item may start with one blank line, not two" \
  "$(printf -- '-\n\n  x\n  ```\n<!-- y\n  ```\n\n'; body emulated "$GREEN")"
shown "a tag line cannot interrupt a paragraph" "$(printf 'Text\n<span>\nx <!-- y\n\n'; body emulated "$GREEN")"
shown "<!-- in a code span, --> later in the paragraph" \
  "$(printf 'Mentions `<!--` here,\nRung: emulated\nand `-->` there.\n'; rcpt)"
shown "an escaped <!--, --> later in the paragraph" \
  "$(printf 'Writes \\<!-- literally,\nRung: emulated\nand --> after.\n'; rcpt)"
shown "<!-- in a link title, --> later in the paragraph" \
  "$(printf 'See [the template](/x "<!--")\nRung: emulated\nand --> after.\n'; rcpt)"
shown "<!-- in a link destination, --> later in the paragraph" \
  "$(printf 'See [a](<!--x>)\nRung: emulated\nand --> after.\n'; rcpt)"
shown "<!-- in a reference definition's title, --> after it" \
  "$(printf '[ref]: /x "<!--"\nRung: emulated\n-->\n'; rcpt)"
shown "a reference definition cannot interrupt a paragraph" \
  "$(printf 'Text.\n[x]: /url "\nRung: emulated\n"\n'; rcpt)"
shown "a control character does not end a destination" \
  "$(printf 'See [a](/x\001 "<!--")\nRung: emulated\n-->\n'; rcpt)"
shown "an unclosed \`<!--\` in inline code" "$(printf 'Mentions an unclosed `<!--` in passing.\n\n'; body emulated "$GREEN")"
shown "\`<!--\` in inline code, a comment later" \
  "$(printf 'Mentions `<!--` in passing.\n\n'; body emulated "$GREEN"; printf '\n<!-- a note -->\n')"
shown "a fenced line starting with <!--" \
  "$(printf 'Quoting the template:\n\n```markdown\n<!-- The highest rung\n```\n\n'; body emulated "$GREEN")"
shown "the whole template quoted in a fence" \
  "$(printf 'Changes the template:\n\n````markdown\n%s\n````\n\n' "$template"; body emulated "$GREEN")"
shown "an unclosed comment in an indented code block" \
  "$(printf 'Text.\n\n    <!-- in an indented code block\n\n'; body emulated "$GREEN")"
shown "an indented code block holds a comment and the Rung line" \
  "$(printf 'Text.\n\n    x <!-- y\n    Rung: emulated\n    -->\n'; rcpt)"
rep() { python3 -c 'import sys; a, u, n, z = sys.argv[1:]; print(a + u * int(n) + z, end="")' "$@"; }
hidden "an image label of 319 bytes that tabs widen past 1000 characters" \
  "$(printf '[x Rung: emulated y y]: /u\n\n![x\nRung: emulated\ny%sy]\n' "$(rep '' $'\t' 300 '')"; rcpt)" "found 0"
# Bodies up to GitHub's 65536-character limit, each built to make one part of the model
# quadratic: a regex that backtracks, or a rescan per opener, per level or per span.
expect "slow: a Rung value holding a long run of spaces" 1 "is not one of" h false "$sha" "$(rep 'Rung: x' ' ' 65527 y)"
expect "slow: list items nested 32767 deep are refused" 1 "nest at most 32" h false "$sha" "$(rep '' '- ' 32767 x)"
expect "list items nested 32 deep are modelled" 0 "emulated at" h false "$sha" \
  "$(rep '' '- ' 32 x; printf '\n\n'; body emulated "$GREEN")"
expect "slow: <? opened 32767 times, never closed" 1 "no rung declared" h false "$sha" "$(rep 'x ' '<?' 32767 '')"
expect "slow: <!-- opened 9362 times, then tabs and one >" 1 "no rung declared" h false "$sha" \
  "$(rep "$(rep 'x ' '<!--' 9362 '')" $'\t' 28085 '>')"
expect "slow: <![CDATA[ opened 4161 times, then tabs and one >" 1 "no rung declared" h false "$sha" \
  "$(rep "$(rep 'x ' '<![CDATA[' 4161 '')" $'\t' 28084 '>')"
# Twice the limit: within it, the unguarded `<!` scan barely outlasts the 2 s timeout, so a
# faster host would not see it red.
expect "slow: <!a opened 24000 times, then tabs" 1 "no rung declared" h false "$sha" \
  "$(rep "$(rep 'x ' '<!a' 24000 '')" $'\t' 58000 '')"
expect "slow: a tag on each of 16384 lines" 1 "no rung declared" h false "$sha" "$(rep '' $'<b>\n' 16384 '')"
expect "slow: 32768 brackets opened, then closed" 1 "no rung declared" h false "$sha" \
  "$(rep "$(rep '' '[' 32768 '')" ']' 32768 '')"
expect "slow: 5461 links after 32768 open brackets" 1 "no rung declared" h false "$sha" \
  "$(rep "$(rep '' '[' 32768 '')" '[a](b)' 5461 '')"
expect "slow: 32768 backticks, then a backtick among tabs" 1 "no rung declared" h false "$sha" \
  "$(rep "$(rep '' '`' 32768 $'\t`')" $'\t' 32766 '')"
expect "a receipt nested deeper than the JSON decoder recurses" 1 "is not JSON" h false "$sha" \
  "$(body emulated "$(rep '' '[' 60000 '')")"
expect "forged: a target this script never writes stays on one log line" 1 "is not a" h false "$sha" \
  "$(body emulated "${GREEN/\"target\":\"feint-evidence-verify\"/\"target\":\"x\\n::error::y\"}")"
expect "forged: an unknown target with an empty rung" 1 "is not a" h false "$sha" \
  "$(body emulated "${GREEN/\"rung\":\"emulated\",\"target\":\"feint-evidence-verify\"/\"rung\":\"\",\"target\":\"x\"}")"
expect "forged: a target filed under another rung" 1 "is not a" h false "$sha" \
  "$(body 'real cloud' "${MOCKED/\"rung\":\"mocked\"/\"rung\":\"real-cloud\"}")"
expect "forged: rc false is not rc 0" 1 "rc must be an integer" h false "$sha" \
  "$(body emulated "${GREEN/\"rc\":0/\"rc\":false}")"
expect "dirty: recorded over uncommitted edits" 1 "uncommitted" h false "$sha" "$(body emulated "$DIRTY")"
expect "vocabulary: 'tested' is not a rung" 1 "is not one of" h false "$sha" "$(body tested "$GREEN")"
expect "two different rungs declared" 1 "exactly one" h false "$sha" "$(printf 'Rung: mocked\n'; body emulated "$GREEN")"
expect "an empty Rung: line with trailing blanks declares nothing" 0 "emulated at" h false "$sha" \
  "$(printf 'Rung: \t \n'; body emulated "$GREEN")"
expect "one rung declared twice, with blanks around it, is one declaration" 0 "emulated at" h false "$sha" \
  "$(printf 'Rung:  emulated \t \n'; body emulated "$GREEN")"
expect "a hostile sha stays on one log line" 1 "the PR head is" h false "$sha" \
  "$(body emulated "${GREEN/\"sha\":\"$sha\"/\"sha\":\"x\\n::error::y\"}")"
expect "renovate[bot] may declare nothing" 0 "renovate[bot]" "renovate[bot]" false "$sha" "Bumps a pin."
expect "renovate[bot]'s declared rung is still checked" 1 "a lower rung" "renovate[bot]" false "$sha" \
  "$(body 'real cloud' "$GREEN")"
expect "a human named like the bot is not exempt" 1 "no rung declared" renovate false "$sha" "Bumps a pin."
expect "a docs-only diff may declare nothing" 0 "docs-only" h true "$sha" "$template"
expect "a docs-only diff's declared rung is still checked" 1 "no receipt pasted" h true "$sha" "$(body mocked)"
expect "a head that is not a sha is refused" 1 "not a commit sha" h false "" "$(body emulated "$GREEN")"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
