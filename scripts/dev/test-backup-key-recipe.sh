#!/usr/bin/env bash
# scripts/ops/backup-key-recipe.sh: names the right buckets for each pair, prints valid JSON policies that give the pair its
# own bucket and the operator everything, never mention the pair on another bucket, withhold DeleteObjectVersion, and print
# no identifier of its own. Offline: it calls no provider. Rung: mocked/static.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$*"; FAIL=$((FAIL + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
sed -E 's#^environment[[:space:]].*#environment = "dev"#; s#^cluster_name.*#cluster_name = "example"#' \
  infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example >"$SB/t.tfvars"
R=scripts/ops/backup-key-recipe.sh
P=s3-example-scaleway
out="$($R "$SB/t.tfvars" replica 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "replica recipe exits 0" || bad "replica exit $rc: $out"
grep -q "bucket $P-backups-dev-backup" <<<"$out" && ok "the replica pair's own bucket is the -backup twin of the backups bucket" || bad "own bucket: $out"
grep -q "Operator-only policy of $P-tfstate-dev-backup" <<<"$out" && grep -q "Operator-only policy of $P-management-dev-backup\|Operator-only policy of $P-.*-dev-backup" <<<"$out" && ok "operator-only policies cover the other -backup buckets" || bad "operator-only list"
# every JSON block parses; the pair is named only on its own bucket
python3 -I - "$out" <<'PY' && ok "JSON policies parse, give the pair only its own bucket, withhold DeleteObjectVersion" || bad "policy shape"
import json, re, sys
text = sys.argv[1]
blocks = re.findall(r"^\{.*?^\}", text, re.M | re.S)
assert len(blocks) >= 2, "want the own-bucket policy and at least one operator-only policy"
for b in blocks:
    d = json.loads(b)
    acts = {a for s in d["Statement"] for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"])}
    assert "s3:DeleteObjectVersion" not in acts and "s3:PutBucketPolicy" not in acts, "a withheld right is granted"
    pair = [s for s in d["Statement"] if s["Sid"].startswith("pair-")]
    own = d["Id"].endswith("-backups-dev-backup")
    assert bool(pair) == own, f"{d['Id']}: the pair appears on a bucket that is not its own"
    if own:
        assert {"s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"} <= acts
PY
# the replica pair lives on the REPLICA store: an OVH replica gets the OVH note and no bucket policy, whatever the cluster's cloud (lab 19)
sed -E 's#^s3_replica_endpoint[[:space:]]*=.*#s3_replica_endpoint = "https://s3.gra.io.cloud.ovh.net"#' "$SB/t.tfvars" >"$SB/o.tfvars"
out_o="$($R "$SB/o.tfvars" replica 2>&1)"
{ grep -q "replica pair for ovh" <<<"$out_o" && grep -q "OVH: no bucket policy" <<<"$out_o" && ! grep -q '"Version"' <<<"$out_o" && grep -q "bucket $P-backups-dev-backup" <<<"$out_o"; } \
  && ok "an OVH replica store: OVH note, no bucket policy, bucket named after the cluster" || bad "OVH replica: $out_o"
out_p="$($R "$SB/o.tfvars" primary 2>&1)"
grep -q "primary pair for scaleway" <<<"$out_p" && grep -q '"Version"' <<<"$out_p" && ok "the primary pair keeps the cluster's cloud" || bad "primary changed"
grep -qE 'SCW[0-9A-Z]{16}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}' <<<"$out" && bad "an identifier appears" || ok "no identifier of any account in the output"
out="$(PAIR_PRINCIPAL=11111111-example OPERATOR_PRINCIPAL=22222222-example $R "$SB/t.tfvars" primary 2>&1)"
python3 -I - "$out" <<'PY' && ok "primary: the principals given are used, SCW-style on Scaleway" || bad "principal not used"
import json, re, sys
d = json.loads(re.findall(r"^\{.*?^\}", sys.argv[1], re.M | re.S)[0])
pp = [s["Principal"] for s in d["Statement"] if s["Sid"].startswith("pair-")]
op = [s["Principal"] for s in d["Statement"] if s["Sid"] == "operator"]
assert pp and all(p == {"SCW": "application_id:11111111-example"} for p in pp), pp
assert op == [{"SCW": "user_id:22222222-example"}], op
PY
grep -q "bucket $P-backups-dev " <<<"$out" && ok "primary: its own bucket is the backups bucket" || bad "primary own bucket"
out="$($R "$SB/t.tfvars" loki 2>&1)"; grep -q "bucket $P-logs-dev" <<<"$out" && ok "loki: the logs bucket" || bad "loki bucket"
$R "$SB/t.tfvars" nonsense >/dev/null 2>&1; [ $? = 2 ] && ok "an unknown kind is a usage error" || bad "unknown kind accepted"

# --- audit sink pairs (infra #318): no delete right at all, the sink's own bucket, the OVH isolation limit stated
$R "$SB/t.tfvars" audit-sink >/dev/null 2>&1; [ $? = 2 ] && ok "audit-sink with the sink off is a usage error" || bad "audit-sink accepted with the sink off"
{ cat "$SB/t.tfvars"; printf '%s\n' 'audit_sink_placement = "same_provider_other_region"' 'audit_sink_endpoint = "https://s3.nl-ams.scw.cloud"' 'audit_sink_region = "nl-ams"'; } >"$SB/s.tfvars"
out_s="$($R "$SB/s.tfvars" audit-sink 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "audit-sink recipe (same provider, other region) exits 0" || bad "audit-sink exit $rc: $out_s"
python3 -I - "$out_s" <<'PY' && ok "audit-sink: the pair can list, get and put, and has NO delete right; the other buckets of the project are operator-only" || bad "audit-sink policy shape"
import json, re, sys
blocks = [json.loads(b) for b in re.findall(r"^\{.*?^\}", sys.argv[1], re.M | re.S)]
own = [d for d in blocks if d["Id"].endswith("-audit-dev")]
assert len(own) == 1, [d["Id"] for d in blocks]
acts = {a for s in own[0]["Statement"] for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"])}
assert {"s3:GetObject", "s3:PutObject", "s3:ListBucket"} <= acts, acts
assert not any("Delete" in a and a != "s3:*" for a in acts if a != "s3:*"), acts
pair = [s for s in own[0]["Statement"] if s["Sid"].startswith("pair-")]
assert pair and not any("Delete" in a for s in pair for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"])), "the pair holds a delete right"
others = [d["Id"] for d in blocks if not d["Id"].endswith("-audit-dev")]
assert any(i.endswith("-backups-dev") for i in others) and all(not [s for s in d["Statement"] if s["Sid"].startswith("pair-")] for d in blocks if d not in own), others
PY
grep -q "NO delete of any kind" <<<"$out_s" && grep -q "bucket $P-audit-dev" <<<"$out_s" && ok "audit-sink: says why there is no delete, and names the audit bucket" || bad "audit-sink text"
{ cat "$SB/t.tfvars"; printf '%s\n' 'audit_sink_placement = "other_provider"' 'audit_sink_endpoint = "https://s3.gra.io.cloud.ovh.net"' 'audit_sink_region = "gra"'; } >"$SB/ov.tfvars"
# infra #393: an OVH key pair reaches every bucket of its project, so the recipe will not call it dedicated until the operator names the sink's own project
out_ov0="$($R "$SB/ov.tfvars" audit-sink 2>&1)"; rc_ov0=$?
{ [ "$rc_ov0" = 2 ] && grep -q "OVH_SINK_PROJECT_ID" <<<"$out_ov0" && ! grep -q "Rights the pair must hold" <<<"$out_ov0"; } \
  && ok "audit-sink on OVH without OVH_SINK_PROJECT_ID: refused (exit 2), nothing printed that reads as a recipe" || bad "OVH sink without a project: rc=$rc_ov0 $out_ov0"
OVH_SINK_PROJECT_ID="has space" $R "$SB/ov.tfvars" audit-sink >/dev/null 2>&1; [ $? = 2 ] && ok "a project id that is not one word is refused" || bad "odd project id accepted"
out_ov="$(OVH_SINK_PROJECT_ID=0123abcd $R "$SB/ov.tfvars" audit-sink 2>&1)"
{ grep -q "audit-sink pair for ovh project 0123abcd" <<<"$out_ov" && grep -q "CANNOT be isolated per bucket" <<<"$out_ov" && ! grep -q '"Version"' <<<"$out_ov"; } \
  && ok "audit-sink on OVH with its own project: no bucket policy, the missing per-bucket isolation is stated, the project is named" || bad "OVH sink: $out_ov"
grep -q "aws s3api list-buckets" <<<"$out_ov" && ok "…and the proof that the pair reaches that one bucket only is printed" || bad "no list-buckets proof: $out_ov"
out_sv="$(OVH_SINK_PROJECT_ID=0123abcd $R "$SB/s.tfvars" audit-sink 2>&1)"
{ ! grep -q "0123abcd" <<<"$out_sv" && grep -q "audit-sink pair for scaleway (bucket" <<<"$out_sv"; } && ok "a sink that is not on OVH ignores the variable" || bad "non-OVH sink changed: $out_sv"
# The recipe attests, it cannot check: any one word passes. The one value it can know is wrong is the project of an OVH cluster whose sink is on OVH too
# (OS_PROJECT_ID is that cluster's own). On another cloud OS_PROJECT_ID is the operator's and may well be the sink's: it is not read there.
sed -E 's#^environment[[:space:]].*#environment = "dev"#; s#^cluster_name.*#cluster_name = "example"#' infrastructure/opentofu/cluster/envs/management-ovh.tfvars.example >"$SB/oc.tfvars"
printf '%s\n' 'audit_sink_placement = "same_provider_other_region"' 'audit_sink_endpoint = "https://s3.sbg.io.cloud.ovh.net"' 'audit_sink_region = "sbg"' >>"$SB/oc.tfvars"
out_oc="$(OS_PROJECT_ID=0123abcd OVH_SINK_PROJECT_ID=0123abcd $R "$SB/oc.tfvars" audit-sink 2>&1)"; rc_oc=$?
{ [ "$rc_oc" = 2 ] && grep -q "the cluster's own project" <<<"$out_oc"; } && ok "an OVH cluster's own project named as the sink's: refused (exit 2)" || bad "same project accepted: rc=$rc_oc $out_oc"
OS_PROJECT_ID=ffff9999 OVH_SINK_PROJECT_ID=0123abcd $R "$SB/oc.tfvars" audit-sink >/dev/null 2>&1; [ $? = 0 ] && ok "…another project on the same cloud passes" || bad "own project of the sink refused"
OS_PROJECT_ID=0123abcd OVH_SINK_PROJECT_ID=0123abcd $R "$SB/ov.tfvars" audit-sink >/dev/null 2>&1; [ $? = 0 ] && ok "…a cluster on another cloud: OS_PROJECT_ID is not read" || bad "OS_PROJECT_ID read for a cluster that is not on OVH"
$R "$SB/ov.tfvars" audit-sink-secondary >/dev/null 2>&1; [ $? = 2 ] && ok "audit-sink-secondary without a second sink is a usage error" || bad "secondary accepted"
{ cat "$SB/t.tfvars"; printf '%s\n' 'audit_sink_placement = "other_provider"' 'audit_sink_endpoint = "https://s3.fr-par.scw.cloud"' 'audit_sink_region = "gra"'; } >"$SB/bad.tfvars"
$R "$SB/bad.tfvars" audit-sink >/dev/null 2>&1; [ $? = 2 ] && ok "an incoherent sink choice is refused here too" || bad "incoherent sink accepted"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
