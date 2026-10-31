#!/usr/bin/env bash
# Install tflint, pinned and checksum-verified.
#
# `task lint` calls it and `scripts/setup.sh` did not install it, so the first
# command a new contributor runs failed on a machine this repository's own setup
# had just declared ready. Measured 2026-08-14 in a bare ubuntu:24.04.
#
# Three copies of this download existed before: a SHA-pinned CI action, a block
# in the session-start hook, and nothing at all in setup.sh. One now.
#
# Usage: install-tflint.sh [bin-dir]      (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

# renovate: datasource=github-releases depName=terraform-linters/tflint
TFLINT_VERSION="v0.65.0"

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BIN_DIR="${1:-$(oa_bin_dir)}"
SUDO="$(oa_sudo_for "$BIN_DIR")"

if command -v tflint >/dev/null 2>&1 && tflint --version 2>/dev/null | grep -qF "${TFLINT_VERSION#v}"; then
  echo "tflint ${TFLINT_VERSION} already installed"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="tflint_linux_amd64.zip" ;;
  Linux-aarch64 | Linux-arm64) asset="tflint_linux_arm64.zip" ;;
  Darwin-x86_64) asset="tflint_darwin_amd64.zip" ;;
  Darwin-arm64) asset="tflint_darwin_arm64.zip" ;;
  *) echo "✗ no published tflint binary for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

# tflint ships a zip, and a bare ubuntu:24.04 has no unzip — setup.sh only pulls
# it in later, for the AWS bundle, so this ran first and died on a missing tool.
if ! command -v unzip >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq unzip
  else
    echo "✗ unzip is required to install tflint, and I cannot install it here" >&2
    exit 1
  fi
fi

base="https://github.com/terraform-linters/tflint/releases/download/${TFLINT_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"
# Grep the one line rather than --ignore-missing: tflint's checksums file lists
# every asset, and we want a hard failure if OUR asset is not in it.
(cd "$tmp" && grep " ${asset}\$" checksums.txt | sha256sum -c -)

unzip -q -o "$tmp/$asset" -d "$tmp"
mkdir -p "$BIN_DIR" 2>/dev/null || $SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$tmp/tflint" "$BIN_DIR/tflint"
echo "installed tflint ${TFLINT_VERSION} → $BIN_DIR/tflint"
