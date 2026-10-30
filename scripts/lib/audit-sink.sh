#!/usr/bin/env bash
# shellcheck disable=SC2034  # the AS_* variables are the interface: they are read by the scripts that source this file
# The audit sink's settings, read from a cluster tfvars and CHECKED (infra #318, docs/audit-sink.md). Sourced by ensure-buckets.sh,
# seed-openbao.sh, backup-key-recipe.sh and audit-sink-check.sh, after lib/common.sh. Off by default: oa_audit_sink_load returns 0
# with AS_PLACEMENT=off and touches nothing else.
#
#   oa_audit_sink_load <tfvars>   sets AS_PLACEMENT AS_PREFIX AS_MODE (GOVERNANCE|COMPLIANCE) AS_DAYS, and per sink n=1,2:
#                                 AS_EP<n> AS_RG<n> AS_KIND<n> (other_provider|same_provider_other_region).
#                                 Returns 1 with every problem on stderr when the choice is not coherent: the caller must stop
#                                 BEFORE creating a bucket (a sink that is not where it claims to be is worse than none).
# The same rules are a `check` block of the cluster root (a warning there, so that a plan and a destroy keep working).

oa_audit_bucket() { printf 's3-%s-%s-audit-%s' "$1" "$2" "$3"; }   # project provider env: named after the CLUSTER's provider, held anywhere

oa_audit_sink_load() { # <tfvars>
  local t="$1" prov pep prg v problems=() ack
  AS_PLACEMENT="$(tfv "$t" audit_sink_placement)"; AS_PLACEMENT="${AS_PLACEMENT:-off}"
  AS_EP1=""; AS_RG1=""; AS_KIND1=""; AS_EP2=""; AS_RG2=""; AS_KIND2=""; AS_PREFIX=audit; AS_MODE=GOVERNANCE; AS_DAYS=365
  case "$AS_PLACEMENT" in
    off) return 0 ;;
    other_provider | same_provider_other_region | both) ;;
    *) echo "✗ audit_sink_placement must be off, other_provider, same_provider_other_region or both (got '$AS_PLACEMENT')" >&2; return 1 ;;
  esac
  prov="$(tfv_provider "$t")"; pep="$(tfv "$t" s3_primary_endpoint)"; prg="$(tfv "$t" s3_primary_region)"
  AS_EP1="$(tfv "$t" audit_sink_endpoint)"; AS_RG1="$(tfv "$t" audit_sink_region)"
  AS_EP2="$(tfv "$t" audit_sink_secondary_endpoint)"; AS_RG2="$(tfv "$t" audit_sink_secondary_region)"
  v="$(tfv "$t" audit_sink_prefix)"; AS_PREFIX="${v:-audit}"
  case "$AS_PLACEMENT" in
    other_provider) AS_KIND1=other_provider; AS_EP2=""; AS_RG2="" ;;
    same_provider_other_region) AS_KIND1=same_provider_other_region; AS_EP2=""; AS_RG2="" ;;
    both) AS_KIND1=other_provider; AS_KIND2=same_provider_other_region ;;
  esac
  [ -n "$AS_EP1" ] && [ -n "$AS_RG1" ] || problems+=("audit_sink_endpoint and audit_sink_region are required")
  if [ "$AS_PLACEMENT" = both ]; then
    [ -n "$AS_EP2" ] && [ -n "$AS_RG2" ] || problems+=("audit_sink_placement = both: audit_sink_secondary_endpoint and audit_sink_secondary_region are required")
  fi
  case "$AS_PREFIX" in
    *[!a-z0-9/_-]* | /* | */ | "") problems+=("audit_sink_prefix must be lowercase letters, digits, - _ and /, not start or end with /") ;;
  esac

  # Where each sink sits, against the CLUSTER's provider (never against the replica store: the sink is its own choice).
  local cp; cp="$(provider_of_endpoint "$pep")"; cp="${cp:-$prov}"   # the cluster's cloud: its primary store's, else its node_distribution
  _oa_as_norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^[[:space:]]+##; s#[[:space:]/]+$##'; }
  _oa_as_other() { # <endpoint>: why it is NOT on another provider, or nothing
    local p; p="$(provider_of_endpoint "$1")"
    if [ "$(_oa_as_norm "$1")" = "$(_oa_as_norm "$pep")" ]; then printf 'it is the cluster'"'"'s own endpoint'
    elif [ -n "$p" ] && [ "$p" = "$cp" ]; then printf 'it is on the cluster'"'"'s own provider (%s)' "$p"; fi
  }
  _oa_as_same() { # <endpoint> <region>: why it is NOT the cluster's provider in another region, or nothing
    local p out=""; p="$(provider_of_endpoint "$1")"
    if [ -z "$p" ]; then [ "$(_oa_as_norm "$1")" = "$(_oa_as_norm "$pep")" ] || out="its provider cannot be told from the host name, so it cannot be shown to be the cluster's own"
    elif [ "$p" != "$cp" ]; then out="it is on $p, the cluster is on $cp"; fi
    if [ "$2" = "$prg" ]; then out="${out:+$out; }the region is the primary store's ($prg): that is one site, not two"; fi
    printf '%s' "$out"
  }
  local why
  if [ -n "$AS_EP1" ]; then
    if [ "$AS_KIND1" = other_provider ]; then
      why="$(_oa_as_other "$AS_EP1")"; [ -z "$why" ] || problems+=("audit_sink_placement = ${AS_PLACEMENT}: audit_sink_endpoint must be on ANOTHER provider, but ${why}")
    else
      why="$(_oa_as_same "$AS_EP1" "$AS_RG1")"; [ -z "$why" ] || problems+=("audit_sink_placement = ${AS_PLACEMENT}: audit_sink_endpoint must be the cluster's provider in another region, but ${why}")
    fi
  fi
  if [ -n "$AS_EP2" ]; then
    why="$(_oa_as_same "$AS_EP2" "$AS_RG2")"; [ -z "$why" ] || problems+=("audit_sink_placement = both: audit_sink_secondary_endpoint must be the cluster's provider in another region, but ${why}")
    [ "$AS_EP2" != "$AS_EP1" ] || problems+=("audit_sink_secondary_endpoint equals audit_sink_endpoint: that is one sink twice")
  fi

  v="$(tfv "$t" audit_sink_lock_mode)"; v="${v:-governance}"
  case "$v" in
    governance) AS_MODE=GOVERNANCE ;;
    compliance)
      AS_MODE=COMPLIANCE; ack="$(tfv "$t" audit_sink_compliance_ack)"
      [ "$ack" = true ] || problems+=("audit_sink_lock_mode = compliance cannot be undone before the retention ends, by anyone, and the bucket cannot be emptied or deleted until then: set audit_sink_compliance_ack = true to say you mean it") ;;
    *) problems+=("audit_sink_lock_mode must be governance or compliance (got '$v')") ;;
  esac
  v="$(tfv "$t" audit_sink_retention_days)"; v="${v:-365}"
  case "$v" in '' | *[!0-9]*) problems+=("audit_sink_retention_days must be a whole number of days (got '$v')") ;; *)
    { [ "$v" -ge 1 ] && [ "$v" -le 3650 ]; } && AS_DAYS="$v" || problems+=("audit_sink_retention_days must be 1 to 3650 (got '$v')") ;; esac

  if [ "${#problems[@]}" -gt 0 ]; then
    printf '✗ audit sink: %s\n' "${problems[@]}" >&2
    return 1
  fi
}

# Whose keys open a sink's bucket (the operator's, to CREATE it): the keys of the cloud that HOLDS it, as for the replica store.
oa_audit_sink_operator_cred() { # <cluster provider> <endpoint> <ak|sk>
  s3_cred "$1" backup "$3" "$2"
}
