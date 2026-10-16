#!/usr/bin/env bash
# ==============================================================================
# OpenAether — pinning the bastion's SSH host key (source this; do not execute)
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/bastion-hostkey.sh"
#
# ANSSI NT-SSH R6 / NT-007 R6: the client must know the server's key before it trusts it. A bastion is made by
# cloud-init and its host key is born on the VM, so the key cannot be pinned BEFORE the first contact; what can be
# done is to (1) compare the first key with a fingerprint read out of band, (2) keep it in a file that survives the
# run, (3) refuse any other key on that address afterwards. Private host keys are NOT injected through cloud-init
# (they would sit in the state and the user_data).
#
# Opt-in through OA_BASTION_PIN_HOSTKEY; unset keeps what the scripts always did (a known_hosts file emptied at every
# run, StrictHostKeyChecking=accept-new):
#   1        first contact is accepted ONCE and its fingerprint printed with a warning; every later run is strict
#   verify   first contact needs OA_BASTION_HOSTKEY_FP (SHA256:...) and refuses on a mismatch or when it is unset
# OA_BASTION_FORGET=1 drops the pinned entry of the bastion being contacted (the bastion was replaced on purpose and
# the NEW fingerprint was checked out of band). A replaced bastion that reuses its public address and has a new key is
# REFUSED until then: that is the point.
#
# Where to read the fingerprint out of band: cloud-init prints the host keys, and `ssh-keygen -lf` forms of them, to
# the instance console / serial log of the provider (docs/admin-access.md, "Bastion host key").
# ==============================================================================

oa_bastion_pin_mode() { # echoes "", "1" or "verify" ("0" and unknown values count as off)
  case "${OA_BASTION_PIN_HOSTKEY:-}" in 1|true|yes) printf '1' ;; verify) printf 'verify' ;; *) printf '' ;; esac
}

# Is there an entry for <ip> in <known_hosts>?
oa_bastion_kh_known() { # <known_hosts> <ip>
  [ -s "$1" ] && ssh-keygen -F "$2" -f "$1" >/dev/null 2>&1
}

# Fingerprints (SHA256:...) of the key(s) held for <ip> in <known_hosts>, one per line.
oa_bastion_kh_fps() { # <known_hosts> <ip>
  ssh-keygen -F "$2" -f "$1" 2>/dev/null | grep -v '^#' | ssh-keygen -lf - -E sha256 2>/dev/null | awk '{ print $2 }'
}

# Drop <ip> from <known_hosts> (a plain, unhashed entry: the probe writes them with HashKnownHosts=no).
oa_bastion_kh_forget() { # <known_hosts> <ip>
  [ -f "$1" ] || return 0
  ssh-keygen -R "$2" -f "$1" >/dev/null 2>&1 || true
  rm -f "$1.old"
}

# One reachability + key-acceptance probe. Returns 0 (logged in), 1 (not yet: refused, timed out, still booting) or
# 3 (the host key is NOT the one pinned; says so on stderr and never retries, a retry cannot change a key).
oa_bastion_probe() { # <known_hosts> <strict: yes|accept-new> <key> <user> <ip>
  local err rc
  err="$(ssh -o UserKnownHostsFile="$1" -o StrictHostKeyChecking="$2" -o HashKnownHosts=no \
           -o BatchMode=yes -o ConnectTimeout=8 -i "$3" "$4@$5" true 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  if grep -qE 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|Offending .* key' <<<"$err"; then
    echo "✗ $5 answers with a host key that is NOT the one pinned in $1." >&2
    echo "  If the bastion was replaced on purpose, read the new fingerprint out of band (the console log) and run with" >&2
    echo "  OA_BASTION_FORGET=1 OA_BASTION_HOSTKEY_FP=SHA256:... to pin the new one. Otherwise someone else holds this address." >&2
    return 3
  fi
  return 1
}

# Pin the bastion: leaves <known_hosts> holding its key and OA_BASTION_SHKC set to the StrictHostKeyChecking value the
# tunnels must use (always "yes" once pinned). Waits up to <wait> seconds for the bastion to accept the key, since
# the key is only final once cloud-init has reached its sshd restart.
oa_bastion_pin() { # <known_hosts> <ip> <user> <key> <wait seconds>
  local kh="$1" ip="$2" user="$3" key="$4" wait="${5:-300}" mode probe deadline rc fps want got
  mode="$(oa_bastion_pin_mode)"
  [ -n "$mode" ] || { echo "oa_bastion_pin: OA_BASTION_PIN_HOSTKEY is not set" >&2; return 2; }
  [ "${OA_BASTION_FORGET:-}" = 1 ] && oa_bastion_kh_forget "$kh" "$ip"
  want="${OA_BASTION_HOSTKEY_FP:-}"
  case "$want" in ""|SHA256:*) ;; *) echo "✗ OA_BASTION_HOSTKEY_FP must look like SHA256:<base64> (ssh-keygen -lf form)" >&2; return 2 ;; esac
  touch "$kh"; chmod 600 "$kh" 2>/dev/null || true

  if oa_bastion_kh_known "$kh" "$ip"; then
    # Repeat contact: strict. A key that differs is refused outright; an unready bastion is waited for.
    deadline=$(( SECONDS + wait ))
    until oa_bastion_probe "$kh" yes "$key" "$user" "$ip"; do
      rc=$?
      [ "$rc" -eq 3 ] && return 3
      (( SECONDS >= deadline )) && { echo "⚠ bastion still unreachable after ${wait}s - trying anyway." >&2; break; }
      sleep 10
    done
    # shellcheck disable=SC2034 # read by the sourcing script
    OA_BASTION_SHKC=yes
    return 0
  fi

  # First contact. The key is read on a PROBE file, after a successful login (so cloud-init is done), compared with the
  # fingerprint when one is given, and only then written to the pinned file.
  if [ "$mode" = verify ] && [ -z "$want" ]; then
    echo "✗ OA_BASTION_PIN_HOSTKEY=verify and no OA_BASTION_HOSTKEY_FP: refusing a first contact nobody checked." >&2
    echo "  Read the fingerprint of $ip from the provider's console log and pass OA_BASTION_HOSTKEY_FP=SHA256:..." >&2
    return 1
  fi
  probe="$(mktemp)"
  deadline=$(( SECONDS + wait ))
  until oa_bastion_probe "$probe" accept-new "$key" "$user" "$ip"; do
    (( SECONDS >= deadline )) && { rm -f "$probe"; echo "✗ bastion $ip did not accept the key within ${wait}s: no host key to pin." >&2; return 1; }
    sleep 10
  done
  fps="$(oa_bastion_kh_fps "$probe" "$ip")"
  if [ -z "$fps" ]; then rm -f "$probe"; echo "✗ logged in but no host key was recorded for $ip." >&2; return 1; fi
  if [ -n "$want" ]; then
    got="$(grep -Fx "$want" <<<"$fps" || true)"
    if [ -z "$got" ]; then
      rm -f "$probe"
      echo "✗ host key of $ip is ${fps//$'\n'/, } but OA_BASTION_HOSTKEY_FP says $want: NOT pinned. Whoever answers on $ip is not the bastion you checked." >&2
      return 3
    fi
    echo "✓ bastion host key ${got} matches the fingerprint given out of band; pinned in $kh"
  else
    echo "⚠ first contact with $ip: host key ${fps//$'\n'/, } was NOT verified out of band; pinned in $kh from now on." >&2
    echo "  Compare it with the console log of the instance; OA_BASTION_PIN_HOSTKEY=verify refuses this case." >&2
  fi
  cat "$probe" >>"$kh"; rm -f "$probe"
  # shellcheck disable=SC2034 # read by the sourcing script
  OA_BASTION_SHKC=yes
  return 0
}

# For the one-shot scripts (harden check, log pull): known_hosts file and StrictHostKeyChecking value to use, never "no".
# <file> is the pinned file when it holds <ip> (strict), else a private temp file with accept-new (first contact, which the
# caller then verifies with oa_bastion_check_fp). Sets OA_KH and OA_SHKC.
oa_bastion_oneshot_opts() { # <ip> [pinned known_hosts]
  local kh="${2:-${BASTION_KNOWN_HOSTS:-.talos-bastion-known-hosts}}"
  # shellcheck disable=SC2034 # OA_SHKC and OA_KH_TEMP are read by the sourcing script
  if oa_bastion_kh_known "$kh" "$1"; then OA_KH="$kh"; OA_SHKC=yes
  else OA_KH="$(mktemp)"; OA_SHKC=accept-new; OA_KH_TEMP=1
  fi
}

# After a first contact on a temp file: print the fingerprint, and compare it with OA_BASTION_HOSTKEY_FP when set.
oa_bastion_check_fp() { # <ip> — 0 fine, 1 mismatch
  local fps
  [ "${OA_KH_TEMP:-}" = 1 ] || return 0
  fps="$(oa_bastion_kh_fps "$OA_KH" "$1")"
  [ -n "$fps" ] || return 0
  if [ -n "${OA_BASTION_HOSTKEY_FP:-}" ]; then
    grep -Fxq "$OA_BASTION_HOSTKEY_FP" <<<"$fps" && return 0
    echo "host key of $1 is ${fps//$'\n'/, }, not the OA_BASTION_HOSTKEY_FP given" >&2; return 1
  fi
  echo "host key of $1 is ${fps//$'\n'/, } (first contact, not verified out of band; pin it with talos-tunnels.sh and OA_BASTION_PIN_HOSTKEY=1)" >&2
  return 0
}
