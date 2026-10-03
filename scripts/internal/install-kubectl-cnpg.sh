#!/usr/bin/env bash
# Install the CloudNativePG kubectl plugin, pinned and checksum-verified.
#
# The roll no longer needs it: `spec.enablePDB: false` removes the budget that
# made a primary unevictable, so nothing shells out to `promote` any more. It
# stays because `kubectl cnpg status <cluster>` is what you read when a database
# is the thing holding a drain, and because the promote path may come back once
# the skew below is understood.
#
# ⚠️ The pinned plugin does NOT match what is deployed: 1.23.6 against a 1.23.1
# operator on 2026-08-15, where `promote` exited 0, printed "will be promoted"
# and left `status.targetPrimary` untouched. Same minor, so the mismatch is not
# obviously the cause — open as a GitHub issue. Keep the minor aligned with the
# operator in OpenAether-apps (apps/base/cnpg/) when that moves.
#
# Usage: install-kubectl-cnpg.sh [bin-dir]   (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

# renovate: datasource=github-releases depName=cloudnative-pg/cloudnative-pg extractVersion=^v(?<version>.*)$
CNPG_VERSION="1.30.1"

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BIN_DIR="${1:-$(oa_bin_dir)}"
SUDO="$(oa_sudo_for "$BIN_DIR")"

if command -v kubectl-cnpg >/dev/null 2>&1 &&
  kubectl-cnpg version 2>/dev/null | grep -qF "${CNPG_VERSION}"; then
  echo "kubectl-cnpg ${CNPG_VERSION} already installed"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="kubectl-cnpg_${CNPG_VERSION}_linux_x86_64.tar.gz" ;;
  Linux-aarch64 | Linux-arm64) asset="kubectl-cnpg_${CNPG_VERSION}_linux_arm64.tar.gz" ;;
  Darwin-x86_64) asset="kubectl-cnpg_${CNPG_VERSION}_darwin_x86_64.tar.gz" ;;
  Darwin-arm64) asset="kubectl-cnpg_${CNPG_VERSION}_darwin_arm64.tar.gz" ;;
  *) echo "✗ no published kubectl-cnpg for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

base="https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base/cnpg-${CNPG_VERSION}-checksums.txt"
# Grep the one line rather than --ignore-missing: a hard failure if OUR asset is
# not in the checksums file is the point.
(cd "$tmp" && grep " ${asset}\$" checksums.txt | sha256sum -c -)

tar xzf "$tmp/$asset" -C "$tmp" kubectl-cnpg
mkdir -p "$BIN_DIR" 2>/dev/null || $SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$tmp/kubectl-cnpg" "$BIN_DIR/kubectl-cnpg"
echo "installed kubectl-cnpg ${CNPG_VERSION} → $BIN_DIR/kubectl-cnpg"
