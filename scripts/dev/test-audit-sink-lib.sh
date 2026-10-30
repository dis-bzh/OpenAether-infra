#!/usr/bin/env bash
# scripts/lib/audit-sink.sh: the audit sink's settings are read from the tfvars and REFUSED when the choice is not coherent, before
# any bucket is created (infra #318). Offline, no provider. Rung: mocked/static.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
source scripts/lib/common.sh
source scripts/lib/audit-sink.sh
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$*"; FAIL=$((FAIL + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mk() { # [extra tfvars lines...] — a Scaleway cluster in fr-par
  sed -E 's#^environment[[:space:]].*#environment = "dev"#; s#^cluster_name.*#cluster_name = "example"#;
          s#^s3_primary_endpoint.*#s3_primary_endpoint = "https://s3.fr-par.scw.cloud"#; s#^s3_primary_region.*#s3_primary_region = "fr-par"#' \
    infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example >"$SB/t.tfvars"
  printf '%s\n' "$@" >>"$SB/t.tfvars"
}
load() { oa_audit_sink_load "$SB/t.tfvars" 2>"$SB/err"; }
refused() { # <name> <text expected in the message>
  if load; then bad "$1: accepted"; elif grep -q -- "$2" "$SB/err"; then ok "$1"; else bad "$1: refused, but not for '$2': $(cat "$SB/err")"; fi
}

mk; load && [ "$AS_PLACEMENT" = off ] && [ -z "$AS_EP1" ] && ok "default: off, nothing set" || bad "default"
mk 'audit_sink_placement = "off"' 'audit_sink_endpoint = "https://s3.fr-par.scw.cloud"'; load && [ "$AS_PLACEMENT" = off ] && ok "off ignores whatever else is set" || bad "off"

mk 'audit_sink_placement = "other_provider"' 'audit_sink_endpoint = "https://s3.gra.io.cloud.ovh.net"' 'audit_sink_region = "gra"'
if load && [ "$AS_EP1" = https://s3.gra.io.cloud.ovh.net ] && [ "$AS_RG1" = gra ] && [ "$AS_MODE" = GOVERNANCE ] && [ "$AS_DAYS" = 365 ] && [ "$AS_PREFIX" = audit ] && [ -z "$AS_EP2" ]; then
  ok "other_provider on OVH for a Scaleway cluster: accepted, GOVERNANCE, 365 days, prefix audit"; else bad "other_provider: $(cat "$SB/err")"; fi
mk 'audit_sink_placement = "other_provider"' 'audit_sink_endpoint = "https://s3.nl-ams.scw.cloud"' 'audit_sink_region = "nl-ams"'
refused "other_provider on the cluster's own provider (Scaleway in another region) is refused" "ANOTHER provider"
mk 'audit_sink_placement = "other_provider"' 'audit_sink_endpoint = "https://s3.fr-par.scw.cloud/"' 'audit_sink_region = "fr-par"'
refused "other_provider on the cluster's own endpoint (trailing slash) is refused" "own endpoint"
mk 'audit_sink_placement = "other_provider"' 'audit_sink_endpoint = "https://minio.example.invalid"' 'audit_sink_region = "x"'
load && ok "other_provider on a host the repo cannot name is accepted when it is not the cluster's endpoint" || bad "unknown host: $(cat "$SB/err")"
mk 'audit_sink_placement = "other_provider"'; refused "a missing endpoint is refused" "required"

mk 'audit_sink_placement = "same_provider_other_region"' 'audit_sink_endpoint = "https://s3.nl-ams.scw.cloud"' 'audit_sink_region = "nl-ams"'
load && [ "$AS_KIND1" = same_provider_other_region ] && ok "same provider, another region: accepted" || bad "same provider: $(cat "$SB/err")"
mk 'audit_sink_placement = "same_provider_other_region"' 'audit_sink_endpoint = "https://s3.fr-par.scw.cloud"' 'audit_sink_region = "fr-par"'
refused "the same region is one site, refused" "one site"
mk 'audit_sink_placement = "same_provider_other_region"' 'audit_sink_endpoint = "https://s3.gra.io.cloud.ovh.net"' 'audit_sink_region = "gra"'
refused "another cloud under the same-provider choice is refused" "it is on ovh, the cluster is on scaleway"

mk 'audit_sink_placement = "both"' 'audit_sink_endpoint = "https://s3.gra.io.cloud.ovh.net"' 'audit_sink_region = "gra"' \
  'audit_sink_secondary_endpoint = "https://s3.nl-ams.scw.cloud"' 'audit_sink_secondary_region = "nl-ams"'
load && [ "$AS_KIND1" = other_provider ] && [ "$AS_KIND2" = same_provider_other_region ] && [ "$AS_EP2" = https://s3.nl-ams.scw.cloud ] && ok "both: one of each, in that order" || bad "both: $(cat "$SB/err")"
mk 'audit_sink_placement = "both"' 'audit_sink_endpoint = "https://s3.gra.io.cloud.ovh.net"' 'audit_sink_region = "gra"'
refused "both without the secondary sink is refused" "secondary_endpoint"
mk 'audit_sink_placement = "both"' 'audit_sink_endpoint = "https://s3.nl-ams.scw.cloud"' 'audit_sink_region = "nl-ams"' \
  'audit_sink_secondary_endpoint = "https://s3.nl-ams.scw.cloud"' 'audit_sink_secondary_region = "nl-ams"'
refused "both with the first sink on the cluster's provider is refused" "ANOTHER provider"

B='audit_sink_placement = "other_provider"'; E='audit_sink_endpoint = "https://s3.gra.io.cloud.ovh.net"'; R='audit_sink_region = "gra"'
mk "$B" "$E" "$R" 'audit_sink_lock_mode = "compliance"'; refused "COMPLIANCE without the explicit opt-in is refused" "audit_sink_compliance_ack"
mk "$B" "$E" "$R" 'audit_sink_lock_mode = "compliance"' 'audit_sink_compliance_ack = false'; refused "COMPLIANCE with the opt-in false is refused" "audit_sink_compliance_ack"
mk "$B" "$E" "$R" 'audit_sink_lock_mode = "compliance"' 'audit_sink_compliance_ack = true' 'audit_sink_retention_days = 30'
load && [ "$AS_MODE" = COMPLIANCE ] && [ "$AS_DAYS" = 30 ] && ok "COMPLIANCE with the opt-in: accepted, 30 days" || bad "compliance: $(cat "$SB/err")"
mk "$B" "$E" "$R" 'audit_sink_lock_mode = "locked"'; refused "an unknown lock mode is refused" "governance or compliance"
mk "$B" "$E" "$R" 'audit_sink_retention_days = 0'; refused "a retention of 0 is refused" "1 to 3650"
mk "$B" "$E" "$R" 'audit_sink_retention_days = "x"'; refused "a retention that is not a number is refused" "whole number"
mk "$B" "$E" "$R" 'audit_sink_prefix = "/bad/"'; refused "a prefix with a leading or trailing slash is refused" "audit_sink_prefix"
mk 'audit_sink_placement = "nowhere"'; refused "an unknown placement is refused" "audit_sink_placement must be"
mk "$B" "$E" "$R" 'audit_sink_prefix = "audit/eu"'; load && [ "$AS_PREFIX" = audit/eu ] && ok "a nested prefix is accepted" || bad "prefix"
[ "$(oa_audit_bucket example scaleway dev)" = s3-example-scaleway-audit-dev ] && ok "bucket name: s3-<project>-<cluster provider>-audit-<env>" || bad "bucket name"

echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
