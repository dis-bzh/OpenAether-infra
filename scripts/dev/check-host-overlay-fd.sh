#!/usr/bin/env bash
# Preflight: does the kernel under Docker accept overlayfs layers given as O_PATH
# file descriptors? Talos 1.14 builds its writable /etc overlay that way
# (fsconfig FSCONFIG_SET_FD, key "lowerdir+"). Where the kernel refuses, every node
# of the Docker lane dies at boot with
#   failed to set up /etc overlay ... FSCONFIG_SET_FD failed: bad file descriptor:
#   key="lowerdir+"
# and the bootstrap waits until its timeout (#291), ten minutes in the run that found it.
#
# WHY A KERNEL: layers by file descriptor arrived in Linux 6.13 ("ovl: specify layers
# via file descriptors") and O_PATH ones in 6.15 ("fs: support O_PATH fds with
# FSCONFIG_SET_FD"). On 6.12.107 fsconfig answers EBADF for an O_PATH layer, the very
# error above. A GitHub-hosted ubuntu-24.04 runner (6.17) boots the lane; a Debian 13
# host (6.12) does not.
#
# HOW IT ANSWERS: the version Docker's daemon reports is the quick answer (a kernel
# below 6.15 is suspect, a distribution may have backported the fix). When the daemon
# runs on THIS kernel the answer is confirmed by asking the kernel itself, in a user
# namespace, with the same call Talos makes. Refuses only on that confirmation; a
# kernel it cannot ask (a Docker Desktop VM, no unshare, no python3) gets a warning
# and the run goes on, the same fail-open shape as check-docker-talos-capability.sh.
#
# OA_OVERLAY_PROBE overrides the command that asks the kernel; it must print ACCEPTED or
# REFUSED, anything else is "cannot tell" (the harness uses it, nothing else should).
#
# Usage: check-host-overlay-fd.sh
set -uo pipefail

WANT_MAJOR=6
WANT_MINOR=15

kernel_of_docker() { docker info --format '{{.KernelVersion}}' 2>/dev/null; }
older_than_want() { # <kernel release string> — true when it parses and is below 6.15
  local maj min
  maj="${1%%.*}"; min="${1#*.}"; min="${min%%[!0-9]*}"
  [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1
  [ "$maj" -lt "$WANT_MAJOR" ] || { [ "$maj" -eq "$WANT_MAJOR" ] && [ "$min" -lt "$WANT_MINOR" ]; }
}

probe_py() {
  cat <<'PY'
import ctypes, os, sys, tempfile
libc = ctypes.CDLL(None, use_errno=True)
FSOPEN, FSCONFIG = 430, 431
SET_FD = 5
d = tempfile.mkdtemp()
l = os.path.join(d, "l"); os.mkdir(l)
fs = libc.syscall(FSOPEN, b"overlay", 1)
if fs < 0:
    print("UNKNOWN")                               # no new mount API, or not allowed here: cannot tell
    sys.exit(0)
fd = os.open(l, getattr(os, "O_PATH", 0o10000000) | os.O_DIRECTORY)
r = libc.syscall(FSCONFIG, fs, SET_FD, b"lowerdir+", None, fd)
print("ACCEPTED" if r == 0 else ("REFUSED" if ctypes.get_errno() in (9, 22) else "UNKNOWN"))   # EBADF / EINVAL
PY
}

ask_kernel() { # 0 accepted, 1 refused, 2 cannot tell
  local said
  if [ -n "${OA_OVERLAY_PROBE:-}" ]; then said="$($OA_OVERLAY_PROBE 2>/dev/null)"
  else
    command -v unshare >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 2
    said="$(unshare -Urm python3 -c "$(probe_py)" 2>/dev/null)"
  fi
  case "$said" in ACCEPTED) return 0;; REFUSED) return 1;; *) return 2;; esac
}

KERNEL="$(kernel_of_docker)"
[ -n "$KERNEL" ] || exit 0                         # no Docker answer: the lane fails on its own, loudly, in seconds
older_than_want "$KERNEL" || exit 0                # 6.15 or newer, or unparsable: nothing to say

if [ "$KERNEL" = "$(uname -r)" ]; then
  ask_kernel; answer=$?
else
  answer=2
fi

case $answer in
  0) exit 0 ;;                                     # an older version string with the fix backported
  1)
    cat >&2 <<EOT
✗ this host's kernel ($KERNEL) cannot run the Docker Talos lane at Talos 1.14.

  Talos 1.14 builds the writable /etc of each node as an overlayfs whose layers are
  passed as O_PATH file descriptors (fsconfig FSCONFIG_SET_FD, key "lowerdir+").
  Linux accepts that from 6.15 (6.13 added layers by file descriptor, 6.15 the
  O_PATH ones); this kernel refused the same call (EBADF). Without it every node
  dies at boot with "failed to set up /etc overlay ... FSCONFIG_SET_FD failed: bad
  file descriptor" and the bootstrap only gives up ten minutes later (#291).

  Use a host whose kernel is 6.15 or newer (a GitHub-hosted ubuntu-24.04 runner is on
  6.17). A Docker Desktop or WSL2 kernel counts: check \`docker info --format
  '{{.KernelVersion}}'\`.
EOT
    exit 1 ;;
  *)
    cat >&2 <<EOT
⚠ Docker runs on kernel $KERNEL, older than 6.15, and this script could not ask it
  whether overlayfs accepts O_PATH layer descriptors (it can only do so when the
  daemon runs on this machine's own kernel, with unshare and python3). Talos 1.14 needs
  that: if every node dies at boot with "failed to set up /etc overlay ...
  FSCONFIG_SET_FD failed: bad file descriptor", this is why (#291).
EOT
    exit 0 ;;
esac
