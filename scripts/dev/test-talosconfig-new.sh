#!/usr/bin/env bash
# ==============================================================================
# `task talosconfig-new` finds a control plane in a cloud cluster's state.
#
# It asked for `control_plane_ips`, an output only the Docker root declares, with
# no data dir and no S3 credentials, so every cloud lane stopped at "no node to
# ask". It also signs from the one admin talosconfig every cluster in the
# checkout shares, so it must be this cluster's. The real Taskfile and script
# run under the real go-task in a throwaway copy of the repository layout. tofu
# and talosctl are stubs, and the tofu stub answers only as the real one can:
# from a data dir `init` set up with S3 credentials, and only for an output that
# root declares.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

TASK="$(command -v task)" || { echo "✗ task is required and not on PATH — nothing was checked" >&2; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
C="$W/infrastructure/opentofu/cluster"; L="$W/infrastructure/opentofu-local"
mkdir -p "$C/envs" "$L" "$W/scripts"/{internal,ops,lib} "$W/bin" "$W/state"
cp Taskfile.yml "$W/"
cp scripts/ops/talosconfig-new.sh "$W/scripts/ops/"
cp scripts/lib/common.sh "$W/scripts/lib/"
cp scripts/internal/resolve-s3-cred.sh "$W/scripts/internal/"

# Each state's outputs, keyed by root and data dir (RFC 5737 addresses). Every
# cluster's admin talosconfig names its own context, so a config that came from
# another cluster's state can be told apart.
mkdir -p "$W/state/cluster/.terraform-management-scaleway" "$W/state/cluster/.terraform-workload-ovh" \
         "$W/state/opentofu-local/.terraform" "$L/.terraform"
echo '["192.0.2.10","192.0.2.11"]' >"$W/state/cluster/.terraform-management-scaleway/control_plane_private_ips"
echo '["192.0.2.20"]' >"$W/state/cluster/.terraform-workload-ovh/control_plane_private_ips"
echo '["192.0.2.30"]' >"$W/state/opentofu-local/.terraform/control_plane_ips"
for s in management-scaleway workload-ovh; do
  printf 'context: %s\nroles: os:admin\n' "$s" >"$W/state/cluster/.terraform-$s/talosconfig"
  echo "kubeconfig of $s" >"$W/state/cluster/.terraform-$s/kubeconfig"
done
: >"$L/.terraform/initialised"  # the Docker root keeps a local state

cat >"$W/bin/tofu" <<EOF
#!/usr/bin/env bash
for a; do case "\$a" in -chdir=*) cd "\${a#-chdir=}" || exit 1 ;; esac; done
D="\${TF_DATA_DIR:-.terraform}"
echo "tofu \$* dir=\$(basename "\$PWD") data=\$D ak=\${AWS_ACCESS_KEY_ID:-}" >>"$W/calls.log"
case " \$* " in
  *" init "*)
    [ -n "\${AWS_ACCESS_KEY_ID:-}" ] || { echo "Error: No valid credential sources found" >&2; exit 1; }
    mkdir -p "\$D" && : >"\$D/initialised" ;;
  *" output -json "*|*" output -raw "*)
    [ -f "\$D/initialised" ] || { echo 'Error: Backend initialization required, please run "tofu init"' >&2; exit 1; }
    f="$W/state/\$(basename "\$PWD")/\$(basename "\$D")/\${*: -1}"
    [ -f "\$f" ] || { echo "Error: Output \"\${*: -1}\" not found" >&2; exit 1; }
    cat "\$f" ;;
esac
EOF
cat >"$W/bin/talosctl" <<EOF
#!/usr/bin/env bash
echo "talosctl \$*" >>"$W/calls.log"
case "\$*" in
  "config info")
    [ -s "\${TALOSCONFIG:-}" ] || exit 1
    printf 'Current context:     fixture\nRoles:               %s\nCertificate expires: 8 hours from now\n' \
      "\$(sed -n 's/^roles: //p' "\$TALOSCONFIG")" ;;
  "-n "*" config new "*) printf 'context: %s\nroles: %s\n' "\$(sed -n 's/^context: //p' "\$TALOSCONFIG")" "\$7" >"\$5" ;;
  *) exit 1 ;;
esac
EOF
# Like the real one, it fails on a tfvars that does not exist.
printf '#!/usr/bin/env bash\necho "tf-backend.sh $*" >>%s/calls.log\n[ -f "$1" ] || { echo "tf-backend.sh: tfvars not found: $1" >&2; exit 1; }\necho -backend-config=path=fixture.tfstate\n' "$W" \
  >"$W/scripts/internal/tf-backend.sh"
chmod +x "$W/bin/tofu" "$W/bin/talosctl" "$W/scripts/internal/tf-backend.sh"
for e in management-scaleway workload-ovh; do echo 'cluster_name = "fixture"' >"$C/envs/$e.tfvars"; done
printf 'context: fixture\nroles: os:admin\n' >"$L/talosconfig"

O="$W/out"
run() { # <command...> — combined output in $O, calls in calls.log
  : >"$W/calls.log"; rm -f "$C"/talosconfig.reader "$L"/talosconfig.reader
  # What the last apply or `task kubeconfig` left: another cluster's admin config.
  printf 'context: left-by-another-cluster\nroles: os:admin\n' >"$C/talosconfig"
  echo 'kubeconfig of another cluster' >"$C/kubeconfig"
  env -i PATH="$W/bin:$PATH" HOME="$W" \
      TF_VAR_encryption_passphrase=fixture-passphrase-of-at-least-32-characters \
      SCW_ACCESS_KEY=scw-access-key SCW_SECRET_KEY=scw-secret-key \
      OVH_AWS_ACCESS_KEY_ID=ovh-access-key OVH_AWS_SECRET_ACCESS_KEY=ovh-secret-key \
      "$@" </dev/null >"$O" 2>&1
}
said() { grep -qF -- "$1" "$O"; }
logged() { grep -qF -- "$1" "$W/calls.log"; }
tail_of() { tail -n 3 "$O" | tr '\n' ' '; }


echo "--- a cloud lane: the node comes from this cluster's state ---"
run "$TASK" -d "$W" talosconfig-new PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && ok "talosconfig-new exits 0" || bad "talosconfig-new exits $rc: $(tail_of)"
logged 'tofu -chdir='"$C"' output -json control_plane_private_ips dir=cluster data=.terraform-management-scaleway ak=scw-access-key' \
  && ok "the state was read through management-scaleway's data dir, with Scaleway's S3 key" \
  || bad "the output was not read from management-scaleway's state: $(grep 'output' "$W/calls.log")"
logged 'talosctl -n 192.0.2.10 config new '"$C"'/talosconfig.reader --roles os:reader --crt-ttl 8h' \
  && said 'roles:   os:reader' \
  && ok "the first control plane was asked, and the reader config was issued" \
  || bad "no reader config from the first control plane: $(grep '^talosctl -n' "$W/calls.log")"
# The one admin file is shared by every cluster in the checkout, so the task has
# to refresh it from the state the node came from, or it signs for the wrong one.
grep -qx 'context: management-scaleway' "$C/talosconfig.reader" \
  && ok "the reader config was signed by management-scaleway's admin config" \
  || bad "the reader config came from: $(grep '^context' "$C/talosconfig.reader" 2>&1)"


echo "--- ROLE and PROVIDER pick the state ---"
# Both differ from the case above, so a hardcoded one cannot pass.
run "$TASK" -d "$W" talosconfig-new PROVIDER=ovh ROLE=workload; rc=$?
[ "$rc" = 0 ] && logged 'tf-backend.sh envs/workload-ovh.tfvars' \
  && logged 'data=.terraform-workload-ovh ak=ovh-access-key' && logged 'talosctl -n 192.0.2.20 ' \
  && ok "workload-ovh's backend, data dir, S3 key and control plane" \
  || bad "exit $rc; calls: $(tr '\n' ';' <"$W/calls.log")"
grep -qx 'context: workload-ovh' "$C/talosconfig.reader" \
  && ok "and signed by workload-ovh's admin config, not the previous cluster's" \
  || bad "the reader config came from: $(grep '^context' "$C/talosconfig.reader" 2>&1)"


echo "--- an exported TALOSCONFIG does not replace the one just fetched ---"
printf 'context: foreign\nroles: os:reader\n' >"$W/foreign.talosconfig"
run env TALOSCONFIG="$W/foreign.talosconfig" "$TASK" -d "$W" talosconfig-new PROVIDER=scaleway; rc=$?
[ "$rc" = 0 ] && grep -qx 'context: management-scaleway' "$C/talosconfig.reader" \
  && ok "the reader config is signed by this cluster's admin config, not the exported one" \
  || bad "rc=$rc; signed from: $(grep '^context' "$C/talosconfig.reader" 2>&1)"


echo "--- a cluster whose state names no control plane says what to do next ---"
mv "$W/state/cluster/.terraform-workload-ovh/control_plane_private_ips" "$W/ips.moved"
run "$TASK" -d "$W" talosconfig-new PROVIDER=ovh ROLE=workload; rc=$?
mv "$W/ips.moved" "$W/state/cluster/.terraform-workload-ovh/control_plane_private_ips"
[ "$rc" != 0 ] && said "no node to ask" \
  && said "Pass one:  $W/scripts/ops/talosconfig-new.sh ovh --node <control-plane private IP>" \
  && said "task tunnels-up PROVIDER=ovh [ROLE=workload]" \
  && ok "it names the node to pass, by absolute path, and the tunnels of this ROLE" \
  || bad "exit $rc; hints: $(tail_of)"


echo "--- a mistyped ROLE stops before anything runs ---"
# ROLE=os:reader is the likely slip, next to ROLES=. tf-backend.sh refuses the
# missing tfvars; a bare `tofu init` after that would open some other backend.
run "$TASK" -d "$W" talosconfig-new PROVIDER=scaleway ROLE=os:reader; rc=$?
[ "$rc" != 0 ] && ! logged 'tofu init' && said 'tfvars not found' \
  && ok "exit $rc, the refusal is printed, and tofu never ran" \
  || bad "exit $rc; calls: $(tr '\n' ';' <"$W/calls.log")"
grep -qx 'context: left-by-another-cluster' "$C/talosconfig" && grep -qx 'kubeconfig of another cluster' "$C/kubeconfig" \
  && ok "no kubeconfig or talosconfig was overwritten" \
  || bad "a file was touched: $(head -c 60 "$C/kubeconfig" 2>&1)"


echo "--- the Docker lane keeps its own output name ---"
run "$W/scripts/ops/talosconfig-new.sh" local; rc=$?
[ "$rc" = 0 ] && logged 'output -json control_plane_ips dir=opentofu-local' && logged 'talosctl -n 192.0.2.30 ' \
  && ok "the Docker root's control_plane_ips still answers" \
  || bad "exit $rc: $(tail_of)"


echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
