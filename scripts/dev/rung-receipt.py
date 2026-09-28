#!/usr/bin/env python3
"""Rung receipts: what the harness ran, on which commit, and how it ended (#120).

CONTRIBUTING.md asks a pull request to say which rung it reached. A sentence
cannot be checked; a line the harness wrote can. Every rung target in
Taskfile.yml calls `record` from a defer, so a red run leaves a receipt too.

  record <target> <provider> <rc> <start>   append to .receipts/<rung>.jsonl (Taskfile only)
  show                                      the latest receipt per target for HEAD, to paste
  check                                     CI: PR_BODY, PR_HEAD_SHA, PR_AUTHOR, DOCS_ONLY

`check` passes when a target that can stand for the declared rung has a green
receipt for the PR head, started on a clean tree, and no pasted run at or below
that rung is red. A receipt makes the claim falsifiable, not unforgeable:
nothing offline can prove a line was not typed by hand.
"""
import json
import os
import re
import subprocess
import sys
from bisect import bisect_right
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# .github/ISSUE_TEMPLATE/report.yml's vocabulary, lowest rung first.
RUNGS = {"mocked": "mocked", "emulated": "emulated", "local-docker": "local Docker",
         "real-cloud": "real cloud"}
ORDER = list(RUNGS)

# Taskfile target -> (rung, the binary that rung is named after). test-rung-receipts.sh
# fails when this and the targets starting with `defer: *receipt` disagree.
TARGETS = {
    "test": ("mocked", "tofu"),
    "test-scripts": ("mocked", "bash"),
    **dict.fromkeys(("feint-plan", "feint-apply", "feint-apply-root", "feint-evidence",
                     "feint-evidence-verify"), ("emulated", "feint")),
    **dict.fromkeys(("local-up", "local-verify", "local-rbac", "local-test", "test-gates-local",
                     "test-cnpg-gates-local", "ssh-ca-check"), ("local-docker", "docker")),
    **dict.fromkeys(("infra-plan", "infra-apply", "infra-down-plan", "infra-down", "cluster-up",
                     "cluster-verify", "cluster-roll", "cluster-upgrade", "cluster-idempotency",
                     "cluster-down"), ("real-cloud", "tofu")),
}
# A plan applies nothing: recorded, and a red one fails the check, but it cannot
# stand for real cloud on its own (CONTRIBUTING: cluster-up is the proof).
PLANS = {"infra-plan", "infra-down-plan"}
# The rest of the test/feint-/local-/infra-/cluster- families, and why they are not
# rungs. The harness fails on a family member that is in neither list.
EXCLUDED = {
    "cluster-security": "reads whatever KUBECONFIG names, local or cloud: no rung to record",
    "feint-test": "its feint-plan and feint-apply children record for it",
    "feint-up": "starts the emulator, proves nothing about a change",
    "feint-down": "stops the emulator, proves nothing about a change",
    "feint-record": "ranks what the emulator does not serve, proves nothing about a change",
    "local-status": "every probe ends in `|| true`: exits 0 without proving anything",
    "local-flux": "a port-forward for debugging",
    "local-render-manifests": "renders a manifest, proves nothing about a change",
    "local-down": "tears the local cluster down, proves nothing about a change",
}
FIELDS = ("rung", "target", "tool", "version", "rc", "sha", "dirty", "utc", "provider")

# They cannot run a rung, so they may declare none: CI's own jobs are their evidence.
# A login, not a phrase in the body — an author cannot opt in.
BOTS = {"renovate[bot]", "dependabot[bot]"}


def git(*args):
    r = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def version(tool):
    try:
        r = subprocess.run([tool, "--version"], capture_output=True, text=True, timeout=10)
    except FileNotFoundError:
        return "absent"
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    m = re.search(r"\d+\.\d+(?:\.\d+)?(?:[-+][\w.]+)?", r.stdout + r.stderr)
    return m.group(0) if m else "unknown"


def record(target, provider, rc, start):
    if target not in TARGETS:
        sys.exit(f"✗ no receipt: '{target}' is not in TARGETS of {Path(__file__).name}")
    rung, tool = TARGETS[target]
    # "<sha> <paths git status listed>", taken when the run started (RECEIPT_START
    # in Taskfile.yml): a commit or an edit made mid-run does not rewrite it.
    sha, changed = (start.split() + ["", ""])[:2]
    receipt = {
        "rung": rung, "target": target, "tool": tool, "version": version(tool),
        # Empty on success, and also when a sub-task is refused before it runs.
        "rc": int(rc or 0),
        "sha": sha if re.fullmatch(r"[0-9a-f]{40}", sha) else "unknown",
        # Uncommitted or untracked files at the start: the run did not test that sha.
        "dirty": changed != "0",
        "utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "provider": provider or {"mocked": "none", "local-docker": "local"}.get(rung, "none"),
    }
    path = ROOT / ".receipts" / f"{rung}.jsonl"
    path.parent.mkdir(exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(receipt, separators=(",", ":")) + "\n")
    why = f"git status listed {changed} path(s)" if changed.isdigit() else "git status failed"
    note = f", dirty: {why} at the start" if receipt["dirty"] else ""
    print(f"receipt: {rung} {target} rc={receipt['rc']}{note} -> .receipts/{path.name}", file=sys.stderr)


def show():
    head, latest = git("rev-parse", "HEAD"), {}
    for rung in ORDER:
        path = ROOT / ".receipts" / f"{rung}.jsonl"
        for line in path.read_text().splitlines() if path.exists() else []:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("sha") == head:
                latest[(rung, r.get("target"), r.get("provider"))] = line
    if not latest:
        sys.exit(f"✗ no receipt for HEAD {head}: run a rung target on this commit first.")
    print("\n".join(latest.values()))


# What GitHub displays of a body: a block pass after cmark-gfm (quotes, list items, footnote
# definitions, lazy lines, fences, HTML blocks), then an inline one that drops raw HTML,
# images, link destinations, titles and labels, and reference definitions. A model: it
# agrees with GitHub on the self-test's rendered bodies, and is proven on nothing else.
QUOTE = re.compile(r" {0,3}> ?")
ITEM = re.compile(r" {0,3}([-+*]|(\d{1,9})[.)])(?= |$)")
NOTE = re.compile(r" {0,3}\[\^[^\] \t\r\n\x00]+\]:[ \t]*")
FENCE = re.compile(r" {0,3}(`{3,}(?=[^`]*$)|~{3,})")
ATX = re.compile(r" {0,3}#{1,6}(?: |$)")
BREAK = re.compile(r" {0,3}([-*_])(?: *\1){2,} *$")
SETEXT = re.compile(r" {0,3}(?:=+|-+) *$")
TAGS = (r"""<[A-Za-z][\w-]*(?:\s+[A-Za-z_:][\w.:-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*"""
        r"""\s*/?>|</[A-Za-z][\w-]*\s*>""")
BLANK = re.compile(r"^ *$")
# HTML block starts and the line ending each (CommonMark 4.6); the last cannot
# interrupt a paragraph. Whitespace is ASCII only there, as in cmark.
HTML = [(re.compile(r"<(?:script|pre|style|textarea)(?:\s|>|$)", re.I | re.A),
         re.compile(r"</(?:script|pre|style|textarea)>", re.I)),
        (re.compile(r"<!--"), re.compile(r"-->")), (re.compile(r"<\?"), re.compile(r"\?>")),
        (re.compile(r"<![A-Za-z]"), re.compile(r">")), (re.compile(r"<!\[CDATA\["), re.compile(r"\]\]>")),
        (re.compile(r"</?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|"
                    r"colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|"
                    r"frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|"
                    r"nav|noframes|ol|optgroup|option|p|param|search|section|source|summary|table|tbody|"
                    r"td|tfoot|th|thead|title|tr|track|ul)(?:\s|/?>|$)", re.I | re.A), BLANK),
        (re.compile(rf"(?:{TAGS})\s*$", re.A), BLANK)]
RAW = re.compile(rf"{TAGS}|<!---?>|<!--.*?-->|<\?.*?\?>|<![A-Za-z][^>]*>|<!\[CDATA\[.*?\]\]>", re.S | re.A)
# The RAW openers that scan ahead, and the end each needs. Past the last such end RAW
# is not tried: rescanning to the end of the text from every opener is quadratic.
ENDS = {"<!--": "-->", "<?": "?>", "<![CDATA[": "]]>", "<!": ">"}
TAG_END = re.compile(r"""<(?:[^>=]|=\s*"[^"]*"|=\s*'[^']*'|=(?!\s*["']))*>""", re.A)
WS = r"[ \t]*(?:\n[ \t]*)?"
# A link destination as cmark-gfm reads it: <...>, or no ASCII space with parentheses
# balanced 32 deep. A backslash escapes punctuation only.
PUNCT = r"[!-/:-@\[-`{-~]"
CH = NEST = rf"[^\s()\\]|\\{PUNCT}|\\(?!{PUNCT})"
for _ in range(32):
    NEST = rf"{CH}|\((?:{NEST})*\)"
DEST = rf"<(?:[^<>\n\\]|\\.)*>|(?!<)(?:{NEST})+"
TITLE = r""""(?:[^"\\]|\\[\s\S])*"|'(?:[^'\\]|\\[\s\S])*'|\((?:[^()\\]|\\[\s\S])*\)"""
TAIL = re.compile(rf"\({WS}(?:(?:{DEST})(?:[ \t]*\n[ \t]*|[ \t]+)(?:{TITLE})|(?:{DEST})?){WS}\)", re.A)
LABEL = re.compile(r"\[((?:[^\[\]\\]|\\[\s\S]){0,999})\]")
REFDEF = re.compile(rf"(?=\[\s*[^\s\]]){LABEL.pattern}:{WS}(?:{DEST})"
                    rf"(?:(?:[ \t]*\n[ \t]*|[ \t]+)(?:{TITLE}))?[ \t]*(?:\n|$)", re.A)


def indent(s):
    return len(s) - len(s.lstrip(" "))


# Each nesting level rescans its line: deeper than this is refused, not modelled.
DEPTH = 32


class TooDeep(Exception):
    """args[0]: the line where quotes, list items and footnotes nest deeper than DEPTH."""


def blocks(lines):
    """cmark-gfm's block pass, as far as display goes: [(kind, [(line, column)])], kind
    "text" (paragraph, heading), "html", "code" or "note" (in a footnote definition)."""
    out, conts, leaf = [], [], None  # conts: [">", "-" or "^", content indent, item still empty]

    def emit(kind, segs):
        out.append(("note" if any(c[0] == "^" for c in conts) else kind, segs))

    def close(keep):
        nonlocal leaf
        if leaf:
            emit("code" if leaf[0] == "fence" else leaf[0], leaf[1])
        leaf = None
        del conts[keep:]

    for n, line in enumerate(lines):
        off = matched = 0
        for c in conts:
            rest = line[off:]
            if c[0] == ">":
                if not (m := QUOTE.match(rest)):
                    break
                off += m.end()
            elif indent(rest) >= c[1]:
                off += c[1]
            elif rest.strip(" ") or c[2]:  # an item may start with one blank line, not two
                break
            matched += 1
        full, rest = matched == len(conts), line[off:]
        if rest.strip(" "):
            for c in conts[:matched]:
                c[2] = False
        # A fence, an indented code block or an HTML block takes the line whole.
        if leaf and full and leaf[0] != "text" and not (leaf[0] == "code" and rest.strip(" ") and indent(rest) < 4):
            leaf[1].append((n, off))
            if leaf[2] and leaf[2].search(rest):
                close(matched)
            continue
        para = leaf is not None and leaf[0] == "text"
        interrupt = para and full
        # Blank means spaces only: cmark counts a no-break space as text.
        while (rest := line[off:]).strip(" ") and indent(rest) < 4:
            if m := QUOTE.match(rest):
                close(matched)
                off += m.end()
                conts.append([">", 0, False])
            elif m := NOTE.match(rest):
                close(matched)
                conts.append(["^", 4, False])
                off += m.end()
            elif (m := ITEM.match(rest)) and not BREAK.match(rest) and not (interrupt and (
                    not rest[m.end():].strip(" ") or m.group(2) and int(m.group(2)) != 1)):
                close(matched)
                after = rest[m.end():]
                pad = indent(after) if after.strip(" ") and indent(after) < 5 else 1
                conts.append(["-", m.end() + pad, not after.strip(" ")])
                off += m.end() + pad
            else:
                break
            if len(conts) > DEPTH:
                raise TooDeep(n)
            matched, interrupt, para = matched + 1, False, False
        else:  # blank, or indented code
            if not rest.strip(" "):
                close(matched)
            elif para:  # the paragraph goes on, lazily or not
                leaf[1].append((n, off + indent(rest)))
            else:
                close(matched)
                leaf = ["code", [(n, off)], None]
            continue
        end = next((e for k, (b, e) in enumerate(HTML)
                    if b.match(rest.lstrip(" ")) and not (k == 6 and interrupt)), None)
        f = FENCE.match(rest)
        if ATX.match(rest) or f or end or BREAK.match(rest) or interrupt and SETEXT.match(rest):
            close(matched)
            if ATX.match(rest):
                emit("text", [(n, off)])
            elif f:
                leaf = ["fence", [(n, off)], re.compile(rf"^ {{0,3}}{f.group(1)[0]}{{{len(f.group(1))},}} *$")]
            elif end:
                leaf = ["html", [(n, off)], end]
                if end.search(rest):
                    close(matched)
        elif para:
            leaf[1].append((n, off + indent(rest)))
        else:
            close(matched)
            leaf = ["text", [(n, off + indent(rest))], None]
    close(0)
    return out


def markup(text):
    """An HTML block: the spans a browser does not display (comments, tags, <?...>, <!...>),
    and where one is left open, or None."""
    spans, i = [], 0
    while (i := text.find("<", i)) >= 0:
        c, d = text[i + 1:i + 2], text[i + 2:i + 3]
        if text.startswith("<!--", i):
            j = text.find("-->", i + 2)  # <!--> and <!---> are whole comments
            end = j + 3 if j >= 0 else -1
        elif c.isascii() and c.isalpha() or c == "/" and d.isascii() and d.isalpha():
            end = m.end() if (m := TAG_END.match(text, i)) else -1
        elif c in ("!", "?", "/"):
            end = text.find(">", i) + 1 or -1
        else:
            i += 1
            continue
        if end < 0:
            return spans, i
        spans.append((i, end))
        i = end
    return spans, None


def refdefs(text):
    """The reference definitions a paragraph opens with."""
    found, i = [], 0
    while m := REFDEF.match(text, i):
        found.append(m)
        i = m.end()
    return found


def norm(label):
    return re.sub(r"\s+", " ", label, flags=re.A).strip(" ").casefold()


def inline(text, labels):
    """A paragraph or heading: the spans GitHub does not display (reference definitions,
    raw HTML, images, link destinations, titles and labels). Code spans and escapes hide
    nothing. `labels`: the body's reference definitions, which a reference must match."""
    spans = [m.span() for m in refdefs(text)]
    last = {o: text.rfind(e) for o, e in ENDS.items()}
    # opens: (where, an image). A link holds no other link: no link opener before
    # `linked`, where the last link's text closed, can link. inner: the last "[" opened.
    i, opens, linked, inner = spans[-1][1] if spans else 0, [], -1, -1
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
        elif c == "`":
            run = re.compile(r"`+").match(text, i).group()
            end = re.compile(rf"(?<!`){run}(?!`)").search(text, i + len(run))
            i = end.end() if end else i + len(run)
        elif c == "<" and all(last[o] >= i + 2 for o in ENDS if text.startswith(o, i)) and (
                m := RAW.match(text, i)):
            spans.append((i, m.end()))
            i = m.end()
        elif c == "[":
            opens.append((i, text[i - 1:i] == "!"))
            inner = i
            i += 1
        elif c == "]" and opens:
            start, image = opens.pop()
            active, end = image or start > linked, None
            if active and (m := TAIL.match(text, i + 1)):
                end = m.end()
            elif active:  # [text][label], [text][] or [text]: only a defined label links
                ref = LABEL.match(text, i + 1)
                full = ref and ref.group(1).strip(" \t\n")
                # No label holds a "[", so brackets with one opened inside name none:
                # norm() over every enclosing pair would be quadratic.
                label = ref.group(1) if full else text[start + 1:i] if start == inner else None
                if label is not None and norm(label) in labels:
                    end = ref.end() if full or ref and not ref.group(1) else i + 1
            if end is not None:
                spans.append((start - 1 if image else i + 1, end))  # an image's text is its alt
                if not image:
                    linked = i
            i = end if end is not None else i + 1
        else:
            i += 1
    return spans


def visible(body):
    """(what GitHub displays of the body, None), or ("", why the check will not guess)."""
    lines = body.expandtabs(4).split("\n")
    doc, starts = "\n".join(lines), [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)
    try:
        found = blocks(lines)
    except TooDeep as e:
        return "", f"line {e.args[0] + 1}: nest at most {DEPTH} quotes, list items and footnotes"
    hide, parsed = [], [(kind, segs, "\n".join(lines[n][c:] for n, c in segs))
                        for kind, segs in found if kind != "code"]
    labels = {norm(m.group(1)) for kind, _, text in parsed if kind != "html" for m in refdefs(text)}
    for kind, segs, text in parsed:
        if kind == "note":  # dropped unless referenced, then moved to the end: hidden either way
            hide += [(starts[n], starts[n + 1] - 1) for n, _ in segs]
            continue
        spans, left = markup(text) if kind == "html" else (inline(text, labels), None)
        src, dst, j = [], [], 0  # where each line of text starts, in text and in doc
        for n, c in segs:
            src.append(j)
            dst.append(starts[n] + c)
            j += len(lines[n]) - c + 1

        def g(x):
            k = bisect_right(src, x) - 1
            return dst[k] + x - src[k]
        hide += [(g(a), g(b)) for a, b in spans]
        if left is not None:
            # GitHub hides what follows up to the next "-->" or ">" in its own HTML:
            # a point this check does not model, so it refuses rather than guess.
            if doc[starts[segs[-1][0] + 1]:].strip():
                return "", (f"line {doc.count(chr(10), 0, g(left)) + 1}: close the HTML comment or tag "
                            "left open there, or GitHub hides what follows it")
            hide.append((g(left), len(doc)))
    shown, i = [], 0
    for a, b in sorted(hide):
        shown.append(doc[i:max(i, a)])
        i = max(i, b)
    return "".join(shown) + doc[i:], None


# The value is stripped in Python: a lazy group before `[ \t]*$` backtracks quadratically.
DECLARED = re.compile(r"^[ \t]*(?:\*\*)?Rung:(?:\*\*)?(.*)$", re.M | re.I)
BLOCK = re.compile(r"^[ \t]*```+[ \t]*receipts[ \t]*\n(.*?)^[ \t]*```", re.M | re.S)


def q(value):
    """Quote text from the body: JSON escaping keeps it on one log line."""
    return json.dumps(str(value)[:40])


def rung_of(label):
    # (?<!\s): a split tried from every space of a long run is quadratic.
    word = re.split(r"(?<!\s)\s+[—(-]", label.lower(), maxsplit=1)[0].strip(" .`*")
    return next((r for r, text in RUNGS.items() if word in (r, text.lower())), None)


def verdict(body, head, author, docs_only):
    """(ok, message) for a PR body. Pure, so the self-test drives it without a PR."""
    body, why = visible(re.sub(r"\r\n?", "\n", body))  # CRLF and a lone CR end a line too
    if why:
        return False, why
    # The template's own "Rung:" line is empty until filled in.
    declared = {s for m in DECLARED.finditer(body) if (s := m.group(1).strip(" \t"))}
    lines = [s for b in BLOCK.findall(body) for s in map(str.strip, b.splitlines()) if s]
    if not declared and not lines:
        if author in BOTS:
            return True, f"no rung declared by {author}: this run's test and emulated jobs stand in"
        if docs_only:
            return True, "no rung declared, and a docs-only diff has none to reach"
        return False, "no rung declared, no receipt pasted (.github/pull_request_template.md)"
    if len(declared) != 1:
        return False, f"declare exactly one 'Rung:' line, found {len(declared)}"
    label = declared.pop()
    want = rung_of(label)
    if want is None:
        return False, f"Rung: {q(label)} is not one of {', '.join(RUNGS.values())}"
    if not lines:
        return False, f"{RUNGS[want]} declared, no receipt pasted: `task receipts` in a ```receipts block"
    receipts = []
    for n, line in enumerate(lines, 1):
        try:
            r = json.loads(line)
        except (ValueError, RecursionError):  # the latter: arrays nested thousands deep
            return False, f"receipt {n} is not JSON: {q(line)}"
        if not isinstance(r, dict) or not set(FIELDS) <= r.keys():
            return False, f"receipt {n} is not a receipt: it needs {', '.join(FIELDS)}"
        # Only what `record` can write, so every value printed below is one of ours.
        own = TARGETS.get(r["target"], (None,))[0] if isinstance(r["target"], str) else None
        if own is None or own != r["rung"]:
            return False, f"receipt {n}: {q(r['target'])} is not a {q(r['rung'])} target"
        if type(r["rc"]) is not int or type(r["dirty"]) is not bool:
            return False, f"receipt {n}: rc must be an integer and dirty a boolean"
        if r["sha"] != head:
            return False, f"receipt {n} is for {q(r['sha'])}, the PR head is {head}: re-run and paste"
        if r["dirty"]:
            return False, f"receipt {n} was recorded over uncommitted changes"
        receipts.append(r)
    level = ORDER.index(want)
    red = [r["target"] for r in receipts if r["rc"] != 0 and ORDER.index(r["rung"]) <= level]
    if red:
        return False, f"{RUNGS[want]} declared, a pasted run at or below it is red: {', '.join(red)}"
    backing = [r["target"] for r in receipts if r["rung"] == want and r["target"] not in PLANS]
    if backing:
        return True, f"{RUNGS[want]} at {head[:12]}: {', '.join(backing)} green"
    if any(r["rung"] == want for r in receipts):
        return False, f"{RUNGS[want]} declared, only a plan backs it: a plan applies nothing"
    top = max(ORDER.index(r["rung"]) for r in receipts)
    if top < level:
        return False, f"{RUNGS[want]} declared, the receipts reach only {RUNGS[ORDER[top]]}: a lower rung"
    return False, f"{RUNGS[want]} declared, no receipt is for it"


def check():
    head = os.environ.get("PR_HEAD_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        sys.exit(f"✗ PR_HEAD_SHA is not a commit sha: {q(head)}")
    ok, message = verdict(os.environ.get("PR_BODY", ""), head, os.environ.get("PR_AUTHOR", ""),
                          os.environ.get("DOCS_ONLY") == "true")
    print(("✓ " if ok else "✗ ") + message)
    return 0 if ok else 1


if __name__ == "__main__":
    cmd, args = (sys.argv[1:2] or [""])[0], sys.argv[2:]
    if cmd == "record" and len(args) == 4:
        record(*args)
    elif cmd == "show" and not args:
        show()
    elif cmd == "check" and not args:
        sys.exit(check())
    else:
        sys.exit(__doc__)
