#!/usr/bin/env bash
# Issue a SHORT-LIVED, NAMED Kubernetes client credential through the CertificateSigningRequest API.
#
# The kubeconfig the deploy hands out is a shared O=system:masters certificate: it bypasses RBAC, names nobody in the
# API audit log and cannot be revoked (docs/admin-access.md). This mints one for a person instead: CN=<name>, O=oa:readers
# (read-only, the default) or O=oa:admins (cluster-admin, explicit --role admin), valid hours. What the group may do is
# decided by the platform-rbac bindings of the apps repository (oa-admins -> cluster-admin, oa-readers -> view).
# Revoking a person before the certificate expires = delete the binding that names the group, or let it expire.
#
# The admin kubeconfig (KUBECONFIG, as `task kubeconfig` wrote it) is used ONLY to create and approve the request; the
# private key is generated here and never leaves this machine. It stays the escrowed break-glass credential.
#
# Usage: kubeconfig-new.sh <name> [--role reader|admin] [--ttl 8h] [--out PATH]
#   --ttl   600s..24h (units s, m, h); default 8h. The signer may cap it; the script reports what it got.
#   --out   default ~/.kube/oa-<name>-<role>.kubeconfig, mode 0600; a path inside this repository is refused
#           (the artifact backups and CI collect from there).
set -euo pipefail

USAGE='usage: kubeconfig-new.sh <name> [--role reader|admin] [--ttl 8h] [--out PATH]'
NAME="${1:?$USAGE}"
shift
ROLE="reader"; TTL="8h"; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:?$USAGE}"; shift 2 ;;
    --ttl)  TTL="${2:?$USAGE}";  shift 2 ;;
    --out)  OUT="${2:?$USAGE}";  shift 2 ;;
    *) echo "✗ unknown argument: $1" >&2; exit 2 ;;
  esac
done

# A name that is not a plain label could carry a "system:" prefix or break the subject line.
if ! [[ "$NAME" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; then
  echo "✗ name '$NAME': lower-case letters, digits, '.', '_' and '-', starting with a letter or digit" >&2; exit 2
fi
case "$ROLE" in
  reader) GROUP="oa:readers" ;;
  admin)  GROUP="oa:admins" ;;
  *) echo "✗ --role is reader or admin, not '$ROLE'" >&2; exit 2 ;;
esac

# TTL in seconds. 600 is the signer's own floor; 24h is the cap here so this cannot become the new year-long file.
if ! [[ "$TTL" =~ ^([0-9]+)([smh])$ ]]; then echo "✗ --ttl '$TTL': a number and s, m or h (8h, 90m)" >&2; exit 2; fi
case "${BASH_REMATCH[2]}" in s) MULT=1 ;; m) MULT=60 ;; h) MULT=3600 ;; esac
SECS=$((BASH_REMATCH[1] * MULT))
if [ "$SECS" -lt 600 ] || [ "$SECS" -gt 86400 ]; then
  echo "✗ --ttl $TTL = ${SECS}s: it must be between 600s (10m) and 86400s (24h)" >&2; exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${OUT:-${HOME:?}/.kube/oa-${NAME}-${ROLE}.kubeconfig}"
# No GNU realpath -m / base64 -w0 / date -d below: operators also run this on macOS (BSD userland).
case "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$OUT")" in
  "$ROOT"/*) echo "✗ $OUT is inside the repository, where CI and the artifact backups collect: pick a path outside" >&2; exit 2 ;;
esac

for t in kubectl openssl jq base64 python3; do command -v "$t" >/dev/null 2>&1 || { echo "✗ $t not found" >&2; exit 2; }; done
# The admin kubeconfig: needed for the server, its CA, and the CSR calls.
CFG="$(kubectl config view --raw --minify -o json 2>/dev/null)" \
  || { echo "✗ no usable admin kubeconfig: set KUBECONFIG (task kubeconfig-new does)" >&2; exit 1; }
SERVER="$(jq -r '.clusters[0].cluster.server // empty' <<<"$CFG")"
CA="$(jq -r '.clusters[0].cluster["certificate-authority-data"] // empty' <<<"$CFG")"
CLUSTER_NAME="$(jq -r '.clusters[0].name // "openaether"' <<<"$CFG")"
if [ -z "$SERVER" ] || [ -z "$CA" ]; then
  echo "✗ the admin kubeconfig has no server or no embedded CA: nothing to build the new one from" >&2; exit 1
fi

b64() { base64 | tr -d '\n'; }
umask 077
WORK="$(mktemp -d)"
CSR="oa-${NAME}-$(date -u +%s)"
cleanup() { kubectl delete csr "$CSR" --ignore-not-found >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/key.pem" 2>/dev/null
openssl req -new -key "$WORK/key.pem" -subj "/O=${GROUP}/CN=${NAME}" -out "$WORK/req.csr"

kubectl create -f - >/dev/null <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR}
spec:
  request: $(b64 <"$WORK/req.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${SECS}
  usages: ["client auth"]
YAML
kubectl certificate approve "$CSR" >/dev/null
kubectl wait --for=jsonpath='{.status.certificate}' "csr/$CSR" --timeout=60s >/dev/null \
  || { echo "✗ the request $CSR was not signed within 60 s (is the controller-manager signing kube-apiserver-client requests?)" >&2; exit 1; }
kubectl get csr "$CSR" -o jsonpath='{.status.certificate}' | base64 -d >"$WORK/crt.pem"

# Report what the signer granted, not what was asked: it may clamp the duration.
END="$(openssl x509 -in "$WORK/crt.pem" -noout -enddate | sed 's/^notAfter=//')"
LEFT="$(LC_ALL=C python3 -c 'import sys,time,calendar; print(calendar.timegm(time.strptime(sys.argv[1], "%b %d %H:%M:%S %Y %Z")) - int(time.time()))' "$END")"
[[ "$LEFT" =~ ^-?[0-9]+$ ]] || { echo "✗ cannot read the certificate expiry '$END'" >&2; exit 1; }
if [ "$LEFT" -gt $((SECS + 120)) ]; then
  echo "✗ the signer granted ${LEFT}s, more than the ${SECS}s asked: not using it (a cluster-signing-duration or a signer that ignores expirationSeconds)" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
: >"$OUT"; chmod 0600 "$OUT"
cat >"$OUT" <<YAML
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
users:
- name: ${NAME}
  user:
    client-certificate-data: $(b64 <"$WORK/crt.pem")
    client-key-data: $(b64 <"$WORK/key.pem")
contexts:
- name: ${NAME}@${CLUSTER_NAME}
  context: {cluster: ${CLUSTER_NAME}, user: ${NAME}}
current-context: ${NAME}@${CLUSTER_NAME}
YAML

printf '✓ %s\n  identity: %s  group: %s\n  expires:  %s (%ss left)\n  use it:   KUBECONFIG=%s kubectl auth whoami\n' \
  "$OUT" "$NAME" "$GROUP" "$END" "$LEFT" "$OUT"
[ "$ROLE" = admin ] && echo "  note:     cluster-admin through the group; the apps platform-rbac brick must be reconciled, or this certificate can do nothing"
exit 0
