#!/usr/bin/env bash
# check-alert-metrics.py does not call a metric blind when "no series" is its healthy state (infra #357).
# A shell entry point so that the harnesses that stub every script of test-scripts see it; the test is the Python file.
set -euo pipefail
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/test-check-alert-metrics.py"
