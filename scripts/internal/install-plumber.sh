#!/usr/bin/env bash
# Install plumber, pinned and checksum-verified — the CI policy scanner
# (`.github/workflows/security.yml`, "Pipeline audit") that gates unpinned
# actions, dangerous triggers and over-broad permissions in every workflow
# file. Before this, the only way to see its verdict before pushing was to
# fetch the binary by hand. See #52.
#
# Same shape as install-gitleaks.sh: a pinned version, the project's own
# checksums file, no third party in the path. Plain binaries per platform —
# plumber ships no tarball.
#
# Not verified here: the build-provenance (sigstore/SLSA) attestation the
# GitHub Action also checks — that needs the `gh` CLI, which a plain
# workstation install cannot assume. The sha256 checksum still guards
# transit integrity against this exact release.
#
# Usage: install-plumber.sh [bin-dir]        (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

# renovate: datasource=github-releases depName=getplumber/plumber extractVersion=^v(?<version>.*)$
PLUMBER_VERSION="0.5.12"

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BIN_DIR="${1:-$(oa_bin_dir)}"
SUDO="$(oa_sudo_for "$BIN_DIR")"

if command -v plumber >/dev/null 2>&1 &&
  plumber version 2>/dev/null | grep -qE "(^|[^0-9.])${PLUMBER_VERSION//./\\.}([^0-9.]|\$)"; then
  echo "plumber v${PLUMBER_VERSION} already installed"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="plumber-linux-amd64" ;;
  Linux-aarch64 | Linux-arm64) asset="plumber-linux-arm64" ;;
  Darwin-x86_64) asset="plumber-darwin-amd64" ;;
  Darwin-arm64) asset="plumber-darwin-arm64" ;;
  *) echo "✗ no published plumber binary for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

base="https://github.com/getplumber/plumber/releases/download/v${PLUMBER_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"
# --ignore-missing: the file lists every platform, and without it the check fails
# on the ones we did not download — which reads like a bad binary.
(cd "$tmp" && sha256sum -c checksums.txt --ignore-missing)

mkdir -p "$BIN_DIR" 2>/dev/null || $SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$tmp/$asset" "$BIN_DIR/plumber"
echo "installed plumber v${PLUMBER_VERSION} → $BIN_DIR/plumber"
