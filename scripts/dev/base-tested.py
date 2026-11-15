#!/usr/bin/env python3
"""Rung receipt, on an edit: the tests ran on the current base (#469).

ci.yml does not run on `edited`, so after a retarget the head keeps the old base's green
results. rung.yml fails the edit that retargets; this fails every later edit too, until a
ci.yml run for the head was created after the last base change (a push or a reopen starts one).
Reads GITHUB_EVENT_PATH; the token needs actions: read and pull-requests: read.
"""
import json
import os
import re
import sys
import urllib.request


def untested(base_changes, runs):
    """The reason the head is untested on its base, or None. Both lists hold ISO-8601 UTC times."""
    if not base_changes:
        return None
    changed = max(base_changes)
    if not runs or max(runs) <= changed:
        return (f"the base branch changed at {changed} and no ci.yml run for this head started after it: "
                "push a commit, or close and reopen this pull request.")
    return None


def get(url):
    """Every page of a GitHub API listing."""
    out = []
    while url:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                                                   "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            page = json.load(r)
            nxt = re.search(r'<([^>]+)>;\s*rel="next"', r.headers.get("Link") or "")
        out += page["workflow_runs"] if isinstance(page, dict) else page
        url = nxt and nxt.group(1)
    return out


def main():
    with open(os.environ["GITHUB_EVENT_PATH"]) as f:
        event = json.load(f)
    if event.get("action") != "edited":
        print("not an edit: this event starts ci.yml on the current base itself")
        return 0
    api, repo = os.environ.get("GITHUB_API_URL", "https://api.github.com"), os.environ["GITHUB_REPOSITORY"]
    pr = event["pull_request"]
    changes = [e["created_at"] for e in get(f"{api}/repos/{repo}/issues/{pr['number']}/timeline?per_page=100")
               if e.get("event") == "base_ref_changed"]
    runs = [r["created_at"] for r in get(f"{api}/repos/{repo}/actions/workflows/ci.yml/runs"
                                         f"?event=pull_request&head_sha={pr['head']['sha']}&per_page=100")]
    reason = untested(changes, runs)
    if reason:
        print(f"::error::{reason}")
        return 1
    print(f"tested on the current base ({len(changes)} base change(s), {len(runs)} ci.yml run(s) for the head)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
