#!/usr/bin/env bash
# setup.sh asks whether a tool is CURRENT, not merely present.
#
# The bare presence check installed the pin on a fresh machine and refused every
# upgrade afterwards, in silence, on every machine that had run the script once.
# Measured 2026-08-23 by the Cléa probe: a cold install reached helm 4.2.4 while
# upgrading over 4.2.3 left 4.2.3. The same shape had been found and fixed for
# feint two days earlier (install_feint in scripts/dev/feint.sh), which is why
# it gets a harness rather than a comment.
#
# The function is extracted and driven against stub binaries: setup.sh runs its
# whole bootstrap when sourced, so there is nothing to import.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

sed -n '/^check_cmd() {/,/^}/p' "$ROOT/scripts/setup.sh" > "$TMP/fn.sh"
# ZERO FLOOR: an extractor that returns nothing makes every assertion below pass
# vacuously, which is the exact shape this file exists against.
grep -q 'command -v' "$TMP/fn.sh" || {
  echo "✗ could not extract check_cmd from setup.sh — the extractor is broken, not the script" >&2
  exit 1
}

stub() { # <name> <what both probes print>
  stub2 "$1" "$2" "$2"
}

stub2() { # <name> <what --version prints> <what version prints> [rc-of--version]
  cat > "$TMP/bin/$1" <<EOF
#!/bin/sh
case "\$1" in
  --version) [ -n "$2" ] && printf '%s\n' "$2"; exit ${4:-0} ;;
  version)   [ -n "$3" ] && printf '%s\n' "$3"; exit 0 ;;
esac
EOF
  chmod +x "$TMP/bin/$1"
}
mkdir -p "$TMP/bin"

run() { # <expected-rc> <label> <tool> [pin]
  local want="$1" label="$2"; shift 2
  local out rc
  out="$(PATH="$TMP/bin:$PATH" bash -c '
    RED=""; GREEN=""; NC=""
    . "$1"
    check_cmd "${2}" "${3:-}"' _ "$TMP/fn.sh" "$@" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$label"; else
    bad "$label (exit $rc, wanted $want) — $out"
  fi
  printf '%s' "$out" > "$TMP/last"
}

echo "=== present is not current ==="
stub helm "v4.2.3"
run 0 "no pin given: presence is still the only question" helm
run 0 "the pinned version installed" helm 4.2.3
run 1 "a different version is refused, not accepted as present" helm 4.2.4
grep -q '↻' "$TMP/last" && ok "and it says the version is not the pinned one" \
  || bad "the refusal does not name what it found"

echo
echo "=== which probe answers differs per tool, and emptiness is the signal ==="
# Measured on this repository's own seven: helm, kubectl and talosctl answer
# only `version`; flux, tflint and task answer only `--version`, and
# `task version` prints the task LIST. Exit codes do not discriminate — several
# return 0 with nothing at all.
stub2 onlyversion "" "v1.2.3"
run 0 "a tool that answers only on version" onlyversion 1.2.3
stub2 onlydash "v1.2.3" ""
run 0 "a tool that answers only on --version" onlydash 1.2.3
stub2 mute "" ""
run 1 "a tool that answers neither cannot satisfy a pin" mute 1.2.3
run 0 "and with no pin it is still just present" mute

# The one that matters: `$(a || b)` concatenated both answers when the first
# printed and then failed, so a version string was assembled out of two
# commands and TWO different pins would both match it.
stub2 noisy "9.9.9" "1.2.3" 1
run 0 "the first non-empty answer is the answer" noisy 9.9.9
run 1 "and the second is not appended to it" noisy 1.2.3

echo
echo "=== the comparison is bounded on both sides ==="
stub helm "v4.2.30"
run 1 "4.2.30 does not satisfy a 4.2.3 pin" helm 4.2.3
stub helm "v14.2.3"
run 1 "14.2.3 does not satisfy a 4.2.3 pin" helm 4.2.3

echo
echo "=== the leading v is optional on either side ==="
stub tofu "OpenTofu v1.12.5"
run 0 "a tool that prints v against a pin that does not" tofu 1.12.5
stub flux "flux version 2.9.3"
run 0 "a tool that prints neither" flux 2.9.3

echo
echo "=== a missing tool is missing, whatever the pin says ==="
# A name nothing on this machine provides, rather than deleting the stub: the
# host has a real helm, so removing the stub falls through to it and the
# assertion passes for the wrong reason. A machine that works hides the defect.
run 1 "absent with a pin" clea-absent-by-construction 4.2.3
run 1 "absent without one" clea-absent-by-construction

echo
echo "=== sudo that exists is not sudo that can be used ==="
# Eight places asked `command -v sudo`. On a workstation where /usr/local/bin is
# not writable and sudo wants a password, that answers yes and the installer
# then dies on a prompt nobody can answer — under `set -e`, taking the whole
# bootstrap with it. Measured 2026-08-24 on exactly such a machine.
LIB="$ROOT/scripts/lib/common.sh"
sudostub() { # <rc of `sudo -n true`>
  printf '#!/bin/sh\n[ "$1" = -n ] && exit %s\nexec "$@"\n' "$1" > "$TMP/bin/sudo"
  chmod +x "$TMP/bin/sudo"
}
lib() { PATH="$TMP/bin:$PATH" bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

# Only the stub directory on PATH. Removing the sudo stub is NOT enough: a
# GitHub runner has a real, PASSWORDLESS sudo, so the "absent" case fell through
# to it and judged absent sudo usable — green on a workstation, red in CI. The
# same mistake as the missing-tool cases above, made two sections after the
# comment warning about it.
#
# /bin/bash by absolute path, because with PATH reduced to the stub directory
# `bash` itself stops being findable: the call dies 127 and the `&&` chain reads
# that as the answer, so the assertion passes having run nothing. oa_sudo_usable
# calls no external command, so the bare PATH costs it nothing.
lib_bare() { env PATH="$TMP/bin" /bin/bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

sudostub 0
lib oa_sudo_usable && ok "passwordless sudo is usable" || bad "passwordless sudo judged unusable"
sudostub 1
lib oa_sudo_usable && bad "sudo that would prompt was judged usable with no terminal" \
                   || ok "sudo that would prompt, with no terminal, is not usable"
rm -f "$TMP/bin/sudo"
lib_bare oa_sudo_usable && bad "absent sudo judged usable" || ok "absent sudo is not usable"

echo
echo "=== and where a binary should go ==="
sudostub 0
[ "$(lib oa_bin_dir)" = /usr/local/bin ] \
  && ok "with a usable sudo, the system directory" \
  || bad "with a usable sudo, got $(lib oa_bin_dir)"
sudostub 1
if [ -w /usr/local/bin ]; then
  echo "  ~ /usr/local/bin is writable here (root?), so the fallback case is NOT exercised"
elif [ "$(lib oa_bin_dir)" = "$HOME/.local/bin" ]; then
  ok "with no usable sudo, the per-user directory"
else
  bad "with no usable sudo, got $(lib oa_bin_dir)"
fi

mkdir -p "$TMP/writable"
[ -z "$(lib oa_sudo_for "$TMP/writable")" ] \
  && ok "a writable directory needs no sudo" || bad "a writable directory asked for sudo"
[ -z "$(lib oa_sudo_for "$TMP/writable/not-created-yet")" ] \
  && ok "a directory yet to be created is judged by its parent" \
  || bad "creating a subdirectory of a writable one asked for sudo"
sudostub 0
[ "$(lib oa_sudo_for /usr/local/bin)" = "sudo" ] || [ -w /usr/local/bin ] \
  && ok "a directory needing privilege gets the prefix" \
  || bad "a directory needing privilege got no prefix"
rm -f "$TMP/bin/sudo"

echo
echo "=== a Python tool is installed at the pin, and a failing step falls through ==="
# apt and brew cannot name a version, so pip_install_pinned is the only path
# for checkov, yamllint and pre-commit: it must ask for exactly pkg==version.
sed -n '/^pip_install_pinned() {/,/^}/p' "$ROOT/scripts/setup.sh" > "$TMP/pip.sh"
grep -q 'pipx install' "$TMP/pip.sh" || {
  echo "✗ could not extract pip_install_pinned from setup.sh" >&2; exit 1; }
pipstub() { # <name> <rc> — records its arguments in $TMP/calls
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit %s\n' "$1" "$TMP" "$2" > "$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}
pipcall() { # <pkg> <ver> — runs the function with only the stubs on PATH
  : > "$TMP/calls"
  PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" SUDO="" \
    bash -c '. "$1"; pip_install_pinned "$2" "$3"' _ "$TMP/pip.sh" "$1" "$2" >/dev/null 2>&1
}
mkdir -p "$TMP/home"
pipstub pipx 0; pipstub python3 0
pipcall checkov 3.3.22
grep -qx 'pipx install --force checkov==3.3.22' "$TMP/calls" \
  && ok "pipx is asked for pkg==version, and --force so an older install is replaced" \
  || bad "pipx was not asked for checkov==3.3.22: $(cat "$TMP/calls")"
pipstub pipx 1
pipcall yamllint 1.38.0
grep -q 'python3 -m pip install --user yamllint==1.38.0' "$TMP/calls" \
  && ok "a failing pipx falls through to pip --user at the same pin" \
  || bad "no pip --user fallback after pipx failed: $(cat "$TMP/calls")"
rm -f "$TMP/bin/pipx" "$TMP/bin/python3"

echo
echo "=== PyYAML is installed where the system python3 can import it ==="
# `task preflight` imports yaml from three scripts. CI's runner image has it and a
# clean machine does not, so nothing installed it until a bare-container run found it.
sed -n '/^ensure_pyyaml() {/,/^}/p' "$ROOT/scripts/setup.sh" > "$TMP/yaml.sh"
grep -q 'python3-yaml' "$TMP/yaml.sh" || {
  echo "✗ could not extract ensure_pyyaml from setup.sh" >&2; exit 1; }
yamlstub() { # <name> <rc> — records its arguments in $TMP/calls
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit %s\n' "$1" "$TMP" "$2" > "$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}
yamlcall() { # runs the function with only the stubs on PATH, never the real apt or brew
  : > "$TMP/calls"
  PATH="$TMP/bin" SUDO="" RED="" NC="" \
    /bin/bash -c '. "$1"; ensure_pyyaml' _ "$TMP/yaml.sh" > "$TMP/yaml.out" 2>&1
}
rm -f "$TMP/bin/apt-get" "$TMP/bin/brew"
yamlstub python3 0
yamlstub apt-get 0
yamlcall
[ ! -s "$TMP/calls" ] || ! grep -q 'apt-get' "$TMP/calls" \
  && ok "yaml already importable: nothing is installed" \
  || bad "installed although python3 could import yaml: $(cat "$TMP/calls")"
yamlstub python3 1
yamlcall
grep -qx 'apt-get install -y python3-yaml' "$TMP/calls" \
  && ok "yaml not importable and apt present: python3-yaml is installed" \
  || bad "apt was not asked for python3-yaml: $(cat "$TMP/calls")"
rm -f "$TMP/bin/apt-get"; yamlstub brew 0
yamlcall
grep -qx 'brew install pyyaml' "$TMP/calls" \
  && ok "no apt but brew: pyyaml is installed through it" \
  || bad "brew was not asked for pyyaml: $(cat "$TMP/calls")"
rm -f "$TMP/bin/brew"
yamlcall; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'python3-yaml' "$TMP/yaml.out"; } \
  && ok "neither apt nor brew: the install command is named, and the script is not aborted" \
  || bad "no instruction when nothing can install it (rc=$rc): $(cat "$TMP/yaml.out")"
rm -f "$TMP/bin/python3"
# The function is worth nothing if the bootstrap never calls it, and removing the
# call would bring the defect back while every case above still passed.
grep -qx 'ensure_pyyaml' "$ROOT/scripts/setup.sh" \
  && ok "and the bootstrap calls it, not only defines it" \
  || bad "ensure_pyyaml is defined in setup.sh but never called"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor, not just a verdict: `FAIL -eq 0` is also true when the harness died
# before asserting anything, which is the shape this repository keeps meeting.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
