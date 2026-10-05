#!/usr/bin/env python3
"""Check that every metric an alert rule reads is actually produced.

Why this exists
---------------
A rule built on a metric nobody produces evaluates cleanly, reports no error,
and never fires. It is indistinguishable from "nothing is wrong" — the exact
failure this platform's alerting is meant to remove. Three instances were found
by hand on 2026-07-29, each silent for as long as it had existed:
  * `gotk_reconcile_condition` — the Flux 2.3 metrics page still cites it, as
    deprecated; the controllers stopped recording it by about Flux 2.5 (inferred
    from flux2's go.mod, not measured). Per-object state is `gotk_resource_info`
    (kube-state-metrics), Ready being a label, not a value;
  * `kube_*` — kube-state-metrics had no NetworkPolicy, so nothing reached it;
  * `node_*` — the scrape named a port the chart does not use, so the target was
    never even discovered.

So: read the metric names out of the VMRules, ask the cluster which of them
have data, and print the ones that do not.

A hit is not automatically a bug — a metric can legitimately have no series yet
(no Certificate exists, no Job has failed). It is a question to answer, which is
better than silence.

Usage:
    KUBECONFIG=… python3 scripts/ops/check-alert-metrics.py [--strict]
    --strict exits 1 on any missing metric (for CI against a reference cluster).
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import urllib.parse
import urllib.request

INFRA = pathlib.Path(__file__).resolve().parents[2]
RULES_DIR = (
    INFRA.parent
    / "OpenAether-apps"
    / "apps"
    / "base"
    / "observability"
    / "vm-customresources"
)
NAMESPACE = "services-observability"
VMSELECT_SVC = "vmselect-victoria-metrics"
PORT = 8481
PATH = "/select/0/prometheus/api/v1/query"

# PromQL/MetricsQL functions and keywords that look like metric names.
NOT_A_METRIC = {
    "absent", "increase", "rate", "count", "max", "min", "sum", "avg", "by",
    "vector", "time", "on", "ignoring", "group_left", "group_right", "and",
    "or", "unless", "offset", "bool", "topk", "bottomk", "delta", "idelta",
    "irate", "changes", "clamp_max", "clamp_min", "histogram_quantile",
    "label_replace", "round", "scalar", "sort", "sort_desc", "without",
}
IDENT_RE = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*")
LABEL_BLOCK_RE = re.compile(r"\{[^{}]*\}")
DURATION_RE = re.compile(r"\[[^\]]*\]")


def metric_names(expr: str) -> set[str]:
    """Metric names in a PromQL expression, without the label names.

    Label matchers must go FIRST: `{condition="Ready"}` otherwise contributes
    `condition` and `Ready`, and the check then chases labels that are not
    metrics. Same for `[15m]` ranges and quoted strings.
    """
    expr = LABEL_BLOCK_RE.sub(" ", expr)
    expr = DURATION_RE.sub(" ", expr)
    expr = re.sub(r'"[^"]*"', " ", expr)
    # `by (namespace, job_name)` groups by LABELS, in parentheses rather than
    # braces — without this, every grouping label is chased as a metric.
    expr = re.sub(r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^()]*\)",
                  " ", expr)
    out = set()
    for m in IDENT_RE.finditer(expr):
        name = m.group(0)
        if name in NOT_A_METRIC or name.isdigit():
            continue
        # An identifier immediately followed by "(" is a function call.
        if expr[m.end():m.end() + 1] == "(":
            continue
        out.add(name)
    return out


def rule_metrics() -> dict[str, set[str]]:
    """Map each metric name to the alerts that read it."""
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML required: pip install pyyaml")

    found: dict[str, set[str]] = {}
    for path in sorted(RULES_DIR.glob("vmrule-*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if not doc or doc.get("kind") != "VMRule":
                continue
            for group in doc["spec"]["groups"]:
                for rule in group["rules"]:
                    for name in metric_names(rule.get("expr", "")):
                        found.setdefault(name, set()).add(rule["alert"])
    return found


def query(session_url: str, expr: str) -> int:
    url = f"{session_url}?" + urllib.parse.urlencode({"query": expr})
    try:
        with urllib.request.urlopen(url, timeout=20) as fh:
            return len(json.load(fh)["data"]["result"])
    except (urllib.error.URLError, TimeoutError, ValueError, KeyError):
        return -1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if any metric has no series")
    ap.add_argument("--local-port", type=int, default=18499)
    args = ap.parse_args()

    metrics = rule_metrics()
    if not metrics:
        sys.exit(f"no rules found under {RULES_DIR}")
    print(f"{len(metrics)} distinct metrics referenced by the alert rules")

    pf = subprocess.Popen(
        ["kubectl", "port-forward", "-n", NAMESPACE,
         f"svc/{VMSELECT_SVC}", f"{args.local_port}:{PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        import time
        time.sleep(6)
        base = f"http://localhost:{args.local_port}{PATH}"

        # Probe ONCE. Without this the loop prints the same failure 17 times,
        # which is how a tool teaches people to ignore it.
        if query(base, "vector(1)") < 0:
            print(f"✗ no reachable vmselect in {NAMESPACE} — is KUBECONFIG set, "
                  "and is the observability brick deployed?")
            return 2

        missing = []
        for name in sorted(metrics):
            if query(base, name) == 0:
                missing.append((name, sorted(metrics[name])))
    finally:
        pf.terminate()

    if not missing:
        print("OK — every metric read by a rule has data.")
        return 0

    print(f"\n{len(missing)} metric(s) with NO series — each alert below can never fire:")
    for name, alerts in missing:
        print(f"  {name}")
        for a in alerts:
            print(f"      used by {a}")
    print("\nEither the scrape is broken, or nothing has produced this yet "
          "(no Certificate, no failed Job…). Answer it; do not ignore it.")
    return 1 if args.strict else 0


if __name__ == "__main__":
    sys.exit(main())
