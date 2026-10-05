#!/usr/bin/env bash
# One tool, one version, everywhere it is claimed.
#
# Four instances of the same defect landed in one week, and every one was
# mechanically checkable:
#   - README said Cilium 1.19.2 against a committed chart 1.20.0;
#   - README said Flux v2.4.0 against a renderer pinning v2.9.3;
#   - setup.sh installed helm 3.21.3 while the renderer refuses any major but 4
#     and CI pins 4.2.3 — so a fresh clone could not run the local rung at all;
#   - docs/emulated-cloud.md said "Pinned to Feint 0.7.3" against feint.sh 0.8.0.
# This checks the CLASS, not those four.
#
# WHAT IT DELIBERATELY DOES NOT DO: flag every version number in prose. The
# emulated-cloud docs legitimately record measurements taken on 0.6.0, 0.7.0 and
# 0.7.3 — history, not drift. Failing those would make this noise, and a checker
# that cries wolf gets muted, which is the defect it exists to prevent. Only
# lines that DECLARE the current pin are compared, and the marker is the phrase
# "Pinned to" and its three French forms (see the git grep below). All three are
# needed: the French twin of the very line that motivated this file uses the one
# a narrower marker missed, so the check verified the English half and skipped
# the other in silence.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

pin() { # <file> <VAR_NAME> — the value of a shell assignment, defaults stripped
  sed -nE "s/^[[:space:]]*(local[[:space:]]+)?${2}=\"?\\\$\{${2}:-([^}\"]+)\}?\"?.*/\2/p;
           s/^[[:space:]]*(local[[:space:]]+)?${2}=\"([^\"]+)\".*/\2/p" "$1" | head -1
}

RENDER=scripts/bootstrap/render-bootstrap-manifests.sh
CILIUM="$(pin "$RENDER" CILIUM_VERSION)"
HELM_MAJOR="$(pin "$RENDER" HELM_MAJOR_EXPECTED)"
FEINT="$(pin scripts/dev/feint.sh FEINT_VERSION)"
HELM_SETUP="$(pin scripts/setup.sh HELM_VERSION)"
HELM_CI="$(sed -nE 's/^[[:space:]]*HELM_VERSION:[[:space:]]*"([^"]+)".*/\1/p' .github/workflows/ci.yml | head -1)"
TOFU_SETUP="$(pin scripts/setup.sh TOFU_VERSION)"
YAMLLINT_SETUP="$(pin scripts/setup.sh YAMLLINT_VERSION)"
YAMLLINT_CI="$(sed -nE 's/.*pip install yamllint==([^[:space:]"]+).*/\1/p' .github/workflows/ci.yml | head -1)"
TOFU_CI="$(sed -nE 's/^[[:space:]]*tofu_version:[[:space:]]*"([^"]+)".*/\1/p' .github/workflows/ci.yml | head -1)"
# Talos has no second pin to compare: ci.yml installs it through
# scripts/internal/install-talosctl.sh, which reads the cluster's own. So the
# question is whether that is still true — TALOS_CI is EXPECTED to be empty, and
# is not part of the zero floor below for that reason.
TALOS_CLUSTER="$(scripts/internal/talos-version.sh 2>/dev/null || true)"
TALOS_CI="$(sed -nE 's/^[[:space:]]*TALOS_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' .github/workflows/ci.yml | head -1)"
GITLEAKS_INSTALL="$(pin scripts/internal/install-gitleaks.sh GITLEAKS_VERSION)"
# The rev: line right after the gitleaks repo: line, not "the Nth rev: in the
# file" — order-independent, so adding or reordering another repo: block
# cannot silently start comparing the wrong pin.
GITLEAKS_PRECOMMIT="$(awk '/repo:.*gitleaks\/gitleaks/{f=1; next} f && /rev:/{print; exit}' \
  .pre-commit-config.yaml | sed -nE 's/.*#[[:space:]]*v([0-9][^[:space:]]*).*/\1/p')"
PLUMBER_INSTALL="$(pin scripts/internal/install-plumber.sh PLUMBER_VERSION)"
PLUMBER_CI="$(sed -nE 's/.*getplumber\/plumber@[0-9a-f]+[[:space:]]*#[[:space:]]*v([0-9][^[:space:]]*).*/\1/p' \
  .github/workflows/security.yml | head -1)"

# ZERO FLOOR. If the extractors return nothing the comparisons below all pass
# vacuously, and this file becomes a green line that proves nothing — the exact
# shape it is written against.
for v in CILIUM HELM_MAJOR FEINT HELM_SETUP HELM_CI TOFU_SETUP TOFU_CI YAMLLINT_SETUP YAMLLINT_CI TALOS_CLUSTER GITLEAKS_INSTALL GITLEAKS_PRECOMMIT PLUMBER_INSTALL PLUMBER_CI; do
  [ -n "${!v}" ] || { echo "✗ could not extract ${v} — the extractor is broken, not the repository" >&2; exit 1; }
done

echo "=== the pins agree with each other ==="

# helm: three files, one major, and the renderer exits 1 on a mismatch.
if [ "$HELM_SETUP" = "$HELM_CI" ]; then
  ok "helm ${HELM_SETUP}: setup.sh and ci.yml agree"
else
  bad "helm: setup.sh installs ${HELM_SETUP}, ci.yml pins ${HELM_CI} — the artifacts they render can differ"
fi
if [ "${HELM_SETUP%%.*}" = "$HELM_MAJOR" ]; then
  ok "helm major ${HELM_MAJOR}: what setup.sh installs is what the renderer accepts"
else
  bad "helm: setup.sh installs major ${HELM_SETUP%%.*}, ${RENDER} refuses anything but ${HELM_MAJOR} — a fresh clone cannot render"
fi

# OpenTofu: unpinned in setup.sh until 2026-08-23, where the official installer
# asked the GitHub API for the newest version and a 403 took the whole bootstrap
# down before anything was installed.
if [ "$TOFU_SETUP" = "$TOFU_CI" ]; then
  ok "OpenTofu ${TOFU_SETUP}: setup.sh and ci.yml agree"
else
  bad "OpenTofu: setup.sh installs ${TOFU_SETUP}, ci.yml pins ${TOFU_CI} — a contributor and CI would not run the same binary"
fi

# yamllint: setup.sh pins it for a contributor's machine, ci.yml for the lint job.
if [ "$YAMLLINT_SETUP" = "$YAMLLINT_CI" ]; then
  ok "yamllint ${YAMLLINT_SETUP}: setup.sh and ci.yml agree"
else
  bad "yamllint: setup.sh installs ${YAMLLINT_SETUP}, ci.yml pins ${YAMLLINT_CI} — a contributor and CI would not lint with the same rules"
fi

# Talos: the drift here was invisible for a different reason than the others —
# there was no rule comparing the pair at all, so ci.yml validated configs with
# v1.13.7 while both roots pinned v1.13.9. The fix is structural rather than a
# comparison: ci.yml installs through install-talosctl.sh, which reads the
# cluster's pin, so the two cannot disagree. What is checked is that the
# structure holds — a hardcoded version coming back is the regression.
if ! grep -q 'install-talosctl\.sh' .github/workflows/ci.yml; then
  bad "ci.yml no longer installs talosctl through scripts/internal/install-talosctl.sh — it can pin a version of its own again"
elif [ -z "$TALOS_CI" ]; then
  ok "Talos ${TALOS_CLUSTER}: ci.yml declares no version of its own, it installs the cluster's"
elif [ "${TALOS_CI#v}" = "${TALOS_CLUSTER#v}" ]; then
  ok "Talos ${TALOS_CLUSTER}: ci.yml names the same version the cluster pins"
else
  bad "Talos: ci.yml pins ${TALOS_CI}, the cluster pins ${TALOS_CLUSTER} — CI would validate configs against another release"
fi

# Cilium: the pin versus the artifact actually committed from it.
CHART="$(sed -nE 's/.*helm\.sh\/chart:[[:space:]]*cilium-([0-9][^[:space:]]*).*/\1/p' \
  infrastructure/opentofu/cluster/bootstrap-manifests/cilium.yaml | head -1)"
if [ -z "$CHART" ]; then
  bad "no 'helm.sh/chart: cilium-<version>' label in the committed manifest — cannot compare"
elif [ "$CHART" = "$CILIUM" ]; then
  ok "Cilium ${CILIUM}: the pin and the committed manifest agree"
else
  bad "Cilium: ${RENDER} pins ${CILIUM}, the committed manifest is ${CHART}"
fi

# gitleaks: the pre-commit rev versus the pinned binary install-gitleaks.sh
# fetches for the gitleaks-system hook. Diverge and a contributor's local hook
# runs a different gitleaks than the one pre-commit's metadata claims.
if [ "$GITLEAKS_INSTALL" = "$GITLEAKS_PRECOMMIT" ]; then
  ok "gitleaks ${GITLEAKS_INSTALL}: install-gitleaks.sh and .pre-commit-config.yaml agree"
else
  bad "gitleaks: install-gitleaks.sh pins ${GITLEAKS_INSTALL}, .pre-commit-config.yaml pins ${GITLEAKS_PRECOMMIT}"
fi

# plumber: `task pipeline-audit`'s own install versus the CI Action pin. Diverge
# and a local run says something CI never checked.
if [ "$PLUMBER_INSTALL" = "$PLUMBER_CI" ]; then
  ok "plumber ${PLUMBER_INSTALL}: install-plumber.sh and security.yml agree"
else
  bad "plumber: install-plumber.sh pins ${PLUMBER_INSTALL}, security.yml pins ${PLUMBER_CI}"
fi

echo "=== the documentation states the same pins ==="

# <marker> <Tool> <version>, in any tracked markdown. Both languages.
declare -A WANT=([Cilium]="$CILIUM" [Feint]="$FEINT")
found_any=0
while read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
  for tool in "${!WANT[@]}"; do
    grep -qi "$tool" <<<"$text" || continue
    found_any=1
    claimed="$(grep -oiE "${tool}[^0-9]{0,4}v?[0-9]+\.[0-9]+\.[0-9]+" <<<"$text" |
               grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ -n "$claimed" ] || continue
    if [ "${claimed#v}" = "${WANT[$tool]#v}" ]; then
      ok "${file}:${line} — ${tool} ${claimed} matches the pin"
    else
      bad "${file}:${line} — states ${tool} ${claimed}, the code pins ${WANT[$tool]}"
    fi
  done
done < <(git grep -niE 'Pinned to|Épinglé (à|sur|au)' -- '*.md' || true)

# Not fatal: a repository may legitimately declare no pin in prose. But say it,
# because "0 documented pins checked" and "every documented pin is correct" look
# identical in a green run.
[ "$found_any" -eq 1 ] || echo "  ~ no documented pin found for any tracked tool (nothing to compare)"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
