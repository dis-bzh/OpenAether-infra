#!/usr/bin/env bash
# Versioning, noncurrent-version expiry and object lock on the buckets that hold backups and logs, and the read-back
# that says whether they are really there. Sourced by ensure-buckets.sh (writes) and s3-isolation-check.sh (reads).
#
# Opt-in: backup_immutability = off | versioned | governance | compliance in the tfvars (default off = nothing is
# touched). Every claim is read back from the store, because an S3-compatible API may accept a call and ignore it.

OA_LIFECYCLE_ID="oa-noncurrent-expiry"

oa_immutability() { # <tfvars> -> off|versioned|governance|compliance
  local v; v="$(tfv "$1" backup_immutability)"; v="${v:-off}"
  case "$v" in
    off | versioned | governance | compliance) printf '%s' "$v" ;;
    *) echo "✗ backup_immutability must be off, versioned, governance or compliance (got '$v')" >&2; return 1 ;;
  esac
}

oa_retention_days() { # <tfvars> -> days (default 60): noncurrent-version expiry, and the default lock retention
  local v; v="$(tfv "$1" backup_retention_days)"; v="${v:-60}"
  case "$v" in
    '' | *[!0-9]*) echo "✗ backup_retention_days must be a whole number of days (got '$v')" >&2; return 1 ;;
  esac
  [ "$v" -ge 1 ] && [ "$v" -le 3650 ] || { echo "✗ backup_retention_days must be 1 to 3650 (got '$v')" >&2; return 1; }
  printf '%s' "$v"
}

# <ak> <sk> <endpoint> <region> <s3api operation and arguments...>
_oa_s3api() {
  local ak="$1" sk="$2" ep="$3" rg="$4"; shift 4
  AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" aws s3api "$@" --endpoint-url "$ep" --region "$rg" --output json
}

_oa_first_line() { tr '\n' ' ' <<<"$1" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-160; }

# oa_protection_state <bucket> <endpoint> <region> <ak> <sk>
# One line: versioning=<Enabled|Suspended|off|unreadable> noncurrent_days=<n|none|unreadable> lock=<MODE:days|enabled|none|unreadable>
oa_protection_state() {
  local b="$1" ep="$2" rg="$3" ak="$4" sk="$5" out v nd lk
  if out="$(_oa_s3api "$ak" "$sk" "$ep" "$rg" get-bucket-versioning --bucket "$b" 2>&1)"; then
    v="$(jq -r '.Status // "off"' <<<"$out" 2>/dev/null)" || v=unreadable
  else v=unreadable; fi
  if out="$(_oa_s3api "$ak" "$sk" "$ep" "$rg" get-bucket-lifecycle-configuration --bucket "$b" 2>&1)"; then
    nd="$(jq -r --arg id "$OA_LIFECYCLE_ID" '[.Rules[]? | select(.ID == $id and .Status == "Enabled") | .NoncurrentVersionExpiration.NoncurrentDays][0] // "none"' <<<"$out" 2>/dev/null)" || nd=unreadable
  elif grep -q 'NoSuchLifecycleConfiguration' <<<"$out"; then nd=none
  else nd=unreadable; fi
  if out="$(_oa_s3api "$ak" "$sk" "$ep" "$rg" get-object-lock-configuration --bucket "$b" 2>&1)"; then
    lk="$(jq -r 'if .ObjectLockConfiguration.ObjectLockEnabled != "Enabled" then "none"
                 elif .ObjectLockConfiguration.Rule.DefaultRetention then "\(.ObjectLockConfiguration.Rule.DefaultRetention.Mode):\(.ObjectLockConfiguration.Rule.DefaultRetention.Days // "years")"
                 else "enabled" end' <<<"$out" 2>/dev/null)" || lk=unreadable
  elif grep -q 'ObjectLockConfigurationNotFoundError' <<<"$out"; then lk=none
  else lk=unreadable; fi
  printf 'versioning=%s noncurrent_days=%s lock=%s' "$v" "$nd" "$lk"
}

# oa_protect_bucket <bucket> <endpoint> <region> <ak> <sk> <mode> <days> <lock|nolock>
# Writes what <mode> asks for, merges (never replaces) the bucket's lifecycle rules, reads it all back, prints one line.
# Returns 1 when something asked for is not confirmed.
oa_protect_bucket() {
  local b="$1" ep="$2" rg="$3" ak="$4" sk="$5" mode="$6" days="$7" kind="$8"
  local err cur rules new want_lock="" problems="" st lk_mode vers_err=""
  if ! _oa_s3api "$ak" "$sk" "$ep" "$rg" head-bucket --bucket "$b" >/dev/null 2>&1; then
    echo "  ⚠ $b: not there, nothing to protect"; return 1
  fi
  [ "$kind" = lock ] && case "$mode" in governance | compliance) want_lock="$(tr '[:lower:]' '[:upper:]' <<<"$mode")" ;; esac

  # A bucket created WITH object lock is versioned already, and Outscale then refuses the PUT (InvalidBucketState, lab 22):
  # a refusal only counts when the read-back below does not confirm Enabled.
  vers_err="$(_oa_s3api "$ak" "$sk" "$ep" "$rg" put-bucket-versioning --bucket "$b" \
          --versioning-configuration Status=Enabled 2>&1 >/dev/null)" || vers_err="${vers_err:-refused}"

  # put-bucket-lifecycle-configuration REPLACES the whole set: read the rules first, and write nothing when they cannot be read.
  if cur="$(_oa_s3api "$ak" "$sk" "$ep" "$rg" get-bucket-lifecycle-configuration --bucket "$b" 2>&1)"; then
    rules="$(jq -c '.Rules // []' <<<"$cur" 2>/dev/null)" || rules=""
  elif grep -q 'NoSuchLifecycleConfiguration' <<<"$cur"; then rules='[]'
  else rules=""; fi
  if [ -z "$rules" ]; then
    problems+="lifecycle rules unreadable, so none written (a write would drop the ones I cannot see); "
  else
    new="$(jq -c --arg id "$OA_LIFECYCLE_ID" --argjson d "$days" \
      '{Rules: (map(select(.ID != $id)) + [{ID:$id, Status:"Enabled", Filter:{Prefix:""}, NoncurrentVersionExpiration:{NoncurrentDays:$d}}])}' <<<"$rules")"
    err="$(_oa_s3api "$ak" "$sk" "$ep" "$rg" put-bucket-lifecycle-configuration --bucket "$b" \
            --lifecycle-configuration "$new" 2>&1 >/dev/null)" || problems+="lifecycle refused ($(_oa_first_line "$err")); "
  fi

  if [ -n "$want_lock" ]; then
    err="$(_oa_s3api "$ak" "$sk" "$ep" "$rg" put-object-lock-configuration --bucket "$b" --object-lock-configuration \
            "{\"ObjectLockEnabled\":\"Enabled\",\"Rule\":{\"DefaultRetention\":{\"Mode\":\"$want_lock\",\"Days\":$days}}}" 2>&1 >/dev/null)" ||
      problems+="object lock refused ($(_oa_first_line "$err")); a bucket usually has to be CREATED with it, see docs/backup-policy.md; "
  fi

  st="$(oa_protection_state "$b" "$ep" "$rg" "$ak" "$sk")"
  case "$st" in *"versioning=Enabled"*) ;; *) problems+="${vers_err:+versioning refused ($(_oa_first_line "$vers_err")); }${vers_err:-versioning not confirmed; }" ;; esac
  case "$st" in *"noncurrent_days=$days "*) ;; *) problems+="expiry of old versions not confirmed; " ;; esac
  if [ -n "$want_lock" ]; then
    case "$st" in *"lock=$want_lock:$days") ;; *) problems+="object lock not confirmed; " ;; esac
  fi
  if [ -n "$problems" ]; then
    echo "  ⚠ $b: NOT fully protected: ${problems%; } [$st]"; return 1
  fi
  lk_mode="no object lock"; [ -n "$want_lock" ] && lk_mode="object lock $want_lock ${days}d"
  echo "  ✓ $b: versioned, old versions expire after ${days}d, ${lk_mode} (read back)"
}
