#!/usr/bin/env bash
# What GitHub enforces here lives in repository settings, where no pull request
# sees it drift (#122). This compares it against what actually happens:
#   - required checks: the rules on main vs. the check runs reported on the head
#     of the last merged PR, read from the API (CodeQL has no workflow file);
#   - tags: an active ruleset blocks moving or deleting every tag, no bypass;
#   - private vulnerability reporting is on, as SECURITY.md tells reporters.
# Exit 0 matches, 1 differs, 2 not verifiable. An empty or unreadable answer is
# 2, never "nothing is required". Run by .github/workflows/repo-settings.yml.
#
# Usage:
#   check-required-checks.sh --self-test     # offline, task test-scripts
#   check-required-checks.sh <owner> <repo> [--ref <commit>] [--tolerate-unreadable-bypass]
#                                            # live, GITHUB_TOKEN/GH_TOKEN if set
set -euo pipefail

exec python3 - "$(dirname "${BASH_SOURCE[0]}")/testdata/check-required-checks/api.json" "$@" <<'PY'
import argparse, copy, http.client, json, os, re, sys, urllib.error, urllib.parse, urllib.request

API = "https://api.github.com"
BRANCH = "main"
# GitHub Actions. A required context pinned to no app is satisfied by any app's
# check run or by a commit status, which is weaker than what main requires.
ACTIONS_APP = 15368
EVERY_TAG = {"~ALL", "refs/tags/**"}


class NotVerifiable(Exception):
    pass


def need(cond, what):
    if not cond:
        raise NotVerifiable(what)


class LiveAPI:
    def __init__(self, token):
        self.headers = {"Accept": "application/vnd.github+json", "User-Agent": "check-required-checks",
                        "X-GitHub-Api-Version": "2022-11-28"}
        if token:
            self.headers["Authorization"] = f"Bearer {token}"

    def get(self, path):
        """(status, text, next page's path or None)"""
        try:
            with urllib.request.urlopen(urllib.request.Request(API + path, headers=self.headers), timeout=30) as r:
                status, text, link = r.status, r.read().decode(), r.headers.get("Link") or ""
        except urllib.error.HTTPError as e:
            return e.code, "", None
        # A cut-off body or a non-UTF-8 one must end as exit 2, not as a traceback's exit 1.
        except (OSError, http.client.HTTPException, ValueError) as e:
            raise NotVerifiable(f"GET {path}: {e}")
        m = re.search(r'<([^>]+)>;\s*rel="next"', link)
        return status, text, m.group(1).removeprefix(API) if m else None


class FakeAPI:
    def __init__(self, responses):
        self.responses = responses

    def get(self, path):
        r = self.responses.get(path, {"status": 404, "body": ""})
        body = r["body"] if isinstance(r["body"], str) else json.dumps(r["body"])
        return r["status"], body, r.get("next")


def fetch(api, path):
    status, text, nxt = api.get(path)
    need(status == 200, f"GET {path} answered HTTP {status}")
    try:
        return json.loads(text), nxt
    except ValueError:
        raise NotVerifiable(f"GET {path} did not answer JSON")


def pages(api, path, key=None):
    """Yield (page, its items), following rel="next"; `key` names the list inside a page."""
    while path:
        where = path
        data, path = fetch(api, path)
        items = (data.get(key) if isinstance(data, dict) else None) if key else data
        need(isinstance(items, list) and all(isinstance(i, dict) for i in items), f"GET {where}: unexpected shape")
        yield data, items


def last_merged_pr(api, repo):
    # Sorted by update, not merge: a comment moves an old PR up. Keep the latest
    # merged_at until a PR updated before it shows no later one can follow.
    best = None
    path = f"/repos/{repo}/pulls?state=closed&base={BRANCH}&sort=updated&direction=desc&per_page=100"
    for pr in (pr for _, prs in pages(api, path) for pr in prs):
        if best and str(pr.get("updated_at")) < best["merged_at"]:
            break
        if pr.get("merged_at") and (not best or pr["merged_at"] > best["merged_at"]):
            best = pr
    need(best, f"no pull request was ever merged into {BRANCH}: no commit shows what runs on one")
    need(isinstance(best.get("head"), dict) and isinstance(best["head"].get("sha"), str), "a PR without a head sha")
    return best


def check_required(api, repo, ref, out):
    rules = [r for _, page in pages(api, f"/repos/{repo}/rules/branches/{BRANCH}?per_page=100") for r in page]
    contexts = [c for r in rules if r.get("type") == "required_status_checks"
                for c in r["parameters"]["required_status_checks"]]
    need(contexts, f"no required status check in the rules on {BRANCH}; an empty answer is not "
                   "\"nothing is required\", it reads the same as one this token cannot see")
    problems, required = [], set()
    for c in contexts:
        need(isinstance(c, dict) and isinstance(c.get("context"), str), "a required status check without a context")
        if c.get("integration_id") != ACTIONS_APP:
            problems.append(f"{c['context']} is required from app {c.get('integration_id')}, not GitHub Actions "
                            f"({ACTIONS_APP}): another app could satisfy it")
        required.add((c["context"], ACTIONS_APP))

    if ref:
        sha, what = ref, "forced by --ref"
    else:
        pr = last_merged_pr(api, repo)
        sha, what = pr["head"]["sha"], f"head of PR #{pr['number']}, merged {pr['merged_at']}"
    out(f"evaluated: {sha} ({what})")
    runs, total = [], None
    for data, page in pages(api, f"/repos/{repo}/commits/{urllib.parse.quote(sha)}/check-runs?per_page=100",
                            key="check_runs"):
        runs += page
        total = data.get("total_count")
    need(total == len(runs), f"read {len(runs)} check runs of a total_count of {total}: a page went missing")
    reported = {}
    for r in runs:
        need(isinstance(r.get("name"), str) and isinstance(r.get("app"), dict), "a check run without a name or an app")
        reported[(r["name"], r["app"].get("id"))] = r["app"].get("slug")

    for name, _ in sorted(required - set(reported)):
        problems.append(f"required but not reported by GitHub Actions: {name}")
    # Any app counts: a check nobody declared is what #122 is about, whoever posts it.
    for key in sorted(set(reported) - required, key=str):
        problems.append(f"reported but not required: {key[0]}"
                        + ("" if key[1] == ACTIONS_APP else f" (from app {reported[key]}, id {key[1]})"))
    return problems, f"{len(required)} required, all and only what reported ({len(runs)} check runs)"


def check_tags(api, repo, tolerate_unreadable_bypass, out):
    listed = [s for _, page in pages(api, f"/repos/{repo}/rulesets?per_page=100") for s in page
              if s.get("target") == "tag"]
    if not listed:
        return ["no ruleset targets tags: any tag can be moved or deleted"], ""
    problems = []
    for s in listed:
        rs, _ = fetch(api, f"/repos/{repo}/rulesets/{s.get('id')}")
        need(isinstance(rs, dict) and all(isinstance(r, dict) for r in rs.get("rules") or []),
             f"ruleset {s.get('id')}: unexpected shape")
        ref = (rs.get("conditions") or {}).get("ref_name") or {}
        # The checks below test these by truthiness: a null or {} would read as "no bypass actors" or "no exclude".
        need(isinstance(rs.get("bypass_actors", []), list) and isinstance(ref.get("exclude", []), list),
             f"ruleset {s.get('id')}: unexpected shape")
        types = {r.get("type") for r in rs.get("rules") or []}
        gaps = [f"no {t} rule" for t in ("deletion", "update") if t not in types]
        if rs.get("enforcement") != "active":
            gaps.append(f"enforcement is {rs.get('enforcement')}")
        if not EVERY_TAG & set(ref.get("include") or []):
            gaps.append(f"includes {ref.get('include')}, not every tag (~ALL or refs/tags/**)")
        if ref.get("exclude"):
            gaps.append(f"excludes {ref['exclude']}")
        if rs.get("bypass_actors"):
            gaps.append("bypass actors " + ", ".join(str(a.get("actor_type")) for a in rs["bypass_actors"]))
        if gaps:
            problems.append(f"ruleset {rs.get('name')}: " + "; ".join(gaps))
            continue
        # Returned only to a token that can edit the ruleset; a workflow token never can.
        readable = "bypass_actors" in rs
        if not readable:
            need(tolerate_unreadable_bypass, f"ruleset {rs.get('name')}: this token cannot read its bypass actors")
            prefix = "::warning::" if os.environ.get("GITHUB_ACTIONS") == "true" else ""
            out(f"{prefix}⚠ ruleset {rs.get('name')}: bypass actors not verified, this token cannot read them")
        return [], (f"ruleset {rs.get('name')}: active on every tag, blocks deletion and update"
                    + (", no bypass actors" if readable else ""))
    return problems, ""


def check_pvr(api, repo):
    data, _ = fetch(api, f"/repos/{repo}/private-vulnerability-reporting")
    need(isinstance(data, dict) and isinstance(data.get("enabled"), bool), "private-vulnerability-reporting: unexpected shape")
    if not data["enabled"]:
        return ["disabled, while SECURITY.md sends reporters to it"], ""
    return [], "enabled, as SECURITY.md says"


def run(api, repo, ref=None, tolerate_unreadable_bypass=False, out=print):
    worst = 0
    for title, check in (("required checks", lambda: check_required(api, repo, ref, out)),
                         ("tag protection", lambda: check_tags(api, repo, tolerate_unreadable_bypass, out)),
                         ("private vulnerability reporting", lambda: check_pvr(api, repo))):
        out(f"--- {title}")
        try:
            problems, ok = check()
        except NotVerifiable as e:
            out(f"✗ not verifiable: {e}")
            worst = 2
            continue
        # A field of a type the code cannot read is as unverifiable as a 403, not a traceback's exit 1.
        except (AttributeError, KeyError, TypeError) as e:
            out(f"✗ not verifiable: an answer this script cannot read ({type(e).__name__}: {e})")
            worst = 2
            continue
        for p in problems:
            out(f"✗ {p}")
        if problems:
            worst = max(worst, 1)
        else:
            out(f"✓ {ok}")
    return worst


def self_test(fixture):
    base = json.load(open(fixture))
    R = "/repos/example-org/example-repo"
    RULES, RULESETS, TAGS, PVR = "/rules/branches/main?per_page=100", "/rulesets?per_page=100", "/rulesets/2", \
        "/private-vulnerability-reporting"
    PULLS = "/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100"
    RUNS = "/commits/0000000000000000000000000000000000000012/check-runs?per_page=100"

    def body(a, path):
        return a[R + path]["body"]

    def add_run(a, name, app=ACTIONS_APP):
        for p in (RUNS, RUNS + "&page=2"):
            body(a, p)["total_count"] += 1
        body(a, RUNS + "&page=2")["check_runs"].append({"name": name, "app": {"id": app, "slug": "other-app"}})

    def drop_run(a):
        for p in (RUNS, RUNS + "&page=2"):
            body(a, p)["total_count"] -= 1
        body(a, RUNS + "&page=2")["check_runs"].pop()

    def tags(a):
        return body(a, TAGS)

    def no_bypass_field(a):
        tags(a).pop("bypass_actors")

    def newest_merge_listed_first(a):  # older-merged #10 was commented on after #12 merged
        a[R + PULLS] = {"status": 200, "body": [body(a, PULLS + "&page=2")[0],
                                                dict(body(a, PULLS)[1], updated_at="2026-01-03T00:00:04Z")]}

    def gapped_tag_ruleset_first(a):
        body(a, RULESETS).insert(1, {"id": 3, "name": "old-tags", "target": "tag"})
        a[R + "/rulesets/3"] = {"status": 200, "body": dict(tags(a), id=3, name="old-tags", enforcement="evaluate")}

    cases = [  # (what, mutation, run() options, expected exit, expected in output)
        ("all match: PR #12 evaluated, not closed-unmerged #13 nor older-merged #10", None, {}, 0, "head of PR #12"),
        ("... and the tag ruleset's empty bypass list is read, not assumed", None, {}, 0, "no bypass actors"),
        ("an extra check reports (CodeQL-shaped)", lambda a: add_run(a, "Analyze (actions)"), {}, 1,
         "reported but not required: Analyze (actions)\n"),
        ("a required name reported by another app", lambda a: add_run(a, "Lint & Format", 999), {}, 1,
         "reported but not required: Lint & Format (from app other-app"),
        ("a required check does not report", drop_run, {}, 1, "required but not reported by GitHub Actions: Analyze"),
        ("a required context pinned to no app", lambda a: body(a, RULES)[1]["parameters"]["required_status_checks"][0]
         .pop("integration_id"), {}, 1, "Lint & Format is required from app None"),
        ("the rules answer is empty", lambda a: a[R + RULES].update(body=[]), {}, 2, "no required status check"),
        ("... and a later section differs: still 2",
         lambda a: (a[R + RULES].update(body=[]), body(a, PVR).update(enabled=False)), {}, 2, "disabled"),
        ("the rules answer is not JSON", lambda a: a[R + RULES].update(body="<html>rate limited</html>"), {}, 2,
         "did not answer JSON"),
        ("the closed-unmerged PR was merged last", lambda a: body(a, PULLS)[0].update(merged_at="2026-01-04T12:00:00Z"),
         {}, 1, "reported but not required: Draft preview"),
        ("the newest merge listed before an older one updated later", newest_merge_listed_first, {}, 0,
         "head of PR #12"),
        ("no PR was ever merged", lambda a: [pr.update(merged_at=None) for p in (PULLS, PULLS + "&page=2")
                                             for pr in body(a, p)], {}, 2, "no pull request was ever merged"),
        ("a check-runs page goes missing", lambda a: a[R + RUNS].pop("next"), {}, 2, "a page went missing"),
        ("a check-runs page without check_runs", lambda a: body(a, RUNS).pop("check_runs"), {}, 2, "unexpected shape"),
        ("a check-runs page that answers a list", lambda a: a[R + RUNS].update(body=[]), {}, 2, "unexpected shape"),
        ("a list item that is not an object", lambda a: body(a, RULESETS).append("tags"), {}, 2, "unexpected shape"),
        ("a PR without a head", lambda a: body(a, PULLS + "&page=2")[0].pop("head"), {}, 2, "without a head sha"),
        ("a PR head without a sha", lambda a: body(a, PULLS + "&page=2")[0]["head"].pop("sha"), {}, 2,
         "without a head sha"),
        ("a required status check without a context", lambda a: body(a, RULES)[1]["parameters"]
         ["required_status_checks"].append({"integration_id": ACTIONS_APP}), {}, 2, "without a context"),
        ("a required status check that is not an object", lambda a: body(a, RULES)[1]["parameters"]
         ["required_status_checks"].append("Lint & Format"), {}, 2, "without a context"),
        ("a check run without an app", lambda a: body(a, RUNS)["check_runs"][0].pop("app"), {}, 2,
         "without a name or an app"),
        ("a check run without a name", lambda a: body(a, RUNS)["check_runs"][0].pop("name"), {}, 2,
         "without a name or an app"),
        ("--ref evaluates the commit given", None, {"ref": "0000000000000000000000000000000000000010"}, 1,
         "0000000000000000000000000000000000000010 (forced by --ref)"),
        ("no ruleset targets tags", lambda a: body(a, RULESETS).pop(), {}, 1, "no ruleset targets tags"),
        ("the tag ruleset answers a list", lambda a: a[R + TAGS].update(body=[]), {}, 2, "ruleset 2: unexpected shape"),
        ("a tag ruleset rule that is not an object", lambda a: tags(a)["rules"].append("update"), {}, 2,
         "ruleset 2: unexpected shape"),
        ("a tag ruleset whose bypass actors are null, not a list", lambda a: tags(a).update(bypass_actors=None), {},
         2, "ruleset 2: unexpected shape"),
        ("... bypass actors {}, not a list", lambda a: tags(a).update(bypass_actors={}), {}, 2,
         "ruleset 2: unexpected shape"),
        ("a tag ruleset whose exclude is null, not a list",
         lambda a: tags(a)["conditions"]["ref_name"].update(exclude=None), {}, 2, "ruleset 2: unexpected shape"),
        ("... exclude {}, not a list", lambda a: tags(a)["conditions"]["ref_name"].update(exclude={}), {}, 2,
         "ruleset 2: unexpected shape"),
        ("the tag ruleset is disabled", lambda a: tags(a).update(enforcement="disabled"), {}, 1, "enforcement is disabled"),
        ("the tag ruleset covers v* only", lambda a: tags(a)["conditions"]["ref_name"].update(include=["refs/tags/v*"]),
         {}, 1, "not every tag"),
        ("the tag ruleset has no conditions", lambda a: tags(a).pop("conditions"), {}, 1, "not every tag"),
        ("the tag ruleset excludes some tags", lambda a: tags(a)["conditions"]["ref_name"].update(exclude=["refs/tags/tmp-*"]),
         {}, 1, "excludes"),
        ("the tag ruleset has a bypass actor", lambda a: tags(a)["bypass_actors"].append({"actor_type": "RepositoryRole"}),
         {}, 1, "bypass actors RepositoryRole"),
        ("the tag ruleset does not block update", lambda a: tags(a).update(rules=[{"type": "deletion"}]), {}, 1,
         "no update rule"),
        ("the tag ruleset does not block deletion", lambda a: tags(a).update(rules=[{"type": "update"}]), {}, 1,
         "no deletion rule"),
        ("the tag ruleset has no rules", lambda a: tags(a).pop("rules"), {}, 1, "no deletion rule"),
        ("the tag ruleset names every tag refs/tags/**",
         lambda a: tags(a)["conditions"]["ref_name"].update(include=["refs/tags/**"]), {}, 0, "active on every tag"),
        ("a gapped tag ruleset listed before a sound one", gapped_tag_ruleset_first, {}, 0,
         "ruleset tags: active on every tag"),
        ("bypass actors unreadable (not an admin token)", no_bypass_field, {}, 2, "cannot read its bypass actors"),
        ("... tolerated when asked, and said", no_bypass_field, {"tolerate_unreadable_bypass": True}, 0,
         "\n⚠ ruleset tags: bypass actors not verified"),
        ("... without claiming there are none", no_bypass_field, {"tolerate_unreadable_bypass": True}, 0,
         "blocks deletion and update\n"),
        ("... as an annotation under GitHub Actions",
         lambda a: (no_bypass_field(a), os.environ.update(GITHUB_ACTIONS="true")),
         {"tolerate_unreadable_bypass": True}, 0, "::warning::⚠ ruleset tags"),
        ("private vulnerability reporting disabled", lambda a: body(a, PVR).update(enabled=False), {}, 1, "disabled"),
        ("private vulnerability reporting answers 403", lambda a: a[R + PVR].update(status=403), {}, 2, "HTTP 403"),
        ("private vulnerability reporting answers a string", lambda a: body(a, PVR).update(enabled="false"), {}, 2,
         "unexpected shape"),
        ("private vulnerability reporting answers a list", lambda a: a[R + PVR].update(body=[]), {}, 2,
         "private-vulnerability-reporting: unexpected shape"),
        ("a field no guard covers, of another type: bypass actors as strings",
         lambda a: tags(a).update(bypass_actors=["OrganizationAdmin"]), {}, 2, "cannot read (AttributeError"),
        ("... a merge time as a number, and the later sections still run",
         lambda a: body(a, PULLS + "&page=2")[0].update(merged_at=5), {}, 2, "'str')\n--- tag protection"),
        ("... a PR without a number", lambda a: body(a, PULLS + "&page=2")[0].pop("number"), {}, 2,
         "cannot read (KeyError"),
    ]
    failed = 0
    for what, mutate, options, want, needle in cases:
        api = copy.deepcopy(base)
        os.environ.pop("GITHUB_ACTIONS", None)  # same output under task test-scripts in CI as locally
        if mutate:
            mutate(api)
        lines = []
        got = run(FakeAPI(api), "example-org/example-repo", out=lines.append, **options)
        text = "\n".join(lines)
        if got == want and needle in text:
            print(f"✓ exit {got}: {what}")
        else:
            failed += 1
            print(f"✗ {what}: expected exit {want} with {needle!r}, got exit {got}:\n  " + text.replace("\n", "\n  "))
    if failed:
        print(f"self-test FAILED: {failed} of {len(cases)}")
        return 1
    print(f"OK: {len(cases)} cases against a canned API, each check seen red and green")
    return 0


def main(fixture, argv):
    if argv == ["--self-test"]:
        return self_test(fixture)
    p = argparse.ArgumentParser(prog="check-required-checks.sh")
    p.add_argument("owner")
    p.add_argument("repo")
    p.add_argument("--ref", help="evaluate this commit instead of the last merged PR's head")
    p.add_argument("--tolerate-unreadable-bypass", action="store_true",
                   help="pass, with a warning, when the token cannot read the tag ruleset's bypass actors")
    a = p.parse_args(argv)
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print("⚠ no GITHUB_TOKEN/GH_TOKEN: 60 requests an hour per IP", file=sys.stderr)
    code = run(LiveAPI(token), f"{a.owner}/{a.repo}", a.ref, a.tolerate_unreadable_bypass)
    print({0: "OK", 1: "DIFFERS from what GitHub enforces", 2: "NOT VERIFIABLE"}[code])
    return code


sys.exit(main(sys.argv[1], sys.argv[2:]))
PY
