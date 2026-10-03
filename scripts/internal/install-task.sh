#!/usr/bin/env bash
# Install go-task, pinned and checksum-verified.
#
# There were two ways Task got installed and neither was good. CI used
# `arduino/setup-task`, a third-party action that queries the releases API
# UNAUTHENTICATED from a shared runner IP — that is what took `main` red on
# 2026-08-13 with nothing wrong in the code. `setup.sh` used
# `sh -c "$(curl https://taskfile.dev/install.sh)"`, unpinned and unverified, in a
# repository that checksums helm, gitleaks, feint and tflint.
#
# One way now, the same shape as every other tool here: a pinned version, the
# project's own checksums file, and no third party in the path.
#
# Usage: install-task.sh [bin-dir]        (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

# renovate: datasource=github-releases depName=go-task/task extractVersion=^v(?<version>.*)$
TASK_VERSION="3.54.0"

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BIN_DIR="${1:-$(oa_bin_dir)}"
SUDO="$(oa_sudo_for "$BIN_DIR")"

# `task --version` prints a bare "3.52.0" today and "Task version: v3.x.y" on
# older releases, so match either, and bound it so 3.52.0 does not match 3.52.01.
if command -v task >/dev/null 2>&1 &&
  task --version 2>/dev/null | grep -qE "(^|[^0-9.])v?${TASK_VERSION//./\\.}([^0-9.]|\$)"; then
  echo "task v${TASK_VERSION} already installed"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="task_linux_amd64.tar.gz" ;;
  Linux-aarch64 | Linux-arm64) asset="task_linux_arm64.tar.gz" ;;
  Darwin-x86_64) asset="task_darwin_amd64.tar.gz" ;;
  Darwin-arm64) asset="task_darwin_arm64.tar.gz" ;;
  *) echo "✗ no published task binary for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

base="https://github.com/go-task/task/releases/download/v${TASK_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/task_checksums.txt" "$base/task_checksums.txt"
# --ignore-missing: the file lists every platform, and without it the check fails
# on the ones we did not download — which reads like a bad binary.
(cd "$tmp" && sha256sum -c task_checksums.txt --ignore-missing)

tar xzf "$tmp/$asset" -C "$tmp" task
mkdir -p "$BIN_DIR" 2>/dev/null || $SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$tmp/task" "$BIN_DIR/task"
echo "installed task v${TASK_VERSION} → $BIN_DIR/task"
