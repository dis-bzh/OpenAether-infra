#!/bin/bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🌐 Checking OpenAether Development Environment...${NC}"

# Root in a container has no sudo and needs none. Bare `sudo` calls exited 127
# there, and set -e took the whole bootstrap with them: on a clean machine this
# died at yamllint and never reached task, flux or helm.
# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif oa_sudo_usable; then
    SUDO="sudo"
else
    SUDO=""
    echo -e "${RED}⚠ Neither root nor a usable sudo: system-wide installs will fail.${NC}"
fi

# The versions this repository pins, at the top so the checks below can compare
# against them. They used to live inside their install functions, where nothing
# could read them — see check_cmd.
#
# TOFU_VERSION MUST stay equal to tofu_version in .github/workflows/ci.yml, and
# HELM_VERSION to HELM_VERSION there and to HELM_MAJOR_EXPECTED in
# scripts/bootstrap/render-bootstrap-manifests.sh, which refuses to render on any
# other major. check-version-drift.sh compares all of them.
#
# renovate: datasource=github-releases depName=opentofu/opentofu extractVersion=^v(?<version>.*)$
TOFU_VERSION="1.13.1"
# renovate: datasource=github-releases depName=fluxcd/flux2 extractVersion=^v(?<version>.*)$
FLUX_VERSION="2.9.6"
# The flux-schema plugin `task lint`'s check-flux-schema.sh needs (#114). Same
# pin as ci.yml's lint job, installed through `flux plugin install`, which
# does its own checksum verification (fluxcd/flux2 RFC 0013).
# renovate: datasource=github-releases depName=fluxcd/flux-schema extractVersion=^v(?<version>.*)$
FLUX_SCHEMA_VERSION="0.15.0"
# renovate: datasource=github-releases depName=helm/helm extractVersion=^v(?<version>.*)$
HELM_VERSION="4.3.0"
# Five more, pinned so Cléa compares a version instead of "whatever is newest today".
# kubectl and aws-cli install from a named URL; the three Python tools via pip.
# YAMLLINT_VERSION MUST equal the pip pin in ci.yml (check-version-drift.sh).
# renovate: datasource=github-releases depName=kubernetes/kubernetes extractVersion=^v(?<version>.*)$
KUBECTL_VERSION="1.37.1"
# renovate: datasource=github-tags depName=aws/aws-cli
AWSCLI_VERSION="2.37.9"
# renovate: datasource=pypi depName=checkov
CHECKOV_VERSION="3.3.22"
# renovate: datasource=pypi depName=yamllint
YAMLLINT_VERSION="1.38.0"
# renovate: datasource=pypi depName=pre-commit
PRECOMMIT_VERSION="4.6.2"

# check_cmd <tool> [pinned-version]
#
# PRESENT IS NOT CURRENT. With no second argument this only asks whether the
# binary exists, and that was the only question it ever asked: setup.sh
# installed the pin on a fresh machine and refused every upgrade afterwards, in
# silence, on every machine that had run it once. Measured 2026-08-23 by the
# Cléa probe — cold install reached helm 4.2.4, upgrading over 4.2.3 left 4.2.3.
# The same shape was found and fixed for feint on 2026-08-21
# (scripts/dev/feint.sh, the comment above its install_feint call).
#
# Every tool this file pins gets the second argument; a tool with no pin must not,
# a comparison against an invented version cannot fail.
check_cmd() {
    local tool="$1" want="${2:-}" version
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${RED}✖ $tool is missing${NC}"
        return 1
    fi
    # First NON-EMPTY answer, and `--version` asked first. Measured on this
    # repository's seven tools: helm, kubectl and talosctl answer only `version`;
    # flux, tflint and task answer only `--version`, and `task version` prints
    # the task LIST. Exit codes do not discriminate — several return 0 with no
    # output — and the previous `$(a || b)` form concatenated both answers when
    # the first failed after printing, which is a version string assembled from
    # two commands.
    version=""
    for flag in --version version; do
        version="$("$tool" "$flag" 2>/dev/null || true)"
        if [ -n "$version" ]; then break; fi
    done
    [ -n "$version" ] || version="detected"
    # Bounded on both sides: 4.2.3 must not match 4.2.30, and the leading v is
    # optional because half of these print it and half do not.
    if [ -n "$want" ] && ! grep -qE "(^|[^0-9.])v?${want//./\\.}([^0-9.]|$)" <<< "$version"; then
        echo -e "${RED}↻ $tool is not the pinned ${want}${NC} (found: $(head -1 <<< "$version"))"
        return 1
    fi
    echo -e "${GREEN}✔ $tool is installed${NC} ($version)"
    return 0
}

install_tofu() {
    # Pinned, and passed to the installer explicitly. Without it the official
    # script asks the GitHub API which version is newest — UNAUTHENTICATED, 60
    # requests an hour from an IP shared with every other customer of the
    # platform. That is what took `main` red on 2026-08-13 through a different
    # tool, and here it is worse: this is the FIRST step, so `set -e` takes the
    # whole bootstrap with it and nothing at all gets installed. Measured
    # 2026-08-23 in a bare ubuntu:24.04, exit 2, by the Cléa probe.
    # MUST stay equal to tofu_version in .github/workflows/ci.yml —
    # check-version-drift.sh compares them.
    #
    # snap and brew used to come first here, and both had to go. Neither can
    # install a NAMED version — `snap install --classic opentofu` serves
    # whatever the channel holds — so on any machine with snap the pin above
    # was decorative. That is how this repository's own workstation ended up on
    # 1.12.6 against a pinned 1.12.5 (measured 2026-08-24). A pin an installer
    # cannot honour is a pin that guarantees drift, and check-version-drift.sh
    # now compares this one. The standalone installer honours it, and installs
    # without root when asked to.
    echo "Installing OpenTofu v${TOFU_VERSION}..."
    # The official installer unzips its download and verifies the signature,
    # refusing to run without unzip, and without either cosign or gpg. A
    # minimal image has none of them: it aborted here, and set -e meant
    # nothing at all got installed — not even the tools further down.
    local need=()
    # curl belongs here too: it is used ten lines down, and a bare ubuntu:24.04
    # has none of these. Listing only two of the three left the same abort this
    # comment describes — exit 127, nothing installed.
    command -v curl &> /dev/null || need+=(curl ca-certificates)
    command -v unzip &> /dev/null || need+=(unzip)
    { command -v gpg &> /dev/null || command -v cosign &> /dev/null; } || need+=(gnupg)
    if [ ${#need[@]} -gt 0 ]; then
        if command -v apt-get &> /dev/null; then
            $SUDO apt-get update && $SUDO apt-get install -y "${need[@]}"
        else
            echo "⚠️  OpenTofu's installer needs: ${need[*]}"
            echo "    Install them, then re-run ./scripts/setup.sh"
            return 1
        fi
    fi
    # Downloads to $TMPDIR, not to the CWD: the `rm` this replaced sat
    # AFTER the installer, so under `set -e` a failed install left a 50 KB
    # third-party script in the root of a public repository.
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN
    curl -fsSL https://get.opentofu.org/install-opentofu.sh -o "$tmp"
    # Where the binary goes follows the same rule as every other tool here:
    # the system path when it is reachable, the per-user one otherwise. The
    # default (/opt/opentofu + /usr/local/bin) needs root, and asking for it
    # on a machine that cannot give it is what aborted this step.
    local bin data
    bin="$(oa_bin_dir)"
    if [ "$bin" = /usr/local/bin ]; then
        data=/opt/opentofu
    else
        data="${HOME}/.local/share/openaether/opentofu"
    fi
    $(oa_sudo_for "$bin") sh "$tmp" --install-method standalone \
        --opentofu-version "${TOFU_VERSION}" \
        --install-path "$data" --symlink-path "$bin"
    [ "$bin" = /usr/local/bin ] || echo "NOTE: tofu installed to $bin. Ensure it's in your PATH."
}

install_kubectl() {
    echo "Installing kubectl v${KUBECTL_VERSION}..."
    local tmp dir sudo_cmd base="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64"
    tmp="$(mktemp -d)"
    curl -fsSLo "$tmp/kubectl" "$base/kubectl"
    echo "$(curl -fsSL "$base/kubectl.sha256")  $tmp/kubectl" | sha256sum -c - >/dev/null
    chmod +x "$tmp/kubectl"
    dir="$(oa_bin_dir)"; sudo_cmd="$(oa_sudo_for "$dir")"
    mkdir -p "$dir"
    $sudo_cmd mv "$tmp/kubectl" "$dir/kubectl"
    rm -rf "$tmp"
    [ "$dir" = /usr/local/bin ] || echo "NOTE: kubectl installed to $dir. Ensure it's in your PATH."
}

install_shellcheck() {
    # `task lint` gates on it, so a contributor who ran this script and cannot
    # run `task lint` is the defect this repository has already met twice — with
    # checkov, which lived only in CI, and with helm, pinned here one major below
    # what the renderer accepts. Pinned + checksum-verified installer, same as
    # ci.yml (#113) — apt's own shellcheck package carried no version pin either.
    "$(dirname "${BASH_SOURCE[0]}")/internal/install-shellcheck.sh"
}

# pip_install_pinned <package> <version> [binary]
# apt and brew cannot name a version, so these tools come from PyPI: pipx, then
# `pip --user`, then a private venv (Ubuntu 24.04 ships python3 with neither
# pip nor pipx; `--user` is refused there as externally managed). Each step
# falls through on failure, and none needs sudo except the last apt-for-pipx.
pip_install_pinned() {
    local pkg="$1" ver="$2" bin="${3:-$1}" venv="$HOME/.local/share/openaether/$1-venv"
    echo "Installing $pkg==$ver..."
    if command -v pipx &> /dev/null && pipx install --force "$pkg==$ver"; then :
    elif python3 -m pip --version &> /dev/null && python3 -m pip install --user "$pkg==$ver"; then :
    elif mkdir -p "$(dirname "$venv")" && python3 -m venv "$venv" &> /dev/null \
         && "$venv/bin/pip" install --quiet "$pkg==$ver"; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$venv/bin/$bin" "$HOME/.local/bin/$bin"
    elif command -v apt-get &> /dev/null \
         && $SUDO apt-get update && $SUDO apt-get install -y pipx && pipx install --force "$pkg==$ver"; then :
    else
        echo "⚠️  Could not install $pkg==$ver automatically. Install it manually: pipx install $pkg==$ver"
        return 1
    fi
    # Installed is not reachable: ~/.local/bin is not on a fresh Ubuntu's PATH.
    if ! command -v "$bin" &> /dev/null && [ -x "$HOME/.local/bin/$bin" ]; then
        command -v pipx &> /dev/null && pipx ensurepath >/dev/null 2>&1 || true
        export PATH="$HOME/.local/bin:$PATH"
        echo "⚠️  $bin is in ~/.local/bin, which was not on your PATH; added for this script."
        echo "   Open a new shell, or: export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

install_task() {
    # One installer, shared with CI, pinned and checksum-verified. This used to
    # pipe an unpinned https://taskfile.dev/install.sh into sh — the only tool
    # here that was neither pinned nor verified.
    "$(dirname "${BASH_SOURCE[0]}")/internal/install-task.sh"
}

install_awscli_bundle() {
    echo "Installing AWS CLI v${AWSCLI_VERSION} from the official bundle..."
    command -v unzip &> /dev/null || $SUDO apt-get install -y unzip
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m)-${AWSCLI_VERSION}.zip" -o "$tmp/aws.zip"
    (cd "$tmp" && unzip -q aws.zip && $SUDO ./aws/install --update)
    rm -rf "$tmp"
}

install_image_tools() {
    echo "Installing Talos image + backup tools (zstd, qemu-img, gpg, jq, aws)..."

    # zstd + qemu-img (image build), gpg (client-side backup encryption) and jq
    # (backup-state.sh) — installed separately so a missing aws package never
    # blocks them (Ubuntu 24.04 dropped awscli from apt).
    if command -v apt-get &> /dev/null; then
        $SUDO apt-get update && $SUDO apt-get install -y zstd qemu-utils gnupg jq
    elif command -v brew &> /dev/null; then
        brew install zstd qemu gnupg jq
    elif command -v dnf &> /dev/null; then
        $SUDO dnf install -y zstd qemu-img gnupg2 jq
    else
        echo "⚠️  Could not auto-install zstd/qemu-img/gpg/jq. Install them manually."
    fi

    # AWS CLI — the official v2 bundle only: brew and snap cannot name a version.
    # Used to upload the image to Object Storage.
    check_cmd aws "$AWSCLI_VERSION" || install_awscli_bundle
}

install_flux() {
    local ARCH="linux_amd64"
    echo "Installing Flux CLI v${FLUX_VERSION}..."
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_${ARCH}.tar.gz" -o "$tmp/flux.tar.gz"
    tar -xzf "$tmp/flux.tar.gz" -C "$tmp"
    local dir sudo_cmd
    dir="$(oa_bin_dir)"; sudo_cmd="$(oa_sudo_for "$dir")"
    mkdir -p "$dir"
    $sudo_cmd install -m 755 "$tmp/flux" "$dir/flux"
    [ "$dir" = /usr/local/bin ] || echo "NOTE: flux installed to $dir. Ensure it's in your PATH."
    rm -rf "$tmp"
}

install_helm() {
    # MUST stay on the same MAJOR as .github/workflows/ci.yml and as
    # HELM_MAJOR_EXPECTED in scripts/bootstrap/render-bootstrap-manifests.sh, which
    # refuses to render on any other and exits 1. This pinned 3.x while both of
    # those required 4, so a fresh clone got a toolchain that could not run
    # `task local-up` — the credential-free rung the README calls the best first
    # step. The mismatch was invisible to anyone who already had helm 4.
    local ARCH="linux-amd64"
    echo "Installing Helm v${HELM_VERSION}..."
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-${ARCH}.tar.gz" -o "$tmp/helm.tar.gz"
    tar -xzf "$tmp/helm.tar.gz" -C "$tmp"
    local dir sudo_cmd
    dir="$(oa_bin_dir)"; sudo_cmd="$(oa_sudo_for "$dir")"
    mkdir -p "$dir"
    $sudo_cmd install -m 755 "$tmp/${ARCH}/helm" "$dir/helm"
    [ "$dir" = /usr/local/bin ] || echo "NOTE: helm installed to $dir. Ensure it's in your PATH."
    rm -rf "$tmp"
}

install_precommit() {
    pip_install_pinned pre-commit "$PRECOMMIT_VERSION"
}

# PyYAML for the system python3. check-cilium-effective-config.py, check-cilium-parity.py
# and check-alert-metrics.py import it and `task preflight` runs them: a CI runner image
# ships it, a clean machine does not. apt/brew and not pipx, whose venv those scripts'
# python3 cannot import.
ensure_pyyaml() {
    python3 -c 'import yaml' 2>/dev/null && return 0
    if command -v apt-get &> /dev/null; then
        echo "Installing PyYAML..."
        $SUDO apt-get update && $SUDO apt-get install -y python3-yaml
    elif command -v brew &> /dev/null; then
        brew install pyyaml
    else
        echo -e "${RED}⚠ PyYAML is missing — 'task preflight' imports it (check-cilium-*.py).${NC}"
        echo "   Install python3-yaml (the PyYAML package of your distribution), then re-run ./scripts/setup.sh"
    fi
}

# 1. Check OpenTofu
if ! check_cmd tofu "$TOFU_VERSION"; then
    install_tofu
fi

# 2. talosctl — pinned to the version the CLUSTERS run, like every other tool
# here. Not behind check_cmd: that probes with `talosctl version`, which prints
# the SERVER's tag too, so a stale client against a current cluster would
# satisfy the pin. The installer asks with `--client`, and is a no-op when it
# already holds.
"$(dirname "${BASH_SOURCE[0]}")/internal/install-talosctl.sh"

# 3. Check kubectl
if ! check_cmd kubectl "$KUBECTL_VERSION"; then
    install_kubectl
fi

# 4. Check yamllint
if ! check_cmd yamllint "$YAMLLINT_VERSION"; then
    pip_install_pinned yamllint "$YAMLLINT_VERSION"
fi

# 4b. Check shellcheck — `task lint` gates on it
if ! check_cmd shellcheck; then
    install_shellcheck
fi

# 5. Check Task
if ! check_cmd task; then
    install_task
fi

# 5b. Check tflint — `task lint` calls it, and this script did not install it, so
# the first command a contributor runs failed on a machine we had just called
# ready. Found 2026-08-14 in a bare ubuntu:24.04.
if ! check_cmd tflint; then
    "$(dirname "${BASH_SOURCE[0]}")/internal/install-tflint.sh"
fi

# 5b-bis. kubectl-cnpg — docs/upgrade.md tells the operator to switch a CNPG
# primary over before its node can be drained, and named a plugin nothing
# installed. A documented step that needs a tool nobody has is not a step.
if ! check_cmd kubectl-cnpg; then
    "$(dirname "${BASH_SOURCE[0]}")/internal/install-kubectl-cnpg.sh"
fi

# 5b-ter. actionlint — `task lint` calls it. A workflow file is the one thing in
# this repository that cannot be run before it is merged.
if ! check_cmd actionlint; then
    "$(dirname "${BASH_SOURCE[0]}")/internal/install-actionlint.sh"
fi

# 5c. Check checkov (`task security` runs it directly; only CI ever had it)
if ! check_cmd checkov "$CHECKOV_VERSION"; then
    pip_install_pinned checkov "$CHECKOV_VERSION"
fi

# 5d. gitleaks — `task security` runs it directly, and pre-commit's own
# `language: golang` hook builds it from source on first use. In this
# project's sandbox that build panics inside wasilibs/go-re2's WASM engine
# (see #126); the pinned release binary does not carry the same defect. The
# `.pre-commit-config.yaml` gitleaks hook is `language: system` for exactly
# this reason — it shells out to whatever this installs.
if ! check_cmd gitleaks; then
    "$(dirname "${BASH_SOURCE[0]}")/internal/install-gitleaks.sh"
fi

# 5e. plumber — `task pipeline-audit` runs it directly; before this it was the
# CI policy scanner nobody could see the verdict of without fetching the
# binary by hand (#52).
if ! check_cmd plumber; then
    "$(dirname "${BASH_SOURCE[0]}")/internal/install-plumber.sh"
fi

# 6. Check Talos image + backup tools (used by `task image-build` and the S3 backups)
MISSING_IMG_TOOLS=0
for t in curl zstd qemu-img aws gpg jq; do
    want=""
    if [ "$t" = aws ]; then want="$AWSCLI_VERSION"; fi
    check_cmd "$t" "$want" || MISSING_IMG_TOOLS=1
done
if [ "$MISSING_IMG_TOOLS" -eq 1 ]; then
    install_image_tools
fi

# 7. Check Flux CLI
if ! check_cmd flux "$FLUX_VERSION"; then
    install_flux
fi

# 7b. flux-schema plugin — `task lint`'s check-flux-schema.sh needs it (#114),
# so local `task lint` must match what ci.yml's lint job installs. `flux plugin
# install` is idempotent and checksum-verifies itself; no separate check_cmd
# guard needed.
if ! flux schema version 2> /dev/null | grep -qF "$FLUX_SCHEMA_VERSION"; then
    flux plugin install "schema@${FLUX_SCHEMA_VERSION}"
fi

# 8. Check Helm — render-bootstrap-manifests.sh runs `helm template`, so every
# path that renders Cilium or Flux needs it, including `task local-up`.
if ! check_cmd helm "$HELM_VERSION"; then
    install_helm
fi

# 9. Check nc — the local Docker provider and talos-tunnels.sh poll ports with it.
if ! check_cmd nc; then
    # Installed, not just reported: `task local-up` and the tunnels need it, and
    # this script installs everything else they need.
    if command -v apt-get &> /dev/null; then
        echo "Installing netcat..."
        $SUDO apt-get update && $SUDO apt-get install -y netcat-openbsd
    else
        echo -e "${RED}⚠ nc (netcat) is missing — 'task local-up' and the SSH tunnels poll ports with it.${NC}"
        echo "   Install netcat-openbsd (or equivalent), then re-run ./scripts/setup.sh"
    fi
fi

# 9b. Check PyYAML — `task preflight` runs scripts that import it.
ensure_pyyaml

# 10. Check pre-commit (optional but recommended)
if ! check_cmd pre-commit "$PRECOMMIT_VERSION"; then
    echo -e "${RED}⚠ pre-commit is not installed (recommended for DevSecOps)${NC}"
    # `read` on a closed stdin returns 1, and `set -e` turned that into an abort
    # one line before "Environment ready" — so this script could not finish
    # anywhere it runs unattended: a container, CI, a fresh machine over ssh.
    if [ -t 0 ]; then
        read -p "Install pre-commit? (y/N) " -n 1 -r
        echo
    else
        REPLY=y
        echo "   no terminal — installing it rather than stopping here."
    fi
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        install_precommit
        echo "Run 'pre-commit install' in the repo root to activate hooks."
    fi
fi

echo -e "\n${GREEN}🚀 Environment ready!${NC}"
echo ""
echo "Next steps (one env file == one cluster):"
echo "  1. cp .env.example .env.sh, fill in your provider's keys, then: source .env.sh"
echo "     (Scaleway: SCW_ACCESS_KEY / SCW_SECRET_KEY / SCW_DEFAULT_PROJECT_ID)"
# The S3 credentials are DERIVED from the provider's own keys by
# scripts/internal/resolve-s3-cred.sh, and the Taskfile sets AWS_* from it. This
# used to tell people to export AWS_ACCESS_KEY_ID themselves; the Taskfile then
# overwrote it, so the instruction was inert and misleading in the first screen a
# newcomer reads.
echo "     S3 credentials are derived from those — do NOT export AWS_* yourself."
echo "     Cross-provider backup only: BACKUP_AWS_ACCESS_KEY_ID / BACKUP_AWS_SECRET_ACCESS_KEY"
echo "  2. export TF_VAR_encryption_passphrase=<32+ chars>   # encrypts tfstate AND the backups"
echo "  3. cp infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example \\"
echo "        infrastructure/opentofu/cluster/envs/management-scaleway.tfvars   # then edit it"
echo "     Six fields have no default: environment, admin_ip, s3_primary_endpoint,"
echo "     s3_primary_region, s3_replica_endpoint, s3_replica_region. See README.md."
echo "  4. task cluster-up ROLE=management PROVIDER=scaleway KEY=~/.ssh/yourkey"
echo "     One idempotent command: image, manifests, infra, tunnels, Talos bootstrap."
echo "     KEY must be the private half of a key listed in bastion_ssh_keys."
