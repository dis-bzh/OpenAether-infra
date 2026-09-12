#!/usr/bin/env bash
# Drive a local Feint emulator (Scaleway / Outscale APIs, no account, no bill).
#
# What the emulated lane proves and what it does not: docs/emulated-cloud.md.
#
# Usage: feint.sh install|start|stop|status|guard [endpoint]
#        feint.sh plan|apply|apply-root|record scaleway|outscale
#        feint.sh evidence|evidence-baseline|evidence-verify scaleway|outscale
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# renovate: datasource=github-releases depName=stephrobert/feint extractVersion=^v(?<version>.*)$
FEINT_VERSION="0.13.0"
FEINT_ENDPOINT="${FEINT_ENDPOINT:-http://127.0.0.1:4599}"
BIN_DIR="${FEINT_BIN_DIR:-$HOME/.local/bin}"
# Off (metadata-only machines) unless a caller asks for a real one — the
# evidence lane sets this to "incus", nothing else needs to.
FEINT_VM="${FEINT_VM:-}"

# feint_cli runs the emulator's own lifecycle commands (start/stop/status): a
# machine runtime means Incus, whose socket belongs to root:incus-admin, and a
# group granted mid-job never reaches the runner's already-running session —
# so root is how feint's own CI runs it too. Resolved to an absolute path
# first: sudo's secure_path does not carry $BIN_DIR when that is a user
# install (~/.local/bin).
feint_cli() {
  if [ -n "$FEINT_VM" ]; then
    sudo "$(command -v feint)" "$@"
  else
    feint "$@"
  fi
}

# --- The guard --------------------------------------------------------------
# Refuse anything that is not this machine. Every official cloud client falls
# back to the operator's stored credentials when the environment says nothing,
# so a redirection that quietly evaluates to empty does not fail — it bills.
# Feint's own repository shipped that bug and created a paying server with it.
guard_local() {
  case "${1:-}" in
    http://127.0.0.1:* | http://localhost:* | http://\[::1\]:*) return 0 ;;
    "") echo "✗ no endpoint given; refusing to run a client that would find its own" >&2 ;;
    *) echo "✗ endpoint ${1} is not local; this lane drives an emulator, never a real cloud" >&2 ;;
  esac
  exit 1
}

addr_of() { printf '%s' "${1#http://}"; }

# running answers whether the emulator is actually listening. `feint status`
# exits 0 whether or not it is, so the output is the only signal.
running() { feint_cli status 2>/dev/null | grep -q '^running on'; }

# require_emulator fails a lane that has nothing to talk to.
#
# Without it these lanes go green with the emulator down — the plan lane makes
# almost no API calls, so it passes either way. A check that cannot fail is a
# check that measures nothing, and it hid a broken `feint-up` for exactly one run.
require_emulator() {
  running && return 0
  echo "✗ no emulator on $FEINT_ENDPOINT" >&2
  # "run 'task feint-up' first" was the whole message, and it named the wrong
  # cause every time the emulator had started and then DIED — which is the only
  # way this fires in CI, where feint-up is a separate step that prints a pid.
  # The one thing that could explain it, the emulator's own log, was discarded.
  # Observed 2026-08-17: the outscale leg planned successfully, then found no
  # emulator at the apply, and nothing in the run said why.
  emulator_log_hint
  exit 1
}

# emulator_log_hint prints the emulator's own log so "why" survives past the
# process that could have answered it directly. Shared by require_emulator and
# reset_emulator's failure path.
emulator_log_hint() {
  local log="${XDG_RUNTIME_DIR:-/tmp}/feint/${FEINT_ENDPOINT#http://}/feint.log"
  log="${log//:/_}"
  if [ -r "$log" ]; then
    echo "  Last lines of ${log}:" >&2
    tail -20 "$log" | sed 's/^/    /' >&2
  else
    echo "  no log at ${log} either — if it never started, run 'task feint-up' first." >&2
  fi
}

# poll_running waits up to FEINT_RESTART_TIMEOUT seconds for the emulator to
# actually answer `status`. `feint start` returning — even after its own
# "listening on ..." line — does not mean the status endpoint is already up:
# a restart inside reset_emulator raced this on a GitHub-hosted runner and
# failed CI once with no code change involved, passing again on an unmodified
# re-run (#169). Integer sleep only: feint also ships Darwin binaries, and
# BSD sleep does not accept a fractional argument.
FEINT_RESTART_TIMEOUT="${FEINT_RESTART_TIMEOUT:-10}"
poll_running() {
  local deadline=$((SECONDS + FEINT_RESTART_TIMEOUT))
  until running; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

# reset_emulator empties the store, which only a restart does: the store is in
# memory (no --state), and `feint clean` is not the verb — it sweeps an Incus
# machine runtime and simply fails when no Incus daemon answers. Without a reset
# a lane inherits the previous one's resources and dies on 409 at the first
# create, long before reaching the operations it was meant to measure.
reset_emulator() {
  local vm_args=()
  [ -n "$FEINT_VM" ] && vm_args=(--vm "$FEINT_VM")
  feint_cli stop >/dev/null 2>&1 || true
  feint_cli start --addr "$(addr_of "$FEINT_ENDPOINT")" "${vm_args[@]}" >/dev/null
  poll_running || {
    echo "✗ the emulator did not come back on $FEINT_ENDPOINT within ${FEINT_RESTART_TIMEOUT}s" >&2
    emulator_log_hint
    exit 1
  }
}

# emulated_env clears every credential a provider could pick up on its own.
#
# Both lanes pin fake credentials in their provider blocks, but an ambient
# SCW_ACCESS_KEY still reaches the SDK and wins: leaving one set fails the run
# with "invalid access key format" at best, and at worst means a lane nobody can
# prove ran without credentials. The point of this lane is that none is needed,
# so none may be in scope.
emulated_env() {
  unset SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_PROJECT_ID SCW_DEFAULT_ORGANIZATION_ID
  unset SCW_DEFAULT_REGION SCW_DEFAULT_ZONE SCW_API_URL SCW_PROFILE
  unset OSC_ACCESS_KEY OSC_SECRET_KEY OSC_REGION OUTSCALE_ACCESS_KEY_ID OUTSCALE_SECRET_KEY
  export TF_DATA_DIR=.terraform-feint TF_IN_AUTOMATION=1 TF_INPUT=0
}

# --- Commands ---------------------------------------------------------------
install_feint() {
  if command -v feint >/dev/null 2>&1 && [ "$(feint version)" = "v${FEINT_VERSION}" ]; then
    echo "feint v${FEINT_VERSION} already installed"
    return 0
  fi
  local base asset tmp
  base="https://github.com/stephrobert/feint/releases/download/v${FEINT_VERSION}"
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset=feint-linux-amd64 ;;
    Linux-aarch64) asset=feint-linux-arm64 ;;
    Darwin-x86_64) asset=feint-darwin-amd64 ;;
    Darwin-arm64) asset=feint-darwin-arm64 ;;
    *) echo "✗ no published feint binary for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL -o "$tmp/$asset" "$base/$asset"
  curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"
  # --ignore-missing: the file lists every platform, and without it the check
  # fails on the ones we did not download — which reads like a bad binary.
  (cd "$tmp" && sha256sum -c checksums.txt --ignore-missing)
  mkdir -p "$BIN_DIR"
  install -m 0755 "$tmp/$asset" "$BIN_DIR/feint"
  echo "installed feint v${FEINT_VERSION} → $BIN_DIR/feint"
}

# The Terraform provider resolves `image_name` through a real name lookup —
# `data.scaleway_instance_image.talos` in modules/providers/scw/main.tf, whose
# `count` is 0 whenever `image_id` is set. Every feint tfvars used to pin
# `image_id` instead, so that data source never actually ran. Feint 0.7.0
# declined `instance/v1 ListImages` outright (501); 0.12.0 serves it, along with
# CreateSnapshot and CreateImage — none declined, and CreateImage enforces a
# real dependency (a made-up snapshot id gets a genuine 404, not a rubber
# stamp). So a name can now be made to resolve to something real: create a
# throwaway volume, snapshot it, and register an image under the name
# `envs/feint-scaleway.tfvars.example` asks for. See issue #150.
SCW_FEINT_IMAGE_NAME="talos-openaether-feint"
# The fixed project the emulated `scaleway` provider block pins
# (infrastructure/opentofu/cluster/main.tf, local.emulator_creds.scw_project_id).
SCW_FEINT_PROJECT_ID="11111111-1111-1111-1111-111111111111"

register_scaleway_image() {
  local endpoint="$1" zone="fr-par-1" images_url vol_id snap_id
  images_url="$endpoint/instance/v1/zones/$zone/images"

  # Idempotent: a second call against an emulator that already served the
  # first one must not mint a duplicate image under the same name.
  if curl -sf "$images_url?name=$SCW_FEINT_IMAGE_NAME" \
    | grep -q "\"name\":\"$SCW_FEINT_IMAGE_NAME\""; then
    return 0
  fi

  vol_id="$(curl -sf -X POST "$endpoint/instance/v1/zones/$zone/volumes" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${SCW_FEINT_IMAGE_NAME}-src\",\"volume_type\":\"l_ssd\",\"size\":10000000000,\"project_id\":\"$SCW_FEINT_PROJECT_ID\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["volume"]["id"])')"

  snap_id="$(curl -sf -X POST "$endpoint/instance/v1/zones/$zone/snapshots" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${SCW_FEINT_IMAGE_NAME}-snap\",\"volume_id\":\"$vol_id\",\"project_id\":\"$SCW_FEINT_PROJECT_ID\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["snapshot"]["id"])')"

  curl -sf -X POST "$images_url" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$SCW_FEINT_IMAGE_NAME\",\"root_volume\":\"$snap_id\",\"arch\":\"x86_64\",\"project_id\":\"$SCW_FEINT_PROJECT_ID\"}" \
    >/dev/null

  echo "  registered image '$SCW_FEINT_IMAGE_NAME' — image_name now resolves to something the emulator actually created"
}

# plan_root runs `tofu plan` on the REAL cluster root against the emulator.
#
# That root declares a partial S3 backend, and `init -backend=false` then leaves
# `plan` refusing to run at all — which is why `task validate` stops at validate.
# An override file replaces the backend for the duration (OpenTofu: a backend
# block in an override file always takes precedence), and the trap removes it:
# left behind, it would silently send a real apply's state to a local file.
plan_root() {
  local provider="$1" root="$REPO_ROOT/infrastructure/opentofu/cluster"
  local example="$root/envs/feint-${provider}.tfvars.example"
  # Globals, not locals: the EXIT trap fires after this function has returned,
  # and a local would be unbound by then — the cleanup would die instead of run.
  override="$root/zz-feint-backend_override.tf"

  [ -f "$example" ] || { echo "✗ no such lane: $example" >&2; exit 1; }
  [ -e "$override" ] && { echo "✗ $override already exists; refusing to overwrite it" >&2; exit 1; }

  work="$(mktemp -d)"
  trap 'rm -f "${override:-}"; rm -rf "${work:-}"' EXIT

  cat > "$override" <<EOT
# Generated by scripts/dev/feint.sh, removed when it exits. If you are reading
# this in a working tree, a run died hard — delete it.
terraform {
  backend "local" {
    path = "$work/feint.tfstate"
  }
}
EOT
  cp "$example" "$work/feint.tfvars"

  [ "$provider" = scaleway ] && register_scaleway_image "$FEINT_ENDPOINT"

  emulated_env
  export TF_VAR_encryption_passphrase="feint-emulated-lane-passphrase-not-a-secret"

  cd "$root"
  tofu init -no-color -reconfigure
  tofu validate -no-color
  tofu plan -no-color -var-file="$work/feint.tfvars" -var "emulator_api_url=$FEINT_ENDPOINT"
  echo "✓ ${provider}: the real cluster root planned against the emulator, no credentials"
}

# apply_root runs the untargeted create/empty-replan/destroy cycle on the REAL
# cluster root (Phase 1: talos_bootstrap=false, already the setting in both
# envs/feint-<provider>.tfvars.example) — plan_root only plans it, and
# apply_fixture below drives the same cycle on the separate reduced fixture,
# not this root. Closes issue #76's first criterion: feint-record proved the
# provider module alone applies end to end (transcript, zero unserved calls);
# this proves the whole root — VMs, networking, LBs — does too.
apply_root() {
  local provider="$1" root="$REPO_ROOT/infrastructure/opentofu/cluster" rc
  local example="$root/envs/feint-${provider}.tfvars.example"
  override="$root/zz-feint-backend_override.tf"

  [ -f "$example" ] || { echo "✗ no such lane: $example" >&2; exit 1; }
  [ -e "$override" ] && { echo "✗ $override already exists; refusing to overwrite it" >&2; exit 1; }

  work="$(mktemp -d)"
  # Start from an empty store: a prior lane's leftover resources answer 409 on
  # the first create, same reason apply_fixture and record_root reset first.
  reset_emulator
  [ "$provider" = scaleway ] && register_scaleway_image "$FEINT_ENDPOINT"
  trap 'rm -f "${override:-}" || true; rm -rf "${work:-}" || true' EXIT

  cat > "$override" <<EOT
# Generated by scripts/dev/feint.sh, removed when it exits. If you are reading
# this in a working tree, a run died hard — delete it.
terraform {
  backend "local" {
    path = "$work/apply.tfstate"
  }
}
EOT
  cp "$example" "$work/feint.tfvars"
  emulated_env
  export TF_VAR_encryption_passphrase="feint-emulated-lane-passphrase-not-a-secret"

  cd "$root"
  local args=(-var-file="$work/feint.tfvars" -var "emulator_api_url=$FEINT_ENDPOINT")

  tofu init -no-color -reconfigure
  tofu apply -no-color -auto-approve "${args[@]}"

  rc=0; tofu plan -no-color -detailed-exitcode "${args[@]}" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) echo "  ok: the second plan is empty — everything read back as it was sent" ;;
    2) tofu plan -no-color "${args[@]}" || true
       echo "✗ the applied state still plans a change: the API does not read back what was sent" >&2; exit 1 ;;
    *) echo "✗ the second plan errored (status $rc)" >&2; exit 1 ;;
  esac

  # Two-step destroy (README's teardown pattern, "Manual equivalent"): machine
  # secrets carry prevent_destroy, and excluding them alone is not enough —
  # module.talos depends_on module.<provider>, so excluding the secrets
  # cascades to keeping the whole provider module too (0 destroyed).
  tofu state rm module.talos.talos_machine_secrets.this[0]
  tofu destroy -no-color -auto-approve "${args[@]}" -var talos_bootstrap=false
  echo "✓ ${provider}: the real cluster root applied / empty re-plan / destroyed, no credentials"
}

# record_root measures which operations our provider module calls that the
# emulator does not serve, and ranks them.
#
# `feint proxy` sits between the client and one upstream and writes a redacted
# transcript; `feint transcript` then ranks what no pack served, most-called
# first. Upstream here is the emulator, not the cloud, and that is a constraint
# rather than a shortcut: a client that signs the host it was configured with —
# the Terraform provider does — cannot be recorded against a real cloud through
# a reverse proxy, because the cloud validates the signature against its own
# name and answers 401. Their docs/proxy.md measures it.
#
# So this answers "what does our module call that is missing", which is what a
# batch issue needs, and not "what does the real cloud answer", which needs the
# DNS/TLS interception their #76 is about.
#
# The apply is expected to FAIL, on the first unserved call. That is the point:
# everything up to it is recorded.
record_root() {
  local provider="$1" root="$REPO_ROOT/infrastructure/opentofu/cluster"
  local example="$root/envs/feint-${provider}.tfvars.example"
  local module proxy_addr="127.0.0.1:4600"
  module="$([ "$provider" = scaleway ] && echo module.scw || echo module.outscale)"
  override="$root/zz-feint-backend_override.tf"

  [ -f "$example" ] || { echo "✗ no such lane: $example" >&2; exit 1; }
  [ -e "$override" ] && { echo "✗ $override already exists; refusing to overwrite it" >&2; exit 1; }

  work="$(mktemp -d)"
  reset_emulator
  # Straight to the emulator, never through the proxy about to start: this is
  # our own setup, not a call the module makes, and the transcript below must
  # rank only the latter.
  [ "$provider" = scaleway ] && register_scaleway_image "$FEINT_ENDPOINT"
  feint proxy --provider "$provider" --upstream "$FEINT_ENDPOINT" \
    --addr "$proxy_addr" --record "$work/$provider.jsonl" >"$work/proxy.log" 2>&1 &
  proxy_pid=$!
  # Kill by pid, never by pattern: `pkill -f 'feint proxy'` matches the shell
  # running this script too, and takes it down with the proxy.
  # `|| true` on every step: under `set -e` a failing command inside an EXIT trap
  # aborts the rest of it, so killing an already-dead proxy would leave the
  # backend override behind and turn a successful run into exit 1.
  trap 'kill "${proxy_pid:-0}" 2>/dev/null || true; rm -f "${override:-}" || true; rm -rf "${work:-}" || true' EXIT
  sleep 2

  cat > "$override" <<EOT
# Generated by scripts/dev/feint.sh, removed when it exits.
terraform {
  backend "local" {
    path = "$work/record.tfstate"
  }
}
EOT
  cp "$example" "$work/feint.tfvars"
  emulated_env
  export TF_VAR_encryption_passphrase="feint-emulated-lane-passphrase-not-a-secret"

  cd "$root"
  tofu init -no-color -reconfigure >/dev/null
  tofu apply -no-color -auto-approve -target="$module" \
    -var-file="$work/feint.tfvars" -var "emulator_api_url=http://$proxy_addr" \
    >"$work/apply.log" 2>&1 || true

  kill "$proxy_pid" 2>/dev/null; wait "$proxy_pid" 2>/dev/null || true
  echo
  feint transcript "$work/$provider.jsonl"
}

# machine_refs lists what apply created, read out of the outputs ONCE — before
# the destroy removes them. Reading them afterwards is how a post-destroy check
# ends up probing an empty list and passing without asking anything.
machine_refs() {
  local out
  out="$([ "$1" = scaleway ] && echo scaleway_paths || echo outscale_vm_ids)"
  tofu output -json "$out" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))'
}

# count_live reports how many of those the emulator still serves. Asked of the
# API, never of the state: a destroy reporting success only means the provider
# believed what the delete answered.
count_live() {
  local provider="$1" refs="$2" live=0 ref
  [ -n "$refs" ] || { printf '0'; return; }
  while read -r ref; do
    [ -n "$ref" ] || continue
    if [ "$provider" = scaleway ]; then
      [ "$(curl -s -o /dev/null -w '%{http_code}' "${FEINT_ENDPOINT}${ref}")" = "200" ] && live=$((live + 1))
    else
      # Presence is not liveness on Outscale: a deleted VM stays readable as
      # "terminated", on the real API as on the emulator. Counting rows here
      # would make every destroy look like a failure.
      live=$((live + $(curl -s -X POST "${FEINT_ENDPOINT}/api/v1/ReadVms" \
        -H 'Content-Type: application/json' -d "{\"Filters\":{\"VmIds\":[\"$ref\"]}}" \
        | python3 -c 'import json,sys
dead = {"terminated", "shutting-down"}
print(sum(1 for v in json.load(sys.stdin).get("Vms", []) if v.get("State") not in dead))')))
    fi
  done <<< "$refs"
  printf '%s' "$live"
}

# apply_fixture drives the real create/read/update/delete cycle.
#
# `plan` alone proves only that the provider accepts an address and can read.
# The empty second plan is the actual assertion: it holds only if every attribute
# the provider sent comes back identical, which is where an invented or dropped
# field shows up.
apply_fixture() {
  local expected live rc refs
  # Globals, like `override` above: the EXIT trap fires after this function has
  # returned, and a local would be unbound by then.
  provider="$1"
  root="$REPO_ROOT/infrastructure/opentofu-feint"

  work="$(mktemp -d)"
  # Start from an empty store: a record lane, or an apply that died half-way,
  # leaves resources whose names this fixture reuses — the create then answers
  # 409 and the failure reads like a provider bug.
  reset_emulator
  # Destroy on the error path too: an apply that dies half-way leaves resources
  # behind, and the next run then starts from a poisoned emulator.
  # `|| true`: a failing command inside an EXIT trap aborts the rest of it under
  # `set -e` — the temp dir would survive and the run would report failure.
  trap 'cd "${root:-}" 2>/dev/null && tofu destroy -no-color -auto-approve -var "target_provider=${provider:-}" -var "endpoint=$FEINT_ENDPOINT" >/dev/null 2>&1 || true; rm -rf "${work:-}" || true' EXIT

  emulated_env
  cd "$root"
  local args=(-var "target_provider=$provider" -var "endpoint=$FEINT_ENDPOINT")

  tofu init -no-color
  tofu validate -no-color
  tofu apply -no-color -auto-approve "${args[@]}"

  expected=3 # control plane + worker + bastion, in both fixtures
  refs="$(machine_refs "$provider")"
  live="$(count_live "$provider" "$refs")"
  [ "$live" = "$expected" ] || { echo "✗ applied $expected machines, the API serves $live" >&2; exit 1; }
  echo "  ok: $live machines exist in the API, not just in the state"

  rc=0; tofu plan -no-color -detailed-exitcode "${args[@]}" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) echo "  ok: the second plan is empty — everything read back as it was sent" ;;
    2) tofu plan -no-color "${args[@]}" || true
       echo "✗ the applied state still plans a change: the API does not read back what was sent" >&2; exit 1 ;;
    *) echo "✗ the second plan errored (status $rc)" >&2; exit 1 ;;
  esac

  tofu destroy -no-color -auto-approve "${args[@]}"
  trap 'rm -rf "${work:-}"' EXIT
  # Same refs as before the destroy — the outputs are gone now, and re-reading
  # them here would ask the emulator about nothing at all.
  live="$(count_live "$provider" "$refs")"
  [ "$live" = "0" ] || { echo "✗ destroy reported success but the API still serves $live machines" >&2; exit 1; }
  echo "✓ ${provider}: apply / empty re-plan / destroy, confirmed against the API"
}

case "${1:-}" in
  install) install_feint ;;
  start)
    guard_local "$FEINT_ENDPOINT"
    # install_feint unconditionally: it returns early when the version already
    # matches, and it is the ONLY thing that compares one. This used to read
    # `command -v feint || install_feint`, which installs when the binary is
    # ABSENT and never asks which version a present one is — so FEINT_VERSION was
    # honoured on a fresh machine and decorative on every machine that had already
    # run the lane. Bumping the pin to 0.10.0 on 2026-08-21 kept running 0.9.0.
    install_feint
    vm_args=()
    [ -n "$FEINT_VM" ] && vm_args=(--vm "$FEINT_VM")
    # Idempotent: `feint start` refuses when one is already listening, and a
    # target you cannot run twice is a target nobody re-runs after a failure.
    # Matched on the output, not the exit code: `feint status` exits 0 either
    # way, so keying off it silently skipped the start and left every later
    # step running against nothing.
    if ! running; then
      feint_cli start --addr "$(addr_of "$FEINT_ENDPOINT")" "${vm_args[@]}"
      poll_running || {
        echo "✗ the emulator did not come up on $FEINT_ENDPOINT within ${FEINT_RESTART_TIMEOUT}s" >&2
        emulator_log_hint
        exit 1
      }
    fi
    feint_cli status
    ;;
  stop)
    # Stopping is enough to discard the store: it lives in memory, nothing is
    # persisted (no --state). Resetting between lanes is `reset_emulator`.
    feint_cli stop || true
    ;;
  status) feint_cli status ;;
  guard) guard_local "${2:-$FEINT_ENDPOINT}" ;;
  plan)
    guard_local "$FEINT_ENDPOINT"
    require_emulator
    plan_root "${2:?usage: feint.sh plan scaleway|outscale}"
    ;;
  apply)
    guard_local "$FEINT_ENDPOINT"
    require_emulator
    apply_fixture "${2:?usage: feint.sh apply scaleway|outscale}"
    ;;
  apply-root)
    guard_local "$FEINT_ENDPOINT"
    require_emulator
    apply_root "${2:?usage: feint.sh apply-root scaleway|outscale}"
    ;;
  record)
    guard_local "$FEINT_ENDPOINT"
    require_emulator
    record_root "${2:?usage: feint.sh record scaleway|outscale}"
    ;;
  evidence)
    # Reads whatever the emulator's own /_feint/conformance already knows, so
    # it must run right after a real cycle (e.g. `feint.sh apply`) and before
    # any reset — a reset is what a fresh `feint start` always is (#151).
    guard_local "$FEINT_ENDPOINT"
    require_emulator
    provider="${2:?usage: feint.sh evidence scaleway|outscale}"
    mkdir -p "$REPO_ROOT/coverage"
    feint evidence --endpoint "$FEINT_ENDPOINT" --out "$REPO_ROOT/coverage/evidence-${provider}.json"
    ;;
  evidence-baseline)
    # Refuses at capture if the record behind it reached no machine runtime
    # (`FEINT_VM` unset) — see feint's own `evidence baseline` help. No `--out`:
    # printed for a human to review before it becomes a committed file, not
    # written as a side effect of a script.
    provider="${2:?usage: feint.sh evidence-baseline scaleway|outscale}"
    feint evidence baseline --evidence "$REPO_ROOT/coverage/evidence-${provider}.json"
    ;;
  evidence-verify)
    provider="${2:?usage: feint.sh evidence-verify scaleway|outscale}"
    feint evidence verify \
      --baseline "$REPO_ROOT/.feint-evidence-${provider}.json" \
      --evidence "$REPO_ROOT/coverage/evidence-${provider}.json"
    ;;
  *)
    echo "Usage: $(basename "$0") install|start|stop|status|guard [endpoint]" >&2
    echo "       $(basename "$0") plan|apply|apply-root|record scaleway|outscale" >&2
    echo "       $(basename "$0") evidence|evidence-baseline|evidence-verify scaleway|outscale" >&2
    exit 1
    ;;
esac
