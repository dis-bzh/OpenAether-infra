#!/usr/bin/env bash
# Dates the real-cloud evidence in docs/status.md (#121). Per provider, the newest
# table row is stale when the Talos or Kubernetes it measured is not the pin, or
# when it is older than OA_EVIDENCE_MAX_AGE_DAYS (default 45: a policy, not a measurement).
#
# The pin is cluster/variables.tf's default, read with an EMPTY tfvars: the
# envs/*.tfvars.example are not watched by Renovate, and a workstation's real
# envs/*.tfvars must not change the verdict.
#
# It proves age and pin agreement, never that a run happened: a typed row looks like
# a measured one. The one verdict it reads is a ❌ or ⚠ anywhere in a row (a failed
# run is no evidence); a row that re-ran only the upgrade counts. Red by design while
# a provider lags the pin, so it is in neither `task lint` nor `task test`: a
# date-driven check there goes red with no commit.
#
# Exit 0 current, 1 stale, 2 not verifiable (the extractor is broken, not the
# repository: no table, a missing column, a bad or future date, no version).
# --warn makes stale exit 0 with a warning, for `task preflight`; 2 still fails.
# OA_EVIDENCE_TODAY=YYYY-MM-DD sets the clock for tests.
#
# Usage: check-evidence-age.sh [--warn] [--status FILE] [--cluster-dir DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"

STATUS="$ROOT/docs/status.md"
CLUSTER="$ROOT/infrastructure/opentofu/cluster"
WARN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --warn)        WARN=1; shift ;;
    --status)      STATUS="${2:?--status needs a file}"; shift 2 ;;
    --cluster-dir) CLUSTER="${2:?--cluster-dir needs a directory}"; shift 2 ;;
    *)             echo "✗ unknown argument: $1 — usage: check-evidence-age.sh [--warn] [--status FILE] [--cluster-dir DIR]" >&2; exit 2 ;;
  esac
done

talos="$(oa_pinned_version "$CLUSTER" "" talos_version)"
k8s="$(oa_pinned_version "$CLUSTER" "" kubernetes_version)"
for v in talos k8s; do
  [ -n "${!v}" ] || { echo "✗ could not read the $v pin from $CLUSTER/variables.tf — the extractor is broken, not the repository" >&2; exit 2; }
done

exec python3 - "$STATUS" "$talos" "$k8s" "$WARN" <<'PY'
import datetime as dt
import os
import re
import sys

status, talos_pin, k8s_pin, warn = sys.argv[1:5]


class NotVerifiable(Exception):
    pass


def need(cond, what):
    if not cond:
        raise NotVerifiable(what)


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def day(text, what):
    need(re.fullmatch(r"\d{4}-\d{2}-\d{2}", text), f"{what}: {text!r} is not YYYY-MM-DD")
    try:
        return dt.date.fromisoformat(text)
    except ValueError:
        raise NotVerifiable(f"{what}: {text!r} is not a date")


# A run that did not go through is no evidence at any version it mentions.
FAILED = ("❌", "⚠")


def version(text):
    # The LAST x.y.z: "1.13.7→1.13.8" measured 1.13.8, and a v prefix is not a difference.
    found = re.findall(r"(?<![\d.])\d+\.\d+\.\d+(?!\.?\d)", text)
    return found[-1] if found else None


def table(lines):
    """(header, rows) of the first pipe table with measured, k8s and Talos columns."""
    for i, line in enumerate(lines[:-1]):
        head = [c.replace("`", "").lower() for c in cells(line)]
        if line.lstrip().startswith("|") and {"measured", "k8s", "talos"} <= set(head) \
                and re.fullmatch(r"[|\s:-]+", lines[i + 1]):
            rows = []
            for row in lines[i + 2:]:
                if not row.lstrip().startswith("|"):
                    break
                rows.append(cells(row))
            return head, rows
    raise NotVerifiable(f"no table with the columns measured, k8s and Talos in {status}")


def check():
    try:
        text = open(status, encoding="utf-8").read()
    except (OSError, ValueError) as e:
        raise NotVerifiable(f"cannot read {status}: {e}")
    pins = {}
    for name, pin in (("talos", talos_pin), ("kubernetes", k8s_pin)):
        need(re.fullmatch(r"v?\d+\.\d+\.\d+", pin), f"the {name} pin {pin!r} is not a version")
        pins[name] = pin.lstrip("v")
    limit = os.environ.get("OA_EVIDENCE_MAX_AGE_DAYS", "45")
    need(re.fullmatch(r"[0-9]+", limit), f"OA_EVIDENCE_MAX_AGE_DAYS={limit!r} is not a number of days")
    today = day(os.environ.get("OA_EVIDENCE_TODAY") or dt.date.today().isoformat(), "OA_EVIDENCE_TODAY")

    print(f"pin: talos v{pins['talos']}, kubernetes v{pins['kubernetes']}; "
          f"evidence older than {limit} days is stale (today {today})")
    head, rows = table(text.splitlines())
    col = {name: head.index(name) for name in ("measured", "k8s", "talos")}
    latest = {}
    for row in rows:
        need(len(row) == len(head), f"row {row[0]!r} has {len(row)} cells, the header {len(head)}")
        m = re.match(r"[a-z]+", row[0].lower())
        need(m, f"row {row[0]!r} names no provider")
        date = day(row[col["measured"]].replace("`", ""), f"{row[0]}: measured")
        need(date <= today, f"{row[0]}: measured {date} is after today ({today})")
        failed = any(g in c for c in row for g in FAILED)
        cell = {"talos": row[col["talos"]], "kubernetes": row[col["k8s"]]}
        seen = {name: version(c) for name, c in cell.items()}
        for name, v in seen.items():
            need(v or failed, f"{row[0]}: the {name} cell {cell[name]!r} holds no version")
        # The later row wins a tie: a re-run is written under the row it re-runs.
        if m.group() not in latest or date >= latest[m.group()][0]:
            latest[m.group()] = (date, seen, failed)
    need(latest, "the table has no rows")

    stale = 0
    for provider, (date, seen, failed) in sorted(latest.items()):
        age = (today - date).days
        why = ["the row records a failure (❌ or ⚠)"] if failed else \
            [f"{name} measured v{seen[name]}, pinned v{pins[name]}" for name in pins if seen[name] != pins[name]]
        if age > int(limit):
            why.append(f"{age} days old, limit {limit}")
        if why:
            stale += 1
            print(f"✗ {provider} {date}: " + "; ".join(why))
        else:
            print(f"✓ {provider} {date} talos v{seen['talos']} kubernetes v{seen['kubernetes']} ({age} d)")
    print(f"{len(latest) - stale} current, {stale} stale")
    if stale and warn == "1":
        print("⚠ real-cloud evidence is stale (listed above): re-measure before claiming it.")
    return 1 if stale and warn != "1" else 0


try:
    sys.exit(check())
except NotVerifiable as e:
    print(f"✗ not verifiable: {e}", file=sys.stderr)
    sys.exit(2)
PY
