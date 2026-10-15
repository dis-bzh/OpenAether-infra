#!/usr/bin/env bash
# Escrow of what the day OpenBao is lost cannot do without: the seal key, the recovery shares and the restic password.
# Without the first, every secret and every raft snapshot is unreadable; without the last, the backups are. Nothing in
# the cluster can escrow them for you, and nothing noticed a forgotten escrow (ANSSI GH-M37-5, RW-PRA-1, B2 recovery rule).
#
#   export   read the three items from the cluster, encrypt the seal key and the restic password to at least TWO
#            distinct OpenPGP keys, copy the (already PGP-encrypted) recovery shares, write a non-secret receipt.
#   verify   open the escrow with a key this machine holds (or a key reconstructed from a split: --key-file) and
#            compare hashes with the receipt AND with the live cluster. An escrow nobody has opened is a hope.
#   attest   verify, and only then write what `cluster-security` check 4.7 and the apps CronJob `openbao-escrow-check`
#            read: the ConfigMap `openbao-escrow-ack` and the annotation `openaether.io/escrowed-at` (apps vault README, Day 0).
#
# Nothing secret is printed, put on a command line or written unencrypted: the key travels as base64 in a shell variable
# and through pipes. The output directory is refused inside a git work tree. Several recipients means ANY ONE can decrypt
# (it survives losing a person, not one leak); a k-of-n split is the apps README's other option and is not done here.
#
# Usage: escrow-openbao.sh export --out DIR (-r KEYID)... | --recipients-from-tfvars FILE
#        escrow-openbao.sh verify --from DIR [--key-file RAW_KEY]
#        escrow-openbao.sh attest --from DIR [--key-file RAW_KEY] [--holders N]
#        KUBECONFIG (default: the cluster directory's); OA_ESCROW_ALLOW_DEV=1 lets export run on a development bootstrap.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS=foundation-vault
export KUBECONFIG="${KUBECONFIG:-$ROOT/infrastructure/opentofu/cluster/kubeconfig}"
RECEIPT=escrow-receipt.json
TMP=""

die() { echo "✗ $*" >&2; exit "${2:-2}"; }
usage() { sed -n '/^# Usage:/,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//' >&2; exit 2; }
sha() { sha256sum | cut -d' ' -f1; }

for t in gpg kubectl jq base64 sha256sum; do command -v "$t" >/dev/null || die "$t is required"; done
[ $# -ge 1 ] || usage
ACTION="$1"; shift
OUT=""; FROM=""; KEYFILE=""; HOLDERS=""; TFVARS=""; RECIPIENTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    --from) FROM="${2:?--from needs a directory}"; shift 2 ;;
    -r|--recipient) RECIPIENTS+=("${2:?-r needs a key id}"); shift 2 ;;
    --recipients-from-tfvars) TFVARS="${2:?needs a file}"; shift 2 ;;
    --key-file) KEYFILE="${2:?--key-file needs a file}"; shift 2 ;;
    --holders) HOLDERS="${2:?--holders needs a number}"; shift 2 ;;
    *) usage ;;
  esac
done

# --- Reads from the cluster ---------------------------------------------------------------------------------------------

secret_field() { kubectl -n "$NS" get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null; }

# One KV field through the pod, as `openaether-admin`: the ServiceAccount token is exchanged for an OpenBao token INSIDE the
# pod, so no OpenBao token ever crosses this terminal (the `bao_admin` helper of docs/admin-access.md, with the token on stdin).
# shellcheck disable=SC2016  # the $ are for the remote shell
bao_read() { # <path> <field>
  local jwt
  jwt="$(kubectl -n "$NS" create token openaether-admin --duration=10m 2>/dev/null)" && [ -n "$jwt" ] || return 1
  printf '%s\n' "$jwt" | kubectl -n "$NS" exec -i openbao-0 -- sh -c '
read -r jwt || exit 4
BAO_TOKEN="$(printf "%s" "$jwt" | bao write -field=token auth/kubernetes/login role=openaether-admin jwt=-)" || exit 3
export BAO_TOKEN
exec bao kv get -mount=secret -field="$2" "$1"' sh "$1" "$2"
}

# Fingerprints of the primary keys the recipients resolve to. Two names for one key, or one key twice, are ONE custodian.
fingerprints() { awk -F: '$1 == "pub" {p = 1; next} p && $1 == "fpr" {print $10; p = 0}'; }

live_seal_b64() { secret_field openbao-seal-key key; }
b64_sha() { printf '%s' "$1" | base64 -d | sha; }

# The directory is as secret as what is in it: refuse a git work tree (one `git add` from public).
refuse_git_tree() {
  local d="$1"
  while [ ! -d "$d" ]; do d="$(dirname "$d")"; done
  if command -v git >/dev/null && [ "$(git -C "$d" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
    die "$1 is inside a git work tree: escrow files must live outside any repository"
  fi
}

# --- export -------------------------------------------------------------------------------------------------------------

do_export() {
  [ -n "$OUT" ] || usage
  if [ -n "$TFVARS" ] && [ "${#RECIPIENTS[@]}" -gt 0 ]; then die "give -r or --recipients-from-tfvars, not both"; fi
  [ -n "$TFVARS" ] || [ "${#RECIPIENTS[@]}" -gt 0 ] || die "no recipient: -r KEYID (twice or more) or --recipients-from-tfvars FILE"
  refuse_git_tree "$OUT"
  if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then die "$OUT is not empty: a new escrow goes to a new directory"; fi

  kubectl -n "$NS" get secret openbao-seal-key >/dev/null 2>&1 || die "no Secret openbao-seal-key in $NS (static seal not in use, or the cluster is not reachable: KUBECONFIG, tunnels)"
  if kubectl -n "$NS" get secret openbao-recovery-dev >/dev/null 2>&1 && [ "${OA_ESCROW_ALLOW_DEV:-}" != 1 ]; then
    die "this is a development bootstrap (openbao-recovery-dev): there is nothing worth escrowing, and it cannot become a production cluster"
  fi

  # Recipients: from the operator's keyring, or from the PGP keys of the tfvars (imported into a throw-away keyring).
  local enc_home="" fprs=() f
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  if [ -n "$TFVARS" ]; then
    [ -f "$TFVARS" ] || die "no $TFVARS"
    enc_home="$TMP/gnupg"; mkdir -m 700 "$enc_home"
    # The base64 strings inside `openbao_recovery_pgp_keys = [ ... ]` (the same extraction as check-openbao-keys.sh).
    awk '/^[[:space:]]*openbao_recovery_pgp_keys[[:space:]]*=/ {on = 1} on {sub(/#.*/, ""); print} on && /\]/ {on = 0}' "$TFVARS" |
      grep -oE '"[A-Za-z0-9+/]{100,}={0,2}"' | tr -d '"' |
      while IFS= read -r k; do printf '%s' "$k" | base64 -d | GNUPGHOME="$enc_home" gpg --batch --quiet --import 2>/dev/null; done
    mapfile -t fprs < <(GNUPGHOME="$enc_home" gpg --batch --with-colons --fingerprint --list-keys 2>/dev/null | fingerprints | sort -u)
  else
    for f in "${RECIPIENTS[@]}"; do
      local found; found="$(gpg --batch --with-colons --fingerprint --list-keys -- "$f" 2>/dev/null | fingerprints)"
      [ "$(grep -c . <<<"$found")" = 1 ] || die "recipient '$f' matches $(grep -c . <<<"$found") keys in your keyring: give a fingerprint"
      fprs+=("$found")
    done
    mapfile -t fprs < <(printf '%s\n' "${fprs[@]}" | sort -u)
  fi
  [ "${#fprs[@]}" -ge 2 ] || die "$(( ${#fprs[@]} )) distinct custodian key(s): an escrow needs at least two (one person's laptop is one point of loss and one leak)"

  gpg_enc() { # <output file> — stdin is encrypted to every custodian
    local a=(--batch --yes --trust-model always --output "$1" --encrypt) r
    for r in "${fprs[@]}"; do a+=(--recipient "$r"); done
    if [ -n "$enc_home" ]; then GNUPGHOME="$enc_home" gpg "${a[@]}"; else gpg "${a[@]}"; fi
  }

  umask 077
  mkdir -p "$OUT" || die "cannot create $OUT"
  chmod 700 "$OUT"

  local seal restic shares_json receipt_files='{}' share_files='[]' name key n
  seal="$(live_seal_b64)"; [ -n "$seal" ] || die "the seal key Secret has no data.key"
  printf '%s' "$seal" | base64 -d | gpg_enc "$OUT/openbao-seal-key.gpg" 2>/dev/null || die "could not encrypt the seal key"

  restic="$(bao_read backup/restic password)" && [ -n "$restic" ] || die "could not read secret/backup/restic through the pod (is OpenBao unsealed and the bootstrap done?)"
  printf '%s' "$restic" | gpg_enc "$OUT/restic-password.gpg" 2>/dev/null || die "could not encrypt the restic password"

  # The recovery shares are PGP-encrypted to the operators already (one decode gives the text the break-glass runbook decodes again).
  if shares_json="$(kubectl -n "$NS" get secret openbao-recovery-shares -o json 2>/dev/null)"; then
    for key in $(jq -r '.data // {} | keys[] | select(test("^share-[0-9]+$"))' <<<"$shares_json"); do
      n="${key#share-}"; name="openbao-share-$n.b64"
      jq -r --arg k "$key" '.data[$k]' <<<"$shares_json" | base64 -d >"$OUT/$name"
      share_files="$(jq -c --arg f "$name" --arg h "$(sha <"$OUT/$name")" '. + [{file:$f, sha256:$h}]' <<<"$share_files")"
    done
  else
    echo "⚠ no Secret openbao-recovery-shares: the shares are not in this escrow (copy them from wherever they were kept)" >&2
  fi
  receipt_files="$(jq -nc --arg a "$(sha <"$OUT/openbao-seal-key.gpg")" --arg b "$(sha <"$OUT/restic-password.gpg")" \
    '{"openbao-seal-key.gpg":$a,"restic-password.gpg":$b}')"

  # Non-secret: the hashes only let an operator compare something reconstructed with what the cluster holds.
  jq -n --arg at "$(date -u +%FT%TZ)" --arg seal "$(b64_sha "$seal")" --arg restic "$(printf '%s' "$restic" | sha)" \
        --argjson files "$receipt_files" --argjson shares "$share_files" \
        --argjson recipients "$(printf '%s\n' "${fprs[@]}" | jq -R . | jq -sc .)" \
    '{format:1, escrowed_at:$at, seal_key_sha256:$seal, restic_password_sha256:$restic, recipients:$recipients,
      holders:($recipients|length), files:$files, recovery_shares:$shares}' >"$OUT/$RECEIPT"

  echo "✓ escrow written to $OUT: openbao-seal-key.gpg, restic-password.gpg, ${#fprs[@]} custodian key(s), $(jq '.recovery_shares|length' "$OUT/$RECEIPT") recovery share(s), $RECEIPT"
  printf '  custodian %s\n' "${fprs[@]}"
  echo "  Compare each fingerprint with the one its owner holds: --trust-model always was used (the keys are the ones you named)."
  echo "  Any ONE of them opens the seal key and the restic password. Next: copy the directory to its places (not the cluster, not a repository),"
  echo "  then PROVE it: escrow-openbao.sh verify --from $OUT (each custodian on their own machine), then attest --from $OUT."
}

# --- verify / attest ----------------------------------------------------------------------------------------------------

# Returns 0 only when the seal key reconstructed from the escrow IS the live one and nothing else disagrees.
do_verify() {
  [ -n "$FROM" ] || usage
  local r="$FROM/$RECEIPT" bad=0 want got live seal restic_want
  [ -f "$r" ] || die "no $r (export first)"
  jq -e '.format == 1 and (.seal_key_sha256|test("^[0-9a-f]{64}$"))' "$r" >/dev/null 2>&1 || die "$r is not a receipt of this tool"
  want="$(jq -r .seal_key_sha256 "$r")"

  # 1. the seal key, from the escrow alone
  if [ -n "$KEYFILE" ]; then
    [ -f "$KEYFILE" ] || die "no $KEYFILE"
    got="$(sha <"$KEYFILE")"
  else
    got="$(gpg --quiet --decrypt "$FROM/openbao-seal-key.gpg" 2>/dev/null | sha)"
    [ "$got" != "$(printf '' | sha)" ] || { echo "✗ this machine cannot open $FROM/openbao-seal-key.gpg: none of its keys is a custodian's (or the file is damaged)" >&2; return 1; }
  fi
  seal="$(live_seal_b64)"; [ -n "$seal" ] || die "cannot read the live seal key (KUBECONFIG, tunnels)"
  live="$(b64_sha "$seal")"
  if [ "$got" != "$want" ]; then
    echo "✗ MISMATCH: what the escrow opens to is not what its receipt says (damaged, or not the key of this receipt); nothing attested" >&2; bad=1
  elif [ "$got" != "$live" ]; then
    echo "✗ MISMATCH: the escrow opens to a key that is NOT the live seal key (rotated since? re-run export); nothing attested" >&2; bad=1
  else
    echo "✓ seal key: reconstructed from the escrow, same sha256 as the live Secret"
  fi

  # 2. the restic password (information: the cluster check is about the seal key)
  restic_want="$(jq -r .restic_password_sha256 "$r")"
  if got="$(gpg --quiet --decrypt "$FROM/restic-password.gpg" 2>/dev/null)" && [ -n "$got" ]; then
    if [ "$(printf '%s' "$got" | sha)" != "$restic_want" ]; then echo "✗ MISMATCH: restic-password.gpg is not what its receipt says" >&2; bad=1
    elif live="$(bao_read backup/restic password)" && [ -n "$live" ]; then
      if [ "$(printf '%s' "$live" | sha)" = "$restic_want" ]; then echo "✓ restic password: escrow opens, same as secret/backup/restic"
      else echo "✗ MISMATCH: secret/backup/restic changed since the escrow (rotated? re-run export)" >&2; bad=1; fi
    else echo "⚠ restic password: escrow opens and matches its receipt; the live value could not be read to compare" >&2; fi
  else
    echo "⚠ restic password: this machine cannot open restic-password.gpg (a key reconstructed from a split proves the seal key only)" >&2
  fi

  # 3. the recovery shares: copies of what the Secret holds
  local line f h shares_json
  if shares_json="$(kubectl -n "$NS" get secret openbao-recovery-shares -o json 2>/dev/null)"; then
    while IFS= read -r line; do
      f="$(jq -r .file <<<"$line")"; h="$(jq -r .sha256 <<<"$line")"
      if [ -f "$FROM/$f" ] && [ "$(sha <"$FROM/$f")" = "$h" ] &&
         [ "$(jq -r --arg k "share-$(sed -E 's/^openbao-share-([0-9]+)\.b64$/\1/' <<<"$f")" '.data[$k] // empty' <<<"$shares_json" | base64 -d | sha)" = "$h" ]; then
        echo "✓ $f: present, same as the live Secret"
      else echo "✗ $f: missing, altered, or different from the live Secret" >&2; bad=1; fi
    done < <(jq -c '.recovery_shares[]' "$r")
  fi
  return "$bad"
}

do_attest() {
  [ -n "$FROM" ] || usage
  do_verify || die "verification failed: nothing attested" 1
  local r="$FROM/$RECEIPT" holders sha_now
  holders="${HOLDERS:-$(jq -r .holders "$r")}"
  [[ "$holders" =~ ^[0-9]+$ ]] && [ "$holders" -ge 2 ] || die "holders must be an integer >= 2 (a single custodian is a single point of loss); got '$holders'" 1
  sha_now="$(jq -r .seal_key_sha256 "$r")"
  # The same two records as the Day 0 step 5 of the apps vault README: the ConfigMap the CronJob reads, the annotation check 4.7 reads.
  kubectl -n "$NS" create configmap openbao-escrow-ack --from-literal=escrowed-at="$(date -u +%F)" \
    --from-literal=seal-key-sha256="$sha_now" --from-literal=holders="$holders" --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null || die "could not write the ConfigMap openbao-escrow-ack" 1
  kubectl -n "$NS" annotate secret openbao-seal-key openaether.io/escrowed-at="$(date -u +%FT%TZ)" --overwrite >/dev/null ||
    die "could not annotate openbao-seal-key" 1
  echo "✓ attested: ConfigMap openbao-escrow-ack ($holders holders) and the annotation on openbao-seal-key"
  echo "  This is the operator's word backed by a hash, not a proof that every custodian can open their copy: have each one run verify."
  echo "  Redo export + attest after every seal-key rotation (the rotation runbook deletes both records)."
}

case "$ACTION" in
  export) do_export ;;
  verify) do_verify ;;
  attest) do_attest ;;
  *) usage ;;
esac
