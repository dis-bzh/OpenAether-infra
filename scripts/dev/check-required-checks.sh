#!/usr/bin/env bash
# What GitHub enforces here lives in repository settings, where no pull request
# sees it drift (#122). This compares it against what actually happens:
#   - required checks: the rules on main vs. the check runs reported on the head
#     of the last merged PR, read from the API (CodeQL has no workflow file);
#   - tags: an active ruleset blocks moving or deleting every tag, no bypass;
#   - private vulnerability reporting is on, as SECURITY.md tells reporters;
#   - main: pull request, no force-push and no deletion are required; signed commits, bypass
#     actors and approving reviews are WARNINGS (a lone maintainer cannot approve their own
#     PR; signatures wait for a signing key), failures under --strict-main;
#   - rulesets as code: .github/rulesets/*.json is what GitHub enforces, field for field;
#   - the `sandbox` environment real-cloud-regression.yml runs in has required reviewers
#     and a branch restriction to `main` (absent = warning: the workflow is dormant).
# Exit 0 matches, 1 differs, 2 not verifiable. An empty or unreadable answer is
# 2, never "nothing is required". Run by .github/workflows/repo-settings.yml.
#
# Usage:
#   check-required-checks.sh --self-test     # offline, task test-scripts
#   check-required-checks.sh <owner> <repo> [--ref <commit>] [--tolerate-unreadable-bypass]
#                            [--strict-main] [--rulesets-dir <dir>]
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
SANDBOX = "sandbox"  # the environment real-cloud-regression.yml runs in


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
        # A run cancelled before its matrix expanded keeps the literal name (#293): editing a PR body while CI runs leaves
        # `Emulated Cloud (${{ matrix.provider }})` behind. It never ran, so it is no check "nobody declared". Only a
        # CANCELLED run with an unexpanded name is skipped: any other run of that name still counts.
        if "${{" in r["name"] and r.get("conclusion") == "cancelled":
            continue
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


def warn(out, text):
    out(("::warning::" if os.environ.get("GITHUB_ACTIONS") == "true" else "") + "⚠ " + text)


def check_main(api, repo, strict, tolerate_unreadable_bypass, out):
    rules = [r for _, page in pages(api, f"/repos/{repo}/rules/branches/{BRANCH}?per_page=100") for r in page]
    types = {r.get("type") for r in rules}
    problems = [f"no {t} rule on {BRANCH}" for t in ("pull_request", "non_fast_forward", "deletion") if t not in types]

    def soft(text):  # a warning, or a failure under --strict-main
        if strict:
            problems.append(text)
        else:
            warn(out, text)

    counts = [(r.get("parameters") or {}).get("required_approving_review_count") for r in rules
              if r.get("type") == "pull_request"]
    need(all(isinstance(c, int) for c in counts), "a pull_request rule without a review count")
    if counts and max(counts) < 1:
        soft("pull requests need 0 approving reviews: one maintainer cannot approve their own, so this is "
             "organisational until a second reviewer exists")
    if "required_signatures" not in types:
        soft(f"no required_signatures rule on {BRANCH}: commits are not required to be signed")
    for rid in sorted({r.get("ruleset_id") for r in rules if r.get("ruleset_id") is not None}):
        rs, _ = fetch(api, f"/repos/{repo}/rulesets/{rid}")
        need(isinstance(rs, dict), f"ruleset {rid}: unexpected shape")
        if "bypass_actors" not in rs:
            need(tolerate_unreadable_bypass, f"ruleset {rs.get('name')}: this token cannot read its bypass actors")
            warn(out, f"ruleset {rs.get('name')}: bypass actors not verified, this token cannot read them")
        else:
            need(isinstance(rs["bypass_actors"], list) and all(isinstance(a, dict) for a in rs["bypass_actors"]),
                 f"ruleset {rid}: unexpected shape")
            if rs["bypass_actors"]:
                soft(f"ruleset {rs.get('name')} lets " + ", ".join(
                    f"{a.get('actor_type')}({a.get('actor_id')}, {a.get('bypass_mode')})" for a in rs["bypass_actors"])
                    + f" bypass it: {BRANCH} can be changed without a pull request")
    return problems, f"{BRANCH} requires a pull request and blocks force-push and deletion"


VOLATILE = {"id", "node_id", "source", "source_type", "created_at", "updated_at", "_links", "current_user_can_bypass"}


def normalise(rs, with_bypass):
    rs = {k: v for k, v in rs.items() if k not in VOLATILE and (with_bypass or k != "bypass_actors")}
    rules = []
    for r in rs.get("rules") or []:
        r = copy.deepcopy(r)
        params = r.get("parameters")
        if isinstance(params, dict) and isinstance(params.get("required_status_checks"), list):
            params["required_status_checks"] = sorted(params["required_status_checks"], key=json.dumps)
        rules.append(r)
    rs["rules"] = sorted(rules, key=json.dumps)
    return rs


def check_rulesets_as_code(api, repo, committed, out):
    if committed is None:
        out("no rulesets directory given: not compared")
        return [], ""
    live = {}
    for s in (s for _, page in pages(api, f"/repos/{repo}/rulesets?per_page=100") for s in page):
        rs, _ = fetch(api, f"/repos/{repo}/rulesets/{s.get('id')}")
        need(isinstance(rs, dict) and isinstance(rs.get("name"), str), f"ruleset {s.get('id')}: unexpected shape")
        live[rs["name"]] = rs
    problems = []
    for name in sorted(set(live) | set(committed)):
        if name not in committed:
            problems.append(f"ruleset {name} is enforced on GitHub and not committed under .github/rulesets/")
        elif name not in live:
            problems.append(f"ruleset {name} is committed and GitHub has no such ruleset")
        else:
            # bypass_actors come back only to an admin: when the live one lacks them, compare the rest.
            with_bypass = "bypass_actors" in live[name]
            a, b = normalise(committed[name], with_bypass), normalise(live[name], with_bypass)
            if a != b:
                keys = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
                problems.append(f"ruleset {name} differs from .github/rulesets/: " + ", ".join(keys))
    return problems, f"{len(live)} ruleset(s) match .github/rulesets/ field for field"


def check_environment(api, repo, out):
    status, text, _ = api.get(f"/repos/{repo}/environments/{SANDBOX}")
    if status == 404:
        warn(out, f"no environment '{SANDBOX}': real-cloud-regression.yml would create it unprotected on its first run")
        return [], ""
    need(status == 200, f"GET environment {SANDBOX} answered HTTP {status}")
    try:
        env = json.loads(text)
    except ValueError:
        raise NotVerifiable(f"environment {SANDBOX} did not answer JSON")
    need(isinstance(env, dict) and isinstance(env.get("protection_rules", []), list), f"environment {SANDBOX}: unexpected shape")
    problems = []
    if not any(isinstance(p, dict) and p.get("type") == "required_reviewers" for p in env.get("protection_rules", [])):
        problems.append(f"environment {SANDBOX} has no required reviewers: any run on it reads the provider keys unattended")
    policy = env.get("deployment_branch_policy")
    if not policy:
        problems.append(f"environment {SANDBOX} accepts any branch: a user with write access can run their own branch with its secrets")
    elif policy.get("custom_branch_policies"):
        # A custom policy is only a restriction if the patterns are main: `*` is "any branch" with a policy attached.
        names = [p.get("name") for _, page in pages(api, f"/repos/{repo}/environments/{SANDBOX}/deployment-branch-policies?per_page=100",
                                                    "branch_policies") for p in page]
        if not names or any(n != BRANCH for n in names):
            problems.append(f"environment {SANDBOX} allows {names or 'no pattern'}, not only '{BRANCH}': a branch matching one of them runs with its secrets")
    else:
        warn(out, f"environment {SANDBOX} is limited to protected branches, not to '{BRANCH}': any branch with classic protection can run it")
    return problems, f"environment {SANDBOX}: required reviewers and a branch restriction"


def run(api, repo, ref=None, tolerate_unreadable_bypass=False, strict_main=False, committed=None, out=print):
    worst = 0
    for title, check in (("required checks", lambda: check_required(api, repo, ref, out)),
                         ("tag protection", lambda: check_tags(api, repo, tolerate_unreadable_bypass, out)),
                         ("main branch", lambda: check_main(api, repo, strict_main, tolerate_unreadable_bypass, out)),
                         ("rulesets as code", lambda: check_rulesets_as_code(api, repo, committed, out)),
                         ("sandbox environment", lambda: check_environment(api, repo, out)),
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
        elif ok:
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

    def add_run(a, name, app=ACTIONS_APP, conclusion="success"):
        for p in (RUNS, RUNS + "&page=2"):
            body(a, p)["total_count"] += 1
        body(a, RUNS + "&page=2")["check_runs"].append({"name": name, "app": {"id": app, "slug": "other-app"},
                                                         "conclusion": conclusion})

    def drop_run(a):
        for p in (RUNS, RUNS + "&page=2"):
            body(a, p)["total_count"] -= 1
        body(a, RUNS + "&page=2")["check_runs"].pop()

    def sandbox_env(a, patterns):
        return {R + "/environments/sandbox": {"status": 200, "body": {
            "name": "sandbox", "protection_rules": [{"type": "required_reviewers"}, {"type": "branch_policy"}],
            "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}}},
                R + "/environments/sandbox/deployment-branch-policies?per_page=100": {"status": 200, "body": {
                    "total_count": len(patterns), "branch_policies": [{"name": n, "type": "branch"} for n in patterns]}}}

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
        ("a cancelled run with an unexpanded matrix name (a PR body edited while CI ran, #293)",
         lambda a: add_run(a, "Emulated Cloud (${{ matrix.provider }})", conclusion="cancelled"), {}, 0, "all and only what reported"),
        ("... but an unexpanded name that did NOT get cancelled still fails",
         lambda a: add_run(a, "Emulated Cloud (${{ matrix.provider }})", conclusion="success"), {}, 1,
         "reported but not required: Emulated Cloud (${{ matrix.provider }})"),
        ("... and a cancelled run with a plain unrequired name still fails",
         lambda a: add_run(a, "Analyze (actions)", conclusion="cancelled"), {}, 1, "reported but not required: Analyze (actions)"),
        ("a required name reported by another app", lambda a: add_run(a, "Lint & Format", 999), {}, 1,
         "reported but not required: Lint & Format (from app other-app"),
        ("a required check does not report", drop_run, {}, 1, "required but not reported by GitHub Actions: Analyze"),
        ("a required context pinned to no app", lambda a: body(a, RULES)[1]["parameters"]["required_status_checks"][0]
         .pop("integration_id"), {}, 1, "Lint & Format is required from app None"),
        ("a required context pinned to another app", lambda a: body(a, RULES)[1]["parameters"]
         ["required_status_checks"][0].update(integration_id=999), {}, 1, "Lint & Format is required from app 999"),
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
        ("the tag ruleset covers refs/tags/* only: one path segment, not every tag",
         lambda a: tags(a)["conditions"]["ref_name"].update(include=["refs/tags/*"]), {}, 1, "not every tag"),
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
         lambda a: tags(a)["conditions"]["ref_name"].update(include=["refs/tags/**"]), {"committed": None}, 0, "active on every tag"),
        ("a gapped tag ruleset listed before a sound one", gapped_tag_ruleset_first, {"committed": None}, 0,
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
        # main branch, rulesets as code, the sandbox environment (SCC/F16, SCC/F12)
        ("main: a pull request, no force-push, no deletion are required; reviews and signatures only warn", None, {}, 0,
         "main requires a pull request and blocks force-push and deletion"),
        ("... and say so: 0 approving reviews, no required_signatures", None, {}, 0, "no required_signatures rule on main"),
        ("... 0 reviews is named organisational", None, {}, 0, "organisational"),
        ("main without a pull_request rule", lambda a: body(a, RULES).pop(3), {}, 1, "no pull_request rule on main"),
        ("main without non_fast_forward", lambda a: body(a, RULES).pop(2), {}, 1, "no non_fast_forward rule on main"),
        ("main without deletion", lambda a: body(a, RULES).pop(0), {}, 1, "no deletion rule on main"),
        ("--strict-main: no signatures fails", None, {"strict_main": True}, 1, "✗ no required_signatures rule on main"),
        ("--strict-main: 0 approving reviews fails", None, {"strict_main": True}, 1, "✗ pull requests need 0 approving reviews"),
        ("--strict-main: all met passes",
         lambda a: (body(a, RULES).append({"type": "required_signatures", "ruleset_id": 1}),
                    body(a, RULES)[3]["parameters"].update(required_approving_review_count=1)),
         {"strict_main": True, "committed": None}, 0, "main requires a pull request"),
        ("a bypass actor on main is a warning", lambda a: (body(a, "/rulesets/1")["bypass_actors"].append(
            {"actor_type": "RepositoryRole", "actor_id": 5, "bypass_mode": "always"})), {"committed": None}, 0,
         "⚠ ruleset main lets RepositoryRole(5, always) bypass it"),
        ("... and a failure under --strict-main", lambda a: body(a, "/rulesets/1")["bypass_actors"].append(
            {"actor_type": "OrganizationAdmin", "actor_id": None, "bypass_mode": "always"}), {"strict_main": True, "committed": None}, 1,
         "✗ ruleset main lets OrganizationAdmin"),
        ("main's bypass actors unreadable without the flag", lambda a: body(a, "/rulesets/1").pop("bypass_actors"), {"committed": None}, 2,
         "ruleset main: this token cannot read its bypass actors"),
        ("a pull_request rule whose review count is a string", lambda a: body(a, RULES)[3]["parameters"].update(
            required_approving_review_count="1"), {}, 2, "without a review count"),
        ("rulesets as code: the committed files match", None, {}, 0, "2 ruleset(s) match .github/rulesets/ field for field"),
        ("... a rule list in another order still matches", lambda a: body(a, "/rulesets/2")["rules"].reverse(), {}, 0,
         "match .github/rulesets/"),
        ("... a required check added on GitHub only", lambda a: body(a, "/rulesets/1")["rules"][3]["parameters"]
         ["required_status_checks"].append({"context": "Extra", "integration_id": ACTIONS_APP}), {}, 1,
         "ruleset main differs from .github/rulesets/: rules"),
        ("... enforcement switched to evaluate on GitHub", lambda a: body(a, "/rulesets/1").update(enforcement="evaluate"), {}, 1,
         "ruleset main differs from .github/rulesets/: enforcement"),
        ("... a ruleset on GitHub with no file", lambda a: (body(a, RULESETS).append({"id": 9, "name": "extra", "target": "branch"}),
                                                          a.update({R + "/rulesets/9": {"status": 200, "body": {"id": 9, "name": "extra", "rules": []}}})),
         {}, 1, "ruleset extra is enforced on GitHub and not committed"),
        ("... a committed file GitHub does not have", lambda a: a.pop(R + "/rulesets/2") and body(a, RULESETS).pop(), {}, 1,
         "ruleset tags is committed and GitHub has no such ruleset"),
        ("... bypass actors are compared only when the API returned them", lambda a: body(a, "/rulesets/1").pop("bypass_actors"),
         {"tolerate_unreadable_bypass": True}, 0, "match .github/rulesets/"),
        ("... no directory given: not compared, and said", None, {"committed": None}, 0, "no rulesets directory given"),
        ("sandbox environment absent: a warning", None, {}, 0, "⚠ no environment 'sandbox'"),
        ("... present with reviewers and a branch rule", lambda a: a.update(sandbox_env(a, ["main"])), {}, 0,
         "environment sandbox: required reviewers and a branch restriction"),
        ("... a custom branch policy that allows every branch (`*`)", lambda a: a.update(sandbox_env(a, ["main", "*"])), {}, 1,
         "not only 'main'"),
        ("... a custom branch policy with no pattern", lambda a: a.update(sandbox_env(a, [])), {}, 1, "allows no pattern"),
        ("... limited to protected branches only: a warning", lambda a: a.update({R + "/environments/sandbox": {"status": 200, "body": {
            "name": "sandbox", "protection_rules": [{"type": "required_reviewers"}],
            "deployment_branch_policy": {"protected_branches": True, "custom_branch_policies": False}}}}), {}, 0,
         "limited to protected branches"),
        ("... present without required reviewers", lambda a: (a.update(sandbox_env(a, ["main"])),
                                                              a[R + "/environments/sandbox"]["body"].update(protection_rules=[])), {}, 1,
         "has no required reviewers"),
        ("... present accepting any branch", lambda a: a.update({R + "/environments/sandbox": {"status": 200, "body": {
            "name": "sandbox", "protection_rules": [{"type": "required_reviewers"}], "deployment_branch_policy": None}}}), {}, 1,
         "accepts any branch"),
        ("... unreadable (403)", lambda a: a.update({R + "/environments/sandbox": {"status": 403, "body": ""}}), {}, 2, "HTTP 403"),
        ("a field no guard covers, of another type: bypass actors as strings",
         lambda a: tags(a).update(bypass_actors=["OrganizationAdmin"]), {}, 2, "cannot read (AttributeError"),
        ("... a merge time as a number, and the later sections still run",
         lambda a: body(a, PULLS + "&page=2")[0].update(merged_at=5), {}, 2, "'str')\n--- tag protection"),
        ("... a PR without a number", lambda a: body(a, PULLS + "&page=2")[0].pop("number"), {}, 2,
         "cannot read (KeyError"),
    ]
    failed = 0
    committed = {n: copy.deepcopy(base[R + f"/rulesets/{i}"]["body"]) for n, i in (("main", 1), ("tags", 2))}
    for what, mutate, options, want, needle in cases:
        api = copy.deepcopy(base)
        os.environ.pop("GITHUB_ACTIONS", None)  # same output under task test-scripts in CI as locally
        if mutate:
            mutate(api)
        lines = []
        got = run(FakeAPI(api), "example-org/example-repo", out=lines.append, **{"committed": copy.deepcopy(committed), **options})
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
    p.add_argument("--strict-main", action="store_true",
                   help="fail, instead of warning, on main without required signatures, with fewer than one approving "
                        "review, or with bypass actors")
    p.add_argument("--rulesets-dir", default=".github/rulesets",
                   help="the committed rulesets (<name>.json each) to compare with GitHub; skipped when absent")
    a = p.parse_args(argv)
    committed = None
    if os.path.isdir(a.rulesets_dir):
        committed = {}
        for f in sorted(os.listdir(a.rulesets_dir)):
            if f.endswith(".json"):
                doc = json.load(open(os.path.join(a.rulesets_dir, f)))
                committed[doc.get("name") or f[:-5]] = doc
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print("⚠ no GITHUB_TOKEN/GH_TOKEN: 60 requests an hour per IP", file=sys.stderr)
    code = run(LiveAPI(token), f"{a.owner}/{a.repo}", a.ref, a.tolerate_unreadable_bypass, a.strict_main, committed)
    print({0: "OK", 1: "DIFFERS from what GitHub enforces", 2: "NOT VERIFIABLE"}[code])
    return code


sys.exit(main(sys.argv[1], sys.argv[2:]))
PY
