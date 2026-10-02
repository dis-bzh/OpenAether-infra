#!/usr/bin/env python3
"""Cléa — watch what a repository pins, and prove a bump before anyone merges it.

Generic on purpose: this file knows nothing about the repository it runs in.
Everything specific arrives through `clea.toml` and through the host repository's
own commands. Dropping it into another project is copying this directory and
writing a new `clea.toml`.

Standard library only — no `pip install` anywhere in the path, so it also runs
inside the bare container the probe lanes use.

Commands
--------
  coverage   offline. Every version anchor in the tree must be readable, and
             seen by every inventory declared in clea.toml. Exits 1 otherwise.
  scan       online. Resolve the latest upstream version of every dependency and
             write the state file plus a Markdown report.
  bump       rewrite one pin in place, by the exact inverse of the reader.
  report     render Markdown from a state file.
  pick-issue which open, labelled issue is Cléa's OWN report — not just the newest.
  prune      name the probe branches whose pin already landed on the base branch.

The two rules this file will not bend
-------------------------------------
* **Zero floor.** An extractor that matches nothing, a datasource that returns
  no version, a tree with no anchors: all exit 1. A green run that checked
  nothing is worse than no check, and it is the shape this repository keeps
  meeting.
* **Loud on rate limits.** An unauthenticated GitHub API call gets 60 requests
  an hour from a shared runner IP, which is what took a `main` branch red once
  here. A 401/403/429 is an error, never "no new version".
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover - only on very old interpreters
    print("clea needs Python 3.11 or newer (tomllib)", file=sys.stderr)
    raise SystemExit(1) from None

USER_AGENT = "clea/1 (+https://github.com/dis-bzh/OpenAether-infra)"
SKIP_DIRS = {".git", "node_modules", ".terraform", ".terraform-validate", "vendor"}


class CleaError(Exception):
    """Anything that must stop the run rather than degrade into a green report."""


# ---------------------------------------------------------------------------
# JSON5, enough of it to read a Renovate config
# ---------------------------------------------------------------------------
# Renovate's own file is JSON5: comments, bare keys, single quotes, trailing
# commas. Parsing it matters because it is one of the inventories `coverage`
# compares against, and a parse that silently yields nothing would mark every
# anchor in the tree as unwatched — noise, which is how a checker gets muted.
# So this raises instead.

_J5_TOKEN = re.compile(
    r"""
      "(?:\\.|[^"\\])*"      # double-quoted string
    | '(?:\\.|[^'\\])*'      # single-quoted string
    | //[^\n]*               # line comment
    | /\*.*?\*/              # block comment
    | [\s\S]                 # anything else, one character
    """,
    re.VERBOSE | re.DOTALL,
)


def _requote(tok: str) -> str:
    """A single-quoted JSON5 string as a double-quoted JSON one."""
    body = tok[1:-1]
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            out.append(nxt if nxt == "'" else c + nxt)
            i += 2
            continue
        out.append('\\"' if c == '"' else c)
        i += 1
    return '"' + "".join(out) + '"'


def json5_to_json(text: str) -> str:
    """Rewrite JSON5 as JSON, leaving string contents untouched.

    Comments become a space so the characters around them stay in one run —
    otherwise a key introduced by `{` on one line and commented on the next
    would lose the `{` that identifies it as a key.
    """
    parts: list[str] = []
    run: list[str] = []

    def flush() -> None:
        if not run:
            return
        chunk = "".join(run)
        # bare keys -> quoted keys
        chunk = re.sub(r"([{,]\s*)([A-Za-z_$][\w$-]*)(\s*):", r'\1"\2"\3:', chunk)
        # trailing commas
        chunk = re.sub(r",(\s*[}\]])", r"\1", chunk)
        parts.append(chunk)
        run.clear()

    for m in _J5_TOKEN.finditer(text):
        tok = m.group(0)
        if tok.startswith("//") or tok.startswith("/*"):
            run.append(" ")
        elif tok.startswith('"'):
            flush()
            parts.append(tok)
        elif tok.startswith("'"):
            flush()
            parts.append(_requote(tok))
        else:
            run.append(tok)
    flush()
    return "".join(parts)


def load_json5(path: Path) -> dict:
    try:
        return json.loads(json5_to_json(path.read_text(encoding="utf-8")))
    except (OSError, ValueError) as exc:
        raise CleaError(f"cannot read {path} as JSON5: {exc}") from exc


# ---------------------------------------------------------------------------
# Anchors
# ---------------------------------------------------------------------------
# The inventory is the tree itself: the same `# renovate: datasource=… depName=…`
# comment Renovate reads, with the pinned value on one of the lines below it.
# One convention, not two — a second inventory is a second thing to drift.
#
# Where Renovate asks you to DECLARE the shape of the value (and ignores in
# silence anything you forgot to declare), Cléa RECOGNISES a fixed set of shapes
# and fails on one it cannot read. That difference is the whole point of
# `coverage`: Cléa's list is a superset, so what it sees and Renovate does not
# is exactly the set of pins nothing is watching.

# Built from the configured marker rather than hard-coded, and not only for
# other repositories: Cléa's own test fixtures carry anchors, so a hard-coded
# word makes the scanner find them and report acme/one as an unwatched
# dependency of this repository. A detector that matches its own fixtures is the
# defect this file is written against — silencing it by path would have hidden
# it instead of removing it.
def anchor_re(marker: str) -> re.Pattern[str]:
    token = marker.strip().lstrip("#/ ").rstrip(":").strip()
    if not token:
        raise CleaError("clea.toml: [scan] marker is empty")
    return re.compile(rf"^\s*(?:#|//)\s*{re.escape(token)}:\s*(?P<attrs>.*\S)\s*$")


ATTR_RE = re.compile(r"(\w+)=(\S+)")

# Ordered: the first form that matches the line wins, so the more specific
# shapes come first. `task-default` before the YAML forms, or a Taskfile's
# `KEY: '{{.KEY | default "1.2.3"}}'` reads back as the whole template.
VALUE_FORMS: list[tuple[str, re.Pattern[str]]] = [
    ("task-default", re.compile(r"\|\s*default\s+\"(?P<v>[^\"]+)\"")),
    ("bash-default", re.compile(
        r"^\s*(?:local\s+|export\s+)?[A-Za-z_]\w*=\"\$\{[A-Za-z_]\w*:-(?P<v>[^}\"]+)\}\"")),
    ("bash", re.compile(r"^\s*(?:local\s+|export\s+)?[A-Za-z_]\w*=\"(?P<v>[^\"]+)\"")),
    ("hcl-default", re.compile(r"^\s*default\s*=\s*\"(?P<v>[^\"]+)\"")),
    ("pip", re.compile(r"pip install\s+[A-Za-z0-9_.\-\[\]]+==(?P<v>[^\s\"']+)")),
    ("precommit-rev", re.compile(r"^\s*rev:\s*\S+\s*#\s*(?P<v>\S+)")),
    ("yaml-dq", re.compile(r"^\s*[A-Za-z_][\w.\-]*:\s*\"(?P<v>[^\"]+)\"")),
    ("yaml-sq", re.compile(r"^\s*[A-Za-z_][\w.\-]*:\s*'(?P<v>[^']+)'")),
    ("action-sha", re.compile(r"^\s*(?:-\s*)?uses:\s*\S+@\S+\s*#\s*(?P<v>\S+)")),
]

# These two forms pin a commit — the `@sha` in `action-sha`, the `rev: sha` in
# `precommit-rev` — and capture only the human tag AFTER it as `value`. `bump`
# rewrites exactly the span it captured, so bumping one of these would move the
# tag comment and leave the commit it is supposed to describe untouched: a pin
# that CLAIMS the new version while still RUNNING the old one, which is worse
# than not tracking it at all — it looks bumped. `cmd_bump` refuses both shapes
# unless it is handed the commit: only `action-sha` can be (`--sha`, recorded by
# the scan from the tag), and it then moves the commit and the comment together.
# `precommit-rev` is always refused. See `renovate-native` in `inventory_coverage`
# for the other half: what makes leaving them untracked unnecessary.
UNSAFE_BUMP_FORMS = frozenset({"action-sha", "precommit-rev"})
SHA40 = re.compile(r"[0-9a-f]{40}")
# `uses: owner/repo[/path]@<commit>  # tag`: the repo the commit belongs to, and the commit.
ACTION_USES = re.compile(
    r"^(?P<head>\s*(?:-\s*)?uses:\s*)(?P<repo>[^@\s]+)@(?P<sha>[0-9a-f]{40})(?P<tail>\s*#)")

# How far below the anchor the value may sit. Renovate's own regexes allow one
# line; three covers a YAML `env:` key that opens its block on the next line.
VALUE_WINDOW = 3

# What a version is allowed to look like. Without this the YAML form reads a
# Taskfile's `KEY: '{{.VERSION | default .PINNED}}'` back as the version itself,
# and the anchor looks healthy while marking a template. A form that matches is
# not the same as a value that means something.
VERSION_LIKE = re.compile(r"^v?\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.+-]+)?$")


class Anchor:
    __slots__ = ("path", "line", "attrs", "value", "value_line", "form", "span",
                 "reason")

    def __init__(self, path: str, line: int, attrs: dict[str, str]) -> None:
        self.path = path
        self.line = line
        self.attrs = attrs
        self.value: str | None = None
        self.value_line: int | None = None
        self.form: str | None = None
        self.span: tuple[int, int] | None = None  # column span of the value
        self.reason: str = ""

    @property
    def dep(self) -> str:
        return self.attrs.get("depName", "?")

    @property
    def datasource(self) -> str:
        return self.attrs.get("datasource", "?")

    @property
    def key(self) -> tuple[str, int]:
        return (self.path, self.line)

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<Anchor {self.path}:{self.line} {self.dep}={self.value}>"


def _read_value(lines: list[str], start: int):
    """First recognised version in the window under the anchor at index `start`.

    Returns (found, reason): `found` is (value, line, form, span) or None;
    `reason` is set only when `found` is None, and names what was read instead
    — "no value here" and "this line reads `{{.VERSION | default .PINNED}}`"
    send a reader to two different places. Always a 2-tuple: a return whose
    ARITY depends on which branch ran is its own kind of landmine for whatever
    reads it next.
    """
    rejected: list[str] = []
    for offset in range(1, VALUE_WINDOW + 1):
        idx = start + offset
        if idx >= len(lines):
            break
        line = lines[idx]
        if not line.strip():
            continue
        for form, pattern in VALUE_FORMS:
            m = pattern.search(line)
            if not m:
                continue
            value = m.group("v")
            if VERSION_LIKE.match(value):
                return (value, idx + 1, form, m.span("v")), None
            rejected.append(f"line {idx + 1} reads {value!r} ({form}), which is not a version")
    reason = ("; ".join(rejected) if rejected
              else f"nothing version-shaped in the {VALUE_WINDOW} lines below")
    return None, reason


def _walk(root: Path, include: list[str], exclude: list[str]):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            full = Path(dirpath) / name
            rel = full.relative_to(root).as_posix()
            if any(fnmatch.fnmatch(rel, pat) for pat in exclude):
                continue
            if include and not any(fnmatch.fnmatch(rel, pat) for pat in include):
                continue
            yield rel, full


def scan_anchors(root: Path, marker: str, exclude: list[str],
                 include: list[str] | None = None) -> tuple[list[Anchor], list[Anchor]]:
    """Every anchor in the tree, split into readable and value-less.

    A value-less anchor is not a warning. It marks a version that is not there —
    a leftover from when the value was a literal, or a pin that moved elsewhere
    — so it can never be bumped and reads to a human as if it could.
    """
    found: list[Anchor] = []
    novalue: list[Anchor] = []
    pattern = anchor_re(marker)
    token = marker.strip().lstrip("#/ ").rstrip(":").strip()
    for rel, full in _walk(root, include or [], exclude):
        try:
            text = full.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if token not in text:
            continue
        lines = text.splitlines()
        # An anchor inside a fenced block of a Markdown file is an EXAMPLE, not
        # a pin — the same rule check-language.sh applies to prose. Without it
        # Cléa reports the anchor in its own README as an unwatched dependency
        # of the repository, which is the class of defect it exists to find.
        markdown = rel.endswith((".md", ".markdown"))
        fenced = False
        for i, line in enumerate(lines):
            if markdown and line.lstrip().startswith(("```", "~~~")):
                fenced = not fenced
                continue
            if fenced:
                continue
            m = pattern.match(line)
            if not m:
                continue
            attrs = dict(ATTR_RE.findall(m.group("attrs")))
            if "depName" not in attrs:
                continue
            anchor = Anchor(rel, i + 1, attrs)
            got, reason = _read_value(lines, i)
            if got is None:
                anchor.reason = reason
                novalue.append(anchor)
                continue
            anchor.value, anchor.value_line, anchor.form, anchor.span = got
            found.append(anchor)
    found.sort(key=lambda a: a.key)
    novalue.sort(key=lambda a: a.key)
    return found, novalue


# ---------------------------------------------------------------------------
# Inventories to cross-check against
# ---------------------------------------------------------------------------

def _file_matcher(pattern: str):
    """Renovate's managerFilePatterns rule: /…/ is a regex, anything else a glob."""
    if len(pattern) > 1 and pattern.startswith("/") and pattern.endswith("/"):
        compiled = re.compile(pattern[1:-1])
        return compiled.search
    return lambda rel: fnmatch.fnmatch(rel, pattern)


def renovate_coverage(root: Path, config: str, exclude: list[str]) -> set[tuple[str, int]]:
    """Anchor positions a Renovate config's customManagers can actually reach.

    Its own `matchStrings` contain the anchor text verbatim, so the config file
    has to be excluded from the scan or it matches itself and reports a dozen
    anchors that do not exist.
    """
    cfg = load_json5(root / config)
    managers = cfg.get("customManagers", [])
    if not managers:
        raise CleaError(
            f"{config} declares no customManagers — either the inventory is wrong "
            "or this repository does not use Renovate; say so in clea.toml"
        )
    covered: set[tuple[str, int]] = set()
    for manager in managers:
        # Renovate renamed fileMatch to managerFilePatterns, and the two are not
        # spelled the same: fileMatch was always a regex, while a
        # managerFilePatterns entry is a regex only when it is delimited by
        # slashes and a glob otherwise. Reading a glob as a regex matches almost
        # nothing and would report every anchor as unwatched.
        modern = manager.get("managerFilePatterns")
        matchers = ([_file_matcher(p) for p in modern] if modern
                    else [_file_matcher("/%s/" % p) for p in manager.get("fileMatch", [])])
        for rel, full in _walk(root, [], exclude + [config]):
            if not any(match(rel) for match in matchers):
                continue
            try:
                text = full.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            for match_string in manager.get("matchStrings", []):
                # Renovate uses JavaScript named groups; Python spells them (?P<…>).
                pattern = match_string.replace("(?<", "(?P<")
                try:
                    rx = re.compile(pattern, re.MULTILINE)
                except re.error as exc:
                    raise CleaError(f"{config}: unusable matchString {match_string!r}: {exc}") from exc
                for m in rx.finditer(text):
                    covered.add((rel, text[: m.start()].count("\n") + 1))
    return covered


def inventory_coverage(root: Path, scan: dict,
                       inventories: list[dict]) -> dict[str, set[tuple[str, int]]]:
    """Anchor positions each declared inventory can see, one set per kind.

    `renovate` cross-checks a real Renovate config's `customManagers`, byte
    for byte — the same question `renovate_coverage` always answered.

    `renovate-native` is not a cross-check at all: it is the list of `form`s
    (from VALUE_FORMS) that Renovate's OWN built-in managers already read
    without any anchor, via `helpers:pinGitHubActionDigests` for `action-sha`
    and `pinDigests` for `precommit-rev`. Both update the commit AND the tag
    comment in one write. A `customManagers` entry matching the same line
    could only ever move the comment — `cmd_bump` refuses exactly these two
    forms for that reason (`UNSAFE_BUMP_FORMS`) — so routing them through
    `renovate` coverage would demand the one kind of watcher that is unsafe to
    build, for a dependency a different, safe watcher already has. Naming the
    form here is what keeps this an explicit, per-project claim rather than a
    blanket exemption: a form not listed still has to be seen by `renovate`.
    """
    seen: dict[str, set[tuple[str, int]]] = {}
    for inventory in inventories:
        kind = inventory.get("kind")
        if kind == "renovate":
            seen["renovate"] = renovate_coverage(
                root, inventory["config"], scan["exclude"] + inventory.get("exclude", []))
        elif kind == "renovate-native":
            forms = set(inventory.get("forms", []))
            if not forms:
                raise CleaError(
                    'clea.toml: [[inventory]] kind = "renovate-native" needs a '
                    "non-empty forms list — naming which VALUE_FORMS shapes it vouches for")
            known = {form for form, _ in VALUE_FORMS}
            unknown = forms - known
            if unknown:
                raise CleaError(
                    f"clea.toml: renovate-native names unknown form(s) {sorted(unknown)} "
                    f"— known forms are {sorted(known)}")
            anchors, _ = scan_anchors(root, scan["marker"], scan["exclude"], scan["include"])
            seen["renovate-native"] = {a.key for a in anchors if a.form in forms}
        else:
            raise CleaError(f"clea.toml: unknown inventory kind {kind!r}")
    return seen


# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

_NUM = re.compile(r"\d+")


def version_key(value: str) -> tuple:
    """Sortable key. Numeric segments compare as numbers, so 1.13.10 > 1.13.9.

    A string comparison gets that pair backwards, which is the one version bug
    every hand-rolled comparator ships with.
    """
    core, _, pre = value.lstrip("vV").partition("-")
    parts: list[int] = []
    for chunk in core.split("."):
        m = _NUM.match(chunk)
        parts.append(int(m.group(0)) if m else 0)
    # A release outranks any prerelease of the same number: (1,) beats (0, …).
    return (tuple(parts), (1,) if not pre else (0, pre))


def is_prerelease(value: str) -> bool:
    return bool(re.search(r"-(?:alpha|beta|rc|pre|dev|next)", value, re.I))


def is_newer(current: str, candidate: str) -> bool:
    return version_key(candidate) > version_key(current)


def same_shape(current: str, candidate: str) -> bool:
    """Both carry a leading v, or neither does.

    Writing `v1.2.3` where `1.2.3` was expected is how a pin becomes a download
    URL that 404s, and every consumer of that value reads it differently.
    """
    return current.startswith("v") == candidate.startswith("v")


def apply_extract(tag: str, extract_version: str | None) -> str:
    if not extract_version:
        return tag
    rx = re.compile(extract_version.replace("(?<", "(?P<"))
    m = rx.search(tag)
    if not m:
        return tag
    if "version" in rx.groupindex:
        return m.group("version")
    return m.group(1) if rx.groups else m.group(0)


# ---------------------------------------------------------------------------
# Datasources
# ---------------------------------------------------------------------------

def http_get(url: str, token: str | None = None, accept: str | None = None) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    if accept:
        request.add_header("Accept", accept)
    if token and urllib.parse.urlparse(url).hostname == "api.github.com":
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", "replace")[:200]
        except OSError:  # pragma: no cover - the status alone is enough
            pass
        if exc.code in (401, 403, 429):
            # Never let this read as "no new version". Unauthenticated GitHub
            # allows 60 requests an hour from an IP shared with every other
            # runner, and a silent 403 here is a report that says all is well.
            raise CleaError(
                f"{url} -> HTTP {exc.code}. Rate limited or unauthorised — export "
                f"GITHUB_TOKEN. Body: {body}"
            ) from exc
        raise CleaError(f"{url} -> HTTP {exc.code}: {body}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise CleaError(f"{url} -> {exc}") from exc


def _gh_json(path: str, token: str | None):
    raw = http_get(f"https://api.github.com{path}", token,
                   accept="application/vnd.github+json")
    return json.loads(raw)


def resolve_commit(dep: str, tag: str, token: str | None) -> str:
    """The commit a tag points at, peeling an annotated tag: what `@<sha>` must hold."""
    obj = (_gh_json(f"/repos/{dep}/git/ref/tags/{tag}", token) or {}).get("object") or {}
    if obj.get("type") == "tag":
        obj = (_gh_json(f"/repos/{dep}/git/tags/{obj.get('sha', '')}", token) or {}).get("object") or {}
    if obj.get("type") != "commit" or not SHA40.fullmatch(obj.get("sha", "")):
        raise CleaError(f"{dep}@{tag}: the tag does not resolve to a commit")
    return obj["sha"]


def latest_github_releases(dep: str, token: str | None, **_) -> dict:
    data = _gh_json(f"/repos/{dep}/releases/latest", token)
    tag = data.get("tag_name")
    if not tag:
        raise CleaError(f"github-releases {dep}: no tag_name in the answer")
    return {
        "tag": tag,
        "released_at": data.get("published_at"),
        "notes_url": data.get("html_url"),
    }


def latest_github_tags(dep: str, token: str | None, **_) -> dict:
    data = _gh_json(f"/repos/{dep}/tags?per_page=100", token)
    tags = [t["name"] for t in data if not is_prerelease(t["name"])]
    if not tags:
        raise CleaError(f"github-tags {dep}: no usable tag")
    tag = max(tags, key=version_key)
    return {"tag": tag, "released_at": None,
            "notes_url": f"https://github.com/{dep}/releases/tag/{tag}"}


def latest_pypi(dep: str, _token: str | None, **_) -> dict:
    data = json.loads(http_get(f"https://pypi.org/pypi/{dep}/json"))
    version = data.get("info", {}).get("version")
    if not version:
        raise CleaError(f"pypi {dep}: no info.version")
    return {"tag": version, "released_at": None,
            "notes_url": f"https://pypi.org/project/{dep}/{version}/"}


def latest_helm(dep: str, _token: str | None, registry_url: str | None = None, **_) -> dict:
    """Newest chart version in a Helm repository index.

    Line-scanned rather than YAML-parsed: PyYAML is not in the standard library
    and this file refuses a dependency for one field. That makes INDENT the only
    structure available, and it has to be used — cilium's index is 1.7 MB and
    embeds Kubernetes CRD listings inside an annotation, where `version: v2`
    appears at depth 10. Reading every `version:` line collected 1673 of those
    against 651 real ones, and `v2` outranks every 1.x, so the answer was v2.
    Two guards, both needed: the key must sit at the chart item's own indent,
    and a chart version is semver, which mandates MAJOR.MINOR.PATCH.
    """
    if not registry_url:
        raise CleaError(f"helm {dep}: no registryUrl on the anchor")
    text = http_get(registry_url.rstrip("/") + "/index.yaml").decode("utf-8", "replace")
    semver = re.compile(r"(?:-\s+)?version:\s*[\"']?(\d+\.\d+\.\d+[0-9A-Za-z.+-]*)[\"']?$")
    versions: list[str] = []
    entry_indent: int | None = None
    item_indent: int | None = None
    key_indent: int | None = None
    inside = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if not inside:
            if re.match(rf"^{re.escape(dep)}:\s*$", stripped):
                inside, entry_indent = True, indent
            continue
        if indent <= entry_indent and not stripped.startswith("-"):
            break
        # Locked on the FIRST list item and never moved: the annotations block
        # inside a chart entry contains its own `- ` items at greater depth, and
        # following those re-based the whole scan below the real keys — which is
        # how 1.8.13 came back as the newest chart of a repository serving 1.20.
        dashed = stripped.startswith("- ")
        if dashed and item_indent is None:
            item_indent, key_indent = indent, indent + 2
        if key_indent is None:
            key_indent = entry_indent + 2
        if dashed and indent != item_indent:
            continue
        if (indent + 2 if dashed else indent) != key_indent:
            continue
        m = semver.match(stripped)
        if m:
            versions.append(m.group(1))
    versions = [v for v in versions if not is_prerelease(v)]
    if not versions:
        raise CleaError(f"helm {dep}: no chart version under entries in {registry_url}")
    tag = max(versions, key=version_key)
    return {"tag": tag, "released_at": None, "notes_url": registry_url}


def latest_terraform_provider(dep: str, _token: str | None,
                              registry_url: str | None = None, **_) -> dict:
    base = (registry_url or "https://registry.opentofu.org").rstrip("/")
    data = json.loads(http_get(f"{base}/v1/providers/{dep}/versions"))
    versions = [v["version"] for v in data.get("versions", [])
                if not is_prerelease(v["version"])]
    if not versions:
        raise CleaError(f"terraform-provider {dep}: no version at {base}")
    tag = max(versions, key=version_key)
    namespace = dep.split("/", 1)[0]
    name = dep.rsplit("/", 1)[-1]
    return {"tag": tag, "released_at": None,
            "notes_url": f"https://github.com/{namespace}/terraform-provider-{name}/releases/tag/v{tag}"}


def latest_url_text(dep: str, _token: str | None, url: str | None = None,
                    extract: str | None = None, **_) -> dict:
    """A plain URL whose body is (or contains) the version.

    This is what covers a tool installed from a moving target — the kind of pin
    that is not a pin at all, like `dl.k8s.io/release/stable.txt`.
    """
    if not url:
        raise CleaError(f"url-text {dep}: no url")
    body = http_get(url).decode("utf-8", "replace").strip()
    if extract:
        m = re.search(extract.replace("(?<", "(?P<"), body, re.MULTILINE)
        if not m:
            raise CleaError(f"url-text {dep}: {extract!r} matched nothing at {url}")
        body = m.groupdict().get("v") or m.group(0)
    if not body:
        raise CleaError(f"url-text {dep}: {url} answered nothing")
    return {"tag": body.strip(), "released_at": None, "notes_url": url}


def bot_activity(repo: str, bot: str, token: str | None) -> dict:
    """When did the bot that proposes the bumps last propose one?

    On its own this says little — a bot with nothing to propose is silent and
    correct. It becomes a signal when crossed with what Cléa found: a
    dependency that IS behind and that the bot's own inventory CAN see, with no
    proposal for days, means the bot is not running. That crossing is what went
    unmade here for three weeks.
    """
    prs = _gh_json(f"/repos/{repo}/pulls?state=all&per_page=100"
                   f"&sort=created&direction=desc", token)
    for pr in prs:
        if (pr.get("user") or {}).get("login") == bot:
            at = pr.get("created_at")
            days = None
            if at:
                seen = datetime.fromisoformat(at.replace("Z", "+00:00"))
                days = (datetime.now(timezone.utc) - seen).days
            return {"bot": bot, "number": pr.get("number"), "at": at,
                    "days": days, "scanned": len(prs)}
    return {"bot": bot, "number": None, "at": None, "days": None,
            "scanned": len(prs)}


DATASOURCES = {
    "github-releases": latest_github_releases,
    "github-tags": latest_github_tags,
    "pypi": latest_pypi,
    "helm": latest_helm,
    "terraform-provider": latest_terraform_provider,
    "url-text": latest_url_text,
}


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "scan": {"marker": "# renovate:", "exclude": [], "include": []},
    "report": {"title": "Cléa — dependency report", "label": "clea",
              "bot_login": "github-actions[bot]"},
    "inventory": [],
    "tool": [],
    "unpinned": [],
    "lane": {},
}


def load_config(path: Path) -> dict:
    if not path.is_file():
        raise CleaError(f"no {path} — Cléa needs one, it is the only thing it knows")
    with path.open("rb") as handle:
        raw = tomllib.load(handle)
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    for key, value in raw.items():
        if isinstance(value, dict) and isinstance(cfg.get(key), dict):
            cfg[key].update(value)
        else:
            cfg[key] = value
    return cfg


def repo_root(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True)
        return Path(out.stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        return Path.cwd()


# ---------------------------------------------------------------------------
# coverage
# ---------------------------------------------------------------------------

def cmd_coverage(args) -> int:
    root = repo_root(args.root)
    cfg = load_config(root / args.config)
    scan = cfg["scan"]
    anchors, novalue = scan_anchors(root, scan["marker"], scan["exclude"], scan["include"])

    # Zero floor. "0 anchors, none unwatched" and "every anchor is watched" look
    # identical in a green run, and only one of them is true.
    if not anchors and not novalue:
        print(f"✗ no version anchor found under {root} — the scanner is broken, "
              "not the repository", file=sys.stderr)
        return 1

    seen = inventory_coverage(root, scan, cfg["inventory"])

    failures = 0
    print(f"=== {len(anchors)} anchors read, {len(novalue)} carrying no version ===")

    for anchor in novalue:
        print(f"  ✗ {anchor.path}:{anchor.line} — {anchor.dep}: the anchor marks no "
              f"version ({anchor.reason}). Nothing can bump it, and it reads as if "
              "something could.")
        failures += 1

    # An anchor fails only if NO declared inventory reaches it. `renovate` and
    # `renovate-native` watch disjoint, complementary shapes by design — each
    # legitimately misses what the other covers, and requiring every kind to
    # see every anchor would fail both halves for doing their job.
    combined: set[tuple[str, int]] = set().union(*seen.values()) if seen else set()
    for name, covered in seen.items():
        missing = [a for a in anchors if a.key not in covered]
        if missing:
            print(f"\n  {name} cannot see {len(missing)} of {len(anchors)}:")
            for anchor in missing:
                flag = ("  ← no inventory sees this one"
                        if len(seen) > 1 and anchor.key not in combined else "")
                print(f"  ✗ {anchor.path}:{anchor.line} — {anchor.dep} = {anchor.value} "
                      f"({anchor.form}){flag}")
        else:
            print(f"  ✓ {name} sees all {len(anchors)}")
    if seen:
        failures += len([a for a in anchors if a.key not in combined])

    print()
    if failures:
        print(f"{failures} unwatched pin(s). A pin nothing watches is a pin nobody bumps.")
        return 1
    print(f"{len(anchors)} anchors, every one watched.")
    return 0


# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------

def _load_previous(path: str | None) -> dict:
    """Previous state, from a state file or from a report that embeds one."""
    if not path:
        return {}
    text = Path(path).read_text(encoding="utf-8")
    m = re.search(r"<!--\s*clea-state\s+(\{.*?\})\s*-->", text, re.DOTALL)
    if m:
        text = m.group(1)
    try:
        return json.loads(text)
    except ValueError:
        return {}


def mark_movement(entry: dict, previous: dict[str, dict]) -> dict:
    """Did upstream move since the last scan? Keyed on dependency AND file, so
    the same tool pinned in two places is two rows, which is how a drift between
    them shows up at all."""
    was = previous.get(entry["dep"] + "@" + entry["file"], {})
    entry["moved_since_last_scan"] = bool(
        was.get("latest") and entry.get("latest") and was["latest"] != entry["latest"])
    return entry


def cmd_scan(args) -> int:
    root = repo_root(args.root)
    cfg = load_config(root / args.config)
    scan = cfg["scan"]
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    anchors, novalue = scan_anchors(root, scan["marker"], scan["exclude"], scan["include"])
    if not anchors:
        print("✗ no readable anchor — nothing to scan", file=sys.stderr)
        return 1
    if not token:
        print("⚠ no GITHUB_TOKEN: 60 requests an hour from a shared runner IP. "
              "This will rate-limit, loudly.", file=sys.stderr)

    previous = _load_previous(args.previous)
    prev_by_key = {d["dep"] + "@" + d["file"]: d for d in previous.get("deps", [])}

    # One upstream call per (datasource, dep), not per anchor: helm is pinned in
    # two files here and the API does not need asking twice.
    cache: dict[tuple[str, str], dict | str] = {}
    commits: dict[tuple[str, str], str] = {}
    deps, errors = [], []

    def resolve(datasource: str, name: str, **kwargs) -> dict:
        key = (datasource, name)
        if key not in cache:
            fetch = DATASOURCES.get(datasource)
            if fetch is None:
                cache[key] = CleaError(f"unknown datasource {datasource!r} for {name}")
            else:
                try:
                    cache[key] = fetch(name, token, **kwargs)
                except CleaError as exc:
                    cache[key] = exc
        got = cache[key]
        if isinstance(got, CleaError):
            raise got
        return got

    for anchor in anchors:
        entry = {
            "dep": anchor.dep,
            "datasource": anchor.datasource,
            "file": anchor.path,
            "line": anchor.line,
            "form": anchor.form,
            "current": anchor.value,
            "pinned": True,
        }
        try:
            upstream = resolve(anchor.datasource, anchor.dep,
                               registry_url=anchor.attrs.get("registryUrl"))
            latest = apply_extract(upstream["tag"], anchor.attrs.get("extractVersion"))
            # The RAW tag is kept beside the extracted one. `bump` re-applies
            # extractVersion per site, so it must be handed the tag: this
            # repository pins fluxcd/flux2 as `v2.9.3` where the value builds a
            # release URL and as `2.9.3` where it builds a filename, and only
            # the tag can become both.
            entry.update(tag=upstream["tag"],
                         latest=latest, released_at=upstream.get("released_at"),
                         notes_url=upstream.get("notes_url"),
                         behind=is_newer(anchor.value, latest),
                         shape_ok=same_shape(anchor.value, latest))
            if anchor.form == "action-sha" and entry["behind"] and anchor.datasource in (
                    "github-releases", "github-tags"):
                # `bump` cannot move the commit an action pin holds without being
                # told it; kept off the other anchors so the lookups stay one per pin.
                try:
                    key = (anchor.dep, upstream["tag"])
                    if key not in commits:
                        commits[key] = resolve_commit(anchor.dep, upstream["tag"], token)
                    entry["sha"] = commits[key]
                except CleaError as exc:
                    errors.append(str(exc))
        except CleaError as exc:
            entry.update(latest=None, error=str(exc), behind=False)
            errors.append(str(exc))
        tool = next((t for t in cfg["tool"] if t["name"] == anchor.dep), None)
        if tool:
            entry["tool"] = tool
        deps.append(mark_movement(entry, prev_by_key))

    for item in cfg["unpinned"]:
        entry = {"dep": item["name"], "datasource": item["datasource"],
                 "file": item.get("consumed_by", ""), "line": 0, "form": "unpinned",
                 "current": None, "pinned": False}
        try:
            upstream = resolve(item["datasource"], item["name"],
                               url=item.get("url"), extract=item.get("extract"),
                               registry_url=item.get("registry_url"))
            entry.update(latest=upstream["tag"], notes_url=upstream.get("notes_url"),
                         released_at=upstream.get("released_at"), behind=False)
        except CleaError as exc:
            entry.update(latest=None, error=str(exc), behind=False)
            errors.append(str(exc))
        deps.append(mark_movement(entry, prev_by_key))

    state = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "deps": deps,
        "novalue": [{"dep": a.dep, "file": a.path, "line": a.line,
                     "reason": a.reason} for a in novalue],
        "unwatched": [],
        # Deduplicated: one rate limit fails once per anchor, and the state is
        # carried in an issue body with a hard size limit.
        "errors": list(dict.fromkeys(errors)),
        "probes": previous.get("probes", []),
    }

    # Union across every declared inventory kind: `renovate` and
    # `renovate-native` watch disjoint, complementary shapes (see
    # `inventory_coverage`), so a dependency is watched if EITHER sees it.
    try:
        seen = inventory_coverage(root, scan, cfg["inventory"])
        if seen:
            covered = set().union(*seen.values())
            state["unwatched"] = [
                {"dep": a.dep, "file": a.path, "line": a.line,
                 "current": a.value, "inventory": ",".join(sorted(seen))}
                for a in anchors if a.key not in covered]
            watched = {(a.path, a.line) for a in anchors if a.key in covered}
            for entry in deps:
                entry["watched"] = (entry["file"], entry["line"]) in watched
    except CleaError as exc:
        errors.append(str(exc))

    # The bot's heartbeat. Skipped loudly rather than quietly: "we did not ask"
    # and "the bot is fine" must not look the same in the report.
    bot = cfg["report"].get("watch_bot")
    slug = cfg["report"].get("repo") or os.environ.get("GITHUB_REPOSITORY")
    if bot and slug:
        try:
            state["bot"] = bot_activity(slug, bot, token)
            state["bot"]["silent_after_days"] = cfg["report"].get("silent_after_days", 8)
        except CleaError as exc:
            errors.append(f"{bot} activity on {slug}: {exc}")
    elif bot:
        errors.append(f"{bot}: no repository to ask about — set GITHUB_REPOSITORY "
                      "or [report] repo in clea.toml")

    # Re-taken here, not at construction: the inventory and the heartbeat run
    # after the state dict is built, and a copy made earlier would silently drop
    # exactly the failures this report exists to show.
    state["errors"] = list(dict.fromkeys(errors))

    Path(args.state).write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    behind = [d for d in deps if d.get("behind")]
    print(f"{len(deps)} dependencies, {len(behind)} behind, "
          f"{len(state['unwatched'])} unwatched, "
          f"{len(state['errors'])} distinct error(s)")

    # A datasource that answered nothing is not a dependency that is up to date.
    if state["errors"] and args.strict:
        for message in state["errors"]:
            print(f"  ✗ {message}", file=sys.stderr)
        return 1
    return 0


# ---------------------------------------------------------------------------
# config — one value, for the shell around Cléa
# ---------------------------------------------------------------------------

def cmd_config(args) -> int:
    """Print one dotted key from clea.toml, so a workflow reads the config
    rather than repeating it. A second copy of a value is a second thing to
    drift, and this repository already has the scars."""
    node = load_config(repo_root(args.root) / args.config)
    for part in args.key.split("."):
        if not isinstance(node, dict) or part not in node:
            raise CleaError(f"clea.toml has no {args.key}")
        node = node[part]
    print(node if not isinstance(node, (dict, list)) else json.dumps(node))
    return 0


# ---------------------------------------------------------------------------
# matrix — what the probe lanes should run
# ---------------------------------------------------------------------------

def slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def cmd_matrix(args) -> int:
    """One entry per dependency to probe, as a GitHub Actions matrix.

    Keyed on the dependency, not on the anchor: a bump rewrites every site at
    once, so probing helm twice because it is pinned in two files would test the
    same tree twice.
    """
    state = json.loads(Path(args.state).read_text(encoding="utf-8"))
    seen: dict[str, dict] = {}
    for dep in state.get("deps", []):
        if not (dep.get("behind") and dep.get("pinned")):
            continue
        if not dep.get("shape_ok", True):
            continue  # bumping it would write a value its consumers read differently
        tool = dep.get("tool") or {}
        if args.daily and tool and tool.get("daily") is False:
            continue
        if args.heavy_only and not (tool and tool.get("daily") is False):
            continue
        key = dep["dep"]
        if key in seen:
            # the commit sits on the dependency's action anchor, not necessarily the first
            if dep.get("sha") and not seen[key]["sha"]:
                seen[key]["sha"] = dep["sha"]
            continue
        seen[key] = {
            "dep": key,
            # The tag, not one anchor's extracted form. Deduplicating by
            # dependency kept whichever file sorted first, so a dependency
            # pinned in two shapes was bumped with the shape of whichever
            # happened to come first — right by luck here, wrong the moment a
            # path changed.
            "version": dep.get("tag") or dep["latest"],
            "sha": dep.get("sha", ""),
            "slug": slugify(key),
            "installer": tool.get("installer", ""),
            "version_cmd": tool.get("version_cmd", ""),
            "installer_stdin": tool.get("installer_stdin", ""),
        }
    entries = sorted(seen.values(), key=lambda e: e["dep"])
    print(json.dumps(entries, separators=(",", ":")))
    return 0


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

def _table(rows: list[list[str]], head: list[str]) -> str:
    out = ["| " + " | ".join(head) + " |",
           "|" + "|".join(["---"] * len(head)) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(out)


def lost_verdicts(state: dict, jobs: list[dict]) -> list[dict]:
    """Probe jobs that passed in this run whose verdict is on no branch.

    The report reads each verdict from its clea/probe/<slug> branch, so a push
    that fails leaves the previous run's record in place and the dependency
    reads "not probed". A verdict counts as recorded only at the exact tag the
    probe tested: an older record for the same dependency is not this run's.
    """
    want: dict[str, set[str]] = {}
    for d in state.get("deps", []):
        if d.get("behind"):
            want.setdefault(d["dep"], set()).add(d.get("tag") or d["latest"])
    have = {(p["dep"], p["version"]) for p in state.get("probes", [])}
    lost = []
    for job in jobs:
        name = job.get("name", "")
        dep = name.removeprefix("Probe ")
        if (name.startswith("Probe ") and job.get("conclusion") == "success"
                and want.get(dep) and not any((dep, v) in have for v in want[dep])):
            lost.append({"dep": dep, "job": name, "url": job.get("html_url", "")})
    return lost


def push_notice(state: dict) -> list[str]:
    """A banner when this run's verdicts did not all reach their branches."""
    push, lost = state.get("push_result", ""), state.get("lost_verdicts", [])
    failed = push not in ("", "success", "skipped")
    if not failed and not lost:
        return []
    ended = f" (the push job ended `{push}`)" if failed else ""
    out = [f"> ⚠️ **This run did not record all its probe verdicts{ended}.** A verdict "
           "below is the last one that reached a branch, not necessarily this run's, so a "
           "dependency can read \"not probed\" or \"probe failed\" for a version it has "
           "since passed. If the job's log says `Invalid username or token`, the "
           "`CLEA_WORKFLOW_TOKEN` secret was rejected: replace it (`docs/clea.md`)."]
    if lost:
        out += ["", "Probe job finished, verdict not recorded:", ""]
        out += [f"- `{s['dep']}` — [{s['job']}]({s['url']})" for s in lost]
    return out + [""]


def render_report(state: dict) -> str:
    deps = state.get("deps", [])
    behind = [d for d in deps if d.get("behind")]
    unpinned = [d for d in deps if not d.get("pinned")]
    lines = [f"_Generated {state.get('generated_at', '?')} by "
             "[Cléa](../blob/main/scripts/clea/README.md). "
             "This issue is rewritten in place; do not open another._", ""]
    lines += push_notice(state)

    lines += ["## Behind upstream", ""]
    if behind:
        rows = []
        for d in behind:
            # Matched on the TAG, not on `latest`. `cmd_matrix` hands the probe
            # `dep.get("tag") or dep["latest"]` — the raw upstream tag, unstripped
            # — because a dependency can be pinned in two shapes across its
            # anchors (see fluxcd/flux2) and only the tag becomes both. `latest`
            # is THIS anchor's own extracted form, and for anything with an
            # extractVersion clause that actually strips something (opentofu,
            # go-task, cloudnative-pg — anything using `^v(?<version>.*)$`),
            # tag and latest are DIFFERENT STRINGS for the same real version:
            # "v1.12.6" vs "1.12.6". Comparing against `latest` here meant three
            # of seven real probes never matched their own anchors and were
            # reported "not probed" despite running and pushing green — found
            # 2026-08-24 on this workflow's sixth real run, where exactly the
            # three dependencies with a stripping extractVersion were affected
            # and the four without one were not.
            expect = d.get("tag") or d["latest"]
            probe = next((p for p in state.get("probes", [])
                          if p["dep"] == d["dep"] and p["version"] == expect), None)
            verdict = "not probed"
            if probe:
                verdict = ("✅ probed green — `%s`" % probe["branch"]) if probe["green"] \
                    else "❌ probe failed"
            notes = f"[notes]({d['notes_url']})" if d.get("notes_url") else "—"
            shape = "" if d.get("shape_ok", True) else " ⚠️ prefix differs"
            rows.append([f"`{d['dep']}`", f"`{d['current']}`", f"`{d['latest']}`{shape}",
                         f"`{d['file']}:{d['line']}`", verdict, notes])
        lines += [_table(rows, ["dependency", "pinned", "upstream", "where",
                                "probe", "release"]), ""]
    else:
        lines += ["Nothing is behind. Every pin matches its upstream.", ""]

    unwatched = state.get("unwatched", [])
    novalue = state.get("novalue", [])
    lines += ["## Not watched", ""]
    if unwatched or novalue or unpinned:
        if unwatched:
            lines += ["**Anchored, but no inventory can see it** — the pin exists, "
                      "the bot that should propose the bump never reads it:", ""]
            lines += [f"- `{u['file']}:{u['line']}` — `{u['dep']}` = `{u['current']}`"
                      for u in unwatched] + [""]
        if novalue:
            lines += ["**Anchor marking no version** — it can never be bumped, and it "
                      "reads to a human as if it could:", ""]
            lines += [f"- `{n['file']}:{n['line']}` — `{n['dep']}`: {n.get('reason', '')}"
                      for n in novalue] + [""]
        if unpinned:
            rows = [[f"`{d['dep']}`", f"`{d.get('latest') or '?'}`",
                     f"`{d['file']}`" if d["file"] else "—",
                     "moved since last scan" if d.get("moved_since_last_scan") else ""]
                    for d in unpinned]
            lines += ["**Consumed at whatever upstream serves today** — no pin, so no "
                      "two machines are guaranteed the same tool:", "",
                      _table(rows, ["dependency", "upstream today", "consumed by",
                                    "note"]), ""]
    else:
        lines += ["Every pin is anchored, readable and watched.", ""]

    bot = state.get("bot")
    if bot:
        actionable = [d for d in deps
                      if d.get("behind") and d.get("pinned") and d.get("watched")]
        limit = bot.get("silent_after_days", 8)
        days = bot.get("days")
        lines += [f"## {bot['bot']}", ""]
        if bot.get("number") is None:
            lines += [f"No pull request from `{bot['bot']}` in the last "
                      f"{bot.get('scanned', 0)} on this repository.", ""]
        else:
            lines += [f"Last proposal: [#{bot['number']}]"
                      f"(../pull/{bot['number']}), {bot.get('at', '?')} "
                      f"({days} days ago).", ""]
        if actionable and (days is None or days > limit):
            lines += [f"> ⚠️ **{len(actionable)} dependency(ies) are behind that "
                      f"`{bot['bot']}` can see, and it has proposed nothing for "
                      f"{days if days is not None else 'longer than that list'} "
                      "days.** Silence alone means nothing — a bot with nothing "
                      "to propose is silent and correct. Silence *while* "
                      "something it watches is behind means it is not running.",
                      ""]
            lines += [f"> - `{d['dep']}` {d['current']} → {d['latest']} "
                      f"(`{d['file']}:{d['line']}`)" for d in actionable] + [""]
        elif actionable:
            lines += [f"{len(actionable)} behind and within its window — nothing "
                      "to conclude yet.", ""]
        else:
            lines += ["Nothing it watches is behind, so its silence proves "
                      "nothing either way.", ""]

    failed = [p for p in state.get("probes", []) if not p["green"]]
    if failed:
        lines += ["## Probe failures", ""]
        for probe in failed:
            lines += [f"### `{probe['dep']}` → `{probe['version']}`", "",
                      "```", probe.get("log", "(no log captured)").strip(), "```", ""]

    # A probe job can fail before it ever reaches the step that pushes its
    # verdict — GITHUB_TOKEN cannot push a change to a file under
    # .github/workflows/, with no `permissions:` grant able to fix that; a
    # transient runner failure would land here too. Either way, "no branch" and
    # "nothing to report" must not read the same: the dependency was tried and
    # the run knows it failed, even with no verdict to show.
    stalled = state.get("stalled_probes", [])
    if stalled:
        lines += ["## Probes that could not record a verdict", "",
                  "The job ran and failed before it could push its branch — a "
                  "gap in the reporting path, not necessarily in the bump "
                  "itself. See the run for why.", ""]
        lines += [f"- `{s['dep']}` — [{s['job']}]({s['url']})" for s in stalled] + [""]

    if state.get("errors"):
        # Grouped on the message with its URL removed: one rate limit produces
        # one failure per dependency, and twenty copies of the same sentence is
        # not twenty pieces of information.
        grouped: dict[str, list[str]] = {}
        for message in state["errors"]:
            url, _, rest = message.partition(" -> ")
            grouped.setdefault(rest or message, []).append(url)
        lines += ["## Datasources that did not answer", "",
                  "Not the same thing as up to date:", ""]
        for message, urls in list(grouped.items())[:8]:
            names = list(dict.fromkeys(u.rsplit("/repos/", 1)[-1] for u in urls))
            shown = ", ".join(f"`{n}`" for n in names[:6])
            more = f" and {len(names) - 6} more" if len(names) > 6 else ""
            lines += [f"- **{len(names)}×** {message}", f"  — {shown}{more}"]
        if len(grouped) > 8:
            lines += [f"- …and {len(grouped) - 8} other failure(s)"]
        lines += [""]

    lines += ["## What this did not test", "",
              "- **No real cloud, ever.** This lane carries no provider credential and "
              "must fail if it ever needs one. A deploy on Scaleway, OVH or Outscale is "
              "run by hand, by someone watching — see `CONTRIBUTING.md`.",
              "- A green probe means the tool installs from cold, upgrades over its "
              "previous version, and the repository's own checks still pass. It does not "
              "mean the new version behaves the same on a running cluster.",
              "- **A dependency pinned only inside `.github/workflows/` cannot be "
              "probed** unless a `CLEA_WORKFLOW_TOKEN` secret is set (a classic PAT, "
              "scope `workflow`) — GITHUB_TOKEN cannot push such a change in any "
              "repository, and no `permissions:` grant can fix that. The warning at "
              "the top of the report names the ones this run could not push."]
    cluster = state.get("cluster_lane")
    if cluster:
        lines += [f"- Weekly local cluster lane: **{cluster.get('verdict', '?')}**, "
                  f"last run {cluster.get('at', '?')} on Talos "
                  f"`{cluster.get('talos', '?')}` / Kubernetes `{cluster.get('k8s', '?')}`."]
    else:
        lines += ["- The weekly local cluster lane has not reported yet."]

    # A GitHub issue body caps at 65536 characters. The probe logs are already
    # rendered above, so they are the first thing to drop from the copy carried
    # forward — a state that makes the write fail loses the state entirely.
    embedded = json.dumps(state, separators=(",", ":"))
    if len(embedded) > 40000:
        trimmed = dict(state)
        trimmed["probes"] = [{k: v for k, v in p.items() if k != "log"}
                             for p in state.get("probes", [])]
        embedded = json.dumps(trimmed, separators=(",", ":"))
    lines += ["", "<!-- clea-state " + embedded + " -->"]
    return "\n".join(lines) + "\n"


def cmd_report(args) -> int:
    state = json.loads(Path(args.state).read_text(encoding="utf-8"))
    text = render_report(state)
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


# ---------------------------------------------------------------------------
# pick-issue — which open, labelled issue is Cléa's OWN report (#127)
# ---------------------------------------------------------------------------
# `render_report` always writes this exact text as the first line of the body
# it produces — the one thing every report issue carries and nothing else
# does. Matched together with the author identity the workflow's own
# PATCH/POST always write issues as (`[report] bot_login`, default
# github-actions[bot]): either alone can collide with an unrelated issue (a
# human can paste this text, and the bot opens other issues too), but the
# pair only ever matches an issue this automation itself produced.
REPORT_MARKER_RE = re.compile(
    r"^_Generated \S+ by \[Cléa\]\(\.\./blob/main/scripts/clea/README\.md\)\. "
    r"This issue is rewritten in place; do not open another\._"
)


def pick_report_issue(issues: list[dict], bot_login: str) -> dict | None:
    """Which of these open, label-matched issues is Cléa's own report.

    Not "the newest" (#127): a human labelling an unrelated issue with the
    report label — to cross-reference a finding, the natural thing to do — is
    picked instead by a naive `sort=created&per_page=1` the moment it is newer
    than the actual report, and the next scheduled run then PATCHes it,
    destroying the human-written content. #104 clobbered #91 exactly this way
    on 2026-08-28. Multiple matches (should not happen — the workflow only
    ever creates one, then rewrites it in place) fall back to the lowest
    issue number: the original report, not whichever the API happened to
    return first.
    """
    matches = [i for i in issues
              if (i.get("user") or {}).get("login") == bot_login
              and REPORT_MARKER_RE.match(i.get("body") or "")]
    return min(matches, key=lambda i: i["number"]) if matches else None


def cmd_pick_issue(args) -> int:
    cfg = load_config(repo_root(args.root) / args.config)
    issues = json.loads(Path(args.issues).read_text(encoding="utf-8"))
    picked = pick_report_issue(issues, cfg["report"].get("bot_login", "github-actions[bot]"))
    if args.body_out:
        Path(args.body_out).write_text((picked or {}).get("body") or "", encoding="utf-8")
    print(picked["number"] if picked else "")
    return 0


# ---------------------------------------------------------------------------
# bump
# ---------------------------------------------------------------------------

def cmd_bump(args) -> int:
    root = repo_root(args.root)
    cfg = load_config(root / args.config)
    scan = cfg["scan"]
    anchors, _ = scan_anchors(root, scan["marker"], scan["exclude"], scan["include"])
    targets = [a for a in anchors if a.dep == args.dep]
    if not targets:
        print(f"✗ no readable anchor for {args.dep}", file=sys.stderr)
        return 1

    # Before any write, so a refusal at the last site cannot leave the first rewritten.
    sha = getattr(args, "sha", None) or ""
    for anchor in targets:
        if anchor.form not in UNSAFE_BUMP_FORMS:
            continue
        where = f"{anchor.path}:{anchor.value_line}"
        if anchor.form == "action-sha" and SHA40.fullmatch(sha):
            lines = (root / anchor.path).read_text(encoding="utf-8").splitlines()
            uses = ACTION_USES.match(lines[(anchor.value_line or 1) - 1])
            if uses and "/".join(uses["repo"].split("/")[:2]).lower() == args.dep.lower():
                continue
            print(f"✗ {where} — this uses: line names another repository than {args.dep}: "
                  "its commit would be taken from the wrong one.", file=sys.stderr)
            return 1
        hint = (" Pass --sha with the commit the tag points at (the scan records it)."
                if anchor.form == "action-sha" else "")
        print(f"✗ {where} — {anchor.form} pins a commit that this write does not touch: "
              f"rewriting the comment to {apply_extract(args.version, anchor.attrs.get('extractVersion'))!r} "
              f"would claim that version while still running whatever {anchor.value!r} "
              "already points at. Renovate resolves the commit and the comment together "
              f"(helpers:pinGitHubActionDigests / pinDigests) — bump this one there, or by hand.{hint}",
              file=sys.stderr)
        return 1

    # Every site, not the first: one tool, one version, everywhere it is claimed.
    # Leaving a second copy behind is the drift this repository has paid for four
    # times in a week.
    changed = 0
    for anchor in targets:
        new_value = apply_extract(args.version, anchor.attrs.get("extractVersion"))
        if not same_shape(anchor.value or "", new_value):
            print(f"✗ {anchor.path}:{anchor.value_line} — {anchor.value!r} and "
                  f"{new_value!r} do not carry the same v prefix; the consumers of "
                  "this value read them differently", file=sys.stderr)
            return 1
        if anchor.value == new_value:
            continue
        path = root / anchor.path
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        idx = (anchor.value_line or 1) - 1
        start, end = anchor.span or (0, 0)
        line = lines[idx]
        lines[idx] = line[:start] + new_value + line[end:]
        if anchor.form == "action-sha":
            lines[idx] = ACTION_USES.sub(
                lambda m: f"{m['head']}{m['repo']}@{sha}{m['tail']}", lines[idx], count=1)
        path.write_text("".join(lines), encoding="utf-8")
        print(f"  {anchor.path}:{anchor.value_line}  {anchor.value} -> {new_value}")
        changed += 1

    # A writer that writes nothing is the false-green this whole file exists
    # against: the probe would then test the version already in the tree and
    # report the bump as proven.
    if not changed:
        print(f"✗ {args.dep} is already at {args.version} everywhere — nothing to "
              "probe", file=sys.stderr)
        return 1
    print(f"{changed} site(s) rewritten")
    return 0


# ---------------------------------------------------------------------------
# prune
# ---------------------------------------------------------------------------

def cmd_prune(args) -> int:
    """Probe branches whose bump has already landed on the base branch.

    Compared on the PIN, not on the diff: a probe branch also carries its own
    verdict file, so it never becomes byte-identical to the base and a diff test
    would prune nothing, ever.
    """
    root = repo_root(args.root)
    cfg = load_config(root / args.config)
    scan = cfg["scan"]
    anchors, _ = scan_anchors(root, scan["marker"], scan["exclude"], scan["include"])
    current: dict[str, str] = {}
    for anchor in anchors:
        # The lowest of a dependency's sites: while one file is still behind,
        # the bump has not fully landed and the branch is still worth keeping.
        if anchor.dep not in current or version_key(anchor.value or "") < version_key(current[anchor.dep]):
            current[anchor.dep] = anchor.value or ""

    refs = subprocess.run(
        ["git", "for-each-ref", "--format=%(refname:short)",
         f"refs/remotes/origin/{args.prefix}*"],
        capture_output=True, text=True, check=False).stdout.split()
    for ref in refs:
        blob = subprocess.run(["git", "show", f"{ref}:clea-probe.json"],
                              capture_output=True, text=True, check=False)
        if blob.returncode != 0:
            continue  # not one of ours, or pushed before the verdict file existed
        try:
            probe = json.loads(blob.stdout)
        except ValueError:
            continue
        landed = current.get(probe.get("dep", ""))
        if landed and not is_newer(landed, probe.get("version", "")):
            print(ref.removeprefix("origin/"))
    return 0


# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="clea", description=__doc__.splitlines()[0])
    parser.add_argument("--root", help="repository root (default: git toplevel)")
    parser.add_argument("--config", default="clea.toml")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("coverage", help="offline: every pin readable and watched")

    p_scan = sub.add_parser("scan", help="online: resolve upstream versions")
    p_scan.add_argument("--state", default="clea-state.json")
    p_scan.add_argument("--previous", help="last state file, or a report embedding one")
    p_scan.add_argument("--strict", action="store_true",
                        help="exit 1 if any datasource failed to answer")

    p_config = sub.add_parser("config", help="print one dotted key from clea.toml")
    p_config.add_argument("key")

    p_matrix = sub.add_parser("matrix", help="GitHub Actions matrix of what to probe")
    p_matrix.add_argument("--state", default="clea-state.json")
    p_matrix.add_argument("--daily", action="store_true",
                          help="skip anything a tool row marked daily = false")
    p_matrix.add_argument("--heavy-only", action="store_true",
                          help="only what daily skips")

    p_report = sub.add_parser("report", help="render Markdown from a state file")
    p_report.add_argument("--state", default="clea-state.json")
    p_report.add_argument("--out")

    p_pick = sub.add_parser("pick-issue", help="which open issue is Cléa's own report")
    p_pick.add_argument("--issues", default="issues.json",
                        help="GitHub API issue list (JSON array), as fetched by the workflow")
    p_pick.add_argument("--body-out", help="write the picked issue's body here (empty if none)")

    p_bump = sub.add_parser("bump", help="rewrite a pin in place")
    p_bump.add_argument("--sha", help="the commit the tag points at: what an action-sha "
                                      "pin needs to move with its comment")
    p_bump.add_argument("dep")
    p_bump.add_argument("version")

    p_prune = sub.add_parser("prune", help="name probe branches already landed")
    p_prune.add_argument("--base", default="main")
    p_prune.add_argument("--prefix", default="clea/probe/")

    args = parser.parse_args(argv)
    handlers = {"coverage": cmd_coverage, "scan": cmd_scan, "report": cmd_report,
                "bump": cmd_bump, "prune": cmd_prune, "matrix": cmd_matrix,
                "config": cmd_config, "pick-issue": cmd_pick_issue}
    try:
        return handlers[args.command](args)
    except CleaError as exc:
        print(f"✗ {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
