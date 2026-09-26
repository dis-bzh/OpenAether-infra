#!/usr/bin/env bash
# Upgrade Kubernetes, then Talos, on a running cluster — and measure the
# interruption instead of asserting there was none.
#
# This is `task cluster-upgrade`. It was proven by hand on all three clouds
# (2026-08-13, again 2026-08-19/20) and has never had unattended coverage.
#
# WHERE THE TARGET COMES FROM. Not from upstream's newest release: from
# `cluster/variables.tf`, the pair this repository actually ships. A cluster's
# tfvars is expected to pin a patch BELOW it, so a run upgrades toward what a
# reader deploying today would land on, and Renovate bumping the defaults is what
# keeps a target to move to. Override with UPGRADE_TALOS_TO / UPGRADE_K8S_TO.
#
# NOTHING HERE RETRIES. The first apply after a `talos_version` bump is known to
# fail on OVH and Outscale (backlog: "Provider produced inconsistent final plan").
# A retry would turn that defect into a green run, which is how it survived this
# long.
#
# DRY_RUN=1 resolves the versions and rewrites a COPY of the tfvars, then stops
# before the first task. It needs no cluster and no credentials, and it is what
# makes the version arithmetic below testable rather than first exercised on a
# paying account.
#
# Usage: cluster-upgrade.sh <provider> <role> [ssh-key]
set -euo pipefail

PROVIDER="${1:?usage: cluster-upgrade.sh <provider> <role> [ssh-key]}"
ROLE="${2:?usage: cluster-upgrade.sh <provider> <role> [ssh-key]}"
KEY="${3:-$HOME/.ssh/id_ed25519}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TFVARS="$ROOT/infrastructure/opentofu/cluster/envs/${ROLE}-${PROVIDER}.tfvars"

# The apiserver is allowed to blink while a control plane restarts — the hand-run
# on 2026-08-13 lost 3 probe seconds to it. This is a ceiling on that blink, not
# a claim of zero: raise it only with a measurement that says why.
MAX_PROBE_FAILS="${MAX_PROBE_FAILS:-15}"

export KUBECONFIG="$ROOT/infrastructure/opentofu/cluster/kubeconfig"

fail() { echo "✗ $*" >&2; exit 1; }
ok() { echo "✓ $*"; }

[ -f "$TFVARS" ] || fail "no $TFVARS"

if [ "${DRY_RUN:-}" = "1" ]; then
  DRY_COPY="$(mktemp)"
  cp "$TFVARS" "$DRY_COPY"
  TFVARS="$DRY_COPY"
  trap 'rm -f "$DRY_COPY"' EXIT
fi

# --- Where we are, and where we are going -------------------------------------

tfvar_get() { # <key> — the tfvars pin, or cluster/variables.tf's default
  local v
  v="$(grep -E "^[[:space:]]*${1}[[:space:]]*=" "$TFVARS" | head -1 |
    sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | tr -d '[:space:]')"
  [ -n "$v" ] || v="$(awk "/variable \"$1\"/,/^}/" "$ROOT/infrastructure/opentofu/cluster/variables.tf" |
    sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
  printf '%s' "$v"
}

tfvar_set() { # <key> <value> — replace the pin, or add one if the file has none
  local key="$1" value="$2"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS"; then
    sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*).*|\1\"$value\"|" "$TFVARS"
  else
    printf '\n%s = "%s"\n' "$key" "$value" >>"$TFVARS"
  fi
  [ "$(tfvar_get "$key")" = "$value" ] || fail "could not set $key to $value in $TFVARS"
}

default_of() { # <key> — cluster/variables.tf only, ignoring the tfvars
  awk "/variable \"$1\"/,/^}/" "$ROOT/infrastructure/opentofu/cluster/variables.tf" |
    sed -nE 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1
}

# --- the path, one minor at a time -------------------------------------------
# Kubernetes forbids skipping a minor on the way up, and Talos supports a WINDOW
# of Kubernetes minors, not all of them — so a valid start and a valid end can be
# joined by a step that is neither. Going (1.12, 1.30) → (1.13, 1.36) by moving
# Talos first lands on (1.13, 1.30), which is below 1.13's floor of 1.31 and is
# refused at apply time, after the previous step has already landed.
#
# The ranges come from cluster/version-support.json — the same file
# versions-guard.tf reads, so the path and the gate cannot disagree about what is
# supported. Every step this builds is a real apply, and that gate runs on each.
SUPPORT_JSON="$ROOT/infrastructure/opentofu/cluster/version-support.json"

minor_of()   { printf '%s' "$1" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/'; }
k8s_minor()  { printf '%s' "$1" | sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/'; }

# Is this Talos minor allowed to run this Kubernetes minor?
pair_ok() { # <talos-version> <k8s-version>
  local lo hi km
  km="$(k8s_minor "$2")"
  read -r lo hi <<<"$(jq -r --arg m "$(minor_of "$1")" \
        '.talos_minors[$m] // empty | "\(.k8s_min) \(.k8s_max)"' "$SUPPORT_JSON")"
  [ -n "${lo:-}" ] || return 1          # a Talos minor the matrix has never heard of
  [ "$km" -ge "$lo" ] && [ "$km" -le "$hi" ]
}

# Intermediate hops land on `.0`: that patch always exists for a Kubernetes minor,
# and the step is left again immediately. Only the LAST hop of each axis carries
# the patch that was actually pinned.
# Which version string to use for a minor on the way through. NEVER `.0` for the
# minor already running: dropping v1.12.7 to v1.12.0 to pass through is a patch
# DOWNGRADE, and the first draft of this did exactly that.
_at_minor() { # <minor> <current-version> <target-version>
  local m="$1" cur="$2" tgt="$3"
  if   [ "$m" = "$(minor_of "$tgt")" ]; then printf '%s' "$tgt"
  elif [ "$m" = "$(minor_of "$cur")" ]; then printf '%s' "$cur"
  else printf 'v%s.0' "$m"; fi
}

# The whole path is built and validated BEFORE a line of it is printed: a caller
# that reads steps and then a refusal has already been told to start something
# that cannot finish.
version_path() { # <talos-from> <k8s-from> <talos-to> <k8s-to> → one "talos k8s" per line
  local t="$1" k="$2" tt="$3" kt="$4" tm km ttm ktm guard=0 nt out=""
  tm="$(minor_of "$t")";   km="$(k8s_minor "$k")"
  ttm="$(minor_of "$tt")"; ktm="$(k8s_minor "$kt")"

  if [ "${tm%%.*}" != "${ttm%%.*}" ]; then
    echo "✗ a Talos MAJOR change (${tm} → ${ttm}) is not a path this builds" >&2; return 1
  fi
  if [ "${tm#*.}" -gt "${ttm#*.}" ] || [ "$km" -gt "$ktm" ]; then
    echo "✗ ${t}/${k} → ${tt}/${kt} goes DOWN. Downgrades are not a path this builds." >&2; return 1
  fi
  # No minor moves: there is no path to build, and the window is none of this
  # function's business. The plan-time guard checks the destination pair on every
  # apply regardless, and consulting the map here would refuse any pair it has not
  # been taught — a fictional test fixture, or a legitimate minor on the day
  # someone bumps before extending version-support.json.
  if [ "$tm" = "$ttm" ] && [ "$km" = "$ktm" ]; then
    printf '%s %s\n' "$tt" "$kt"; return 0
  fi

  pair_ok "$tt" "$kt" || {
    echo "✗ the TARGET ${tt}/${kt} is not a supported pair — nothing to path toward." >&2; return 1; }

  while [ "$tm" != "$ttm" ] || [ "$km" != "$ktm" ]; do
    guard=$((guard + 1))
    [ "$guard" -le 40 ] || { echo "✗ path did not converge in 40 steps — refusing to guess" >&2; return 1; }

    # Talos first when it is legal: its window moves the ceiling up, so taking it
    # early keeps the path short and never strands Kubernetes below a new floor.
    nt="${tm%%.*}.$(( ${tm#*.} + 1 ))"
    if [ "$tm" != "$ttm" ] && pair_ok "v${nt}.0" "v1.${km}.0"; then
      tm="$nt"
    elif [ "$km" -lt "$ktm" ] && pair_ok "v${tm}.0" "v1.$((km + 1)).0"; then
      km=$((km + 1))
    else
      echo "✗ no supported step out of Talos ${tm} / Kubernetes 1.${km} toward ${ttm}/1.${ktm}." >&2
      echo "  Neither axis can move without leaving the window in version-support.json." >&2
      return 1
    fi
    out+="$(_at_minor "$tm" "$t" "$tt") $(_at_minor "1.${km}" "$k" "$kt")"$'\n'
  done

  # The loop only exits with both minors matched, and the same-minor case returned
  # long before it — so `out` is never empty here. A fallback that filled it was
  # dead the moment that early return went in, and a mutation proved it: removing
  # it changed nothing.
  printf '%s' "$out"
}

TALOS_TO="${UPGRADE_TALOS_TO:-$(default_of talos_version)}"
K8S_TO="${UPGRADE_K8S_TO:-$(default_of kubernetes_version)}"

# WHERE WE ARE COMES FROM THE CLUSTER, NOT THE TFVARS.
#
# This script rewrites the tfvars BEFORE the apply that makes it true. Interrupt
# it in between — Ctrl+C, a failed apply, a lost connection — and the file
# asserts a version nobody is running. The next run then reads that file, decides
# the step is already done, and skips it. The cluster stays behind and the run
# reports success.
#
# Demonstrated on Outscale, 2026-08-18: an aborted run left
# `kubernetes_version = v1.36.3` in the tfvars. There it was harmless (the apply
# HAD landed), but the same abort one step earlier would have silently skipped a
# Kubernetes upgrade for ever.
#
# So each axis is decided by asking every node what it runs. A MIXED fleet is the
# resume case and must run, not skip: that is precisely the state an interrupted
# roll leaves behind.
cluster_versions() { # <field> — the distinct set across all nodes, or empty
  # custom-columns, not the jsonpath the post-upgrade counters use: this asks a
  # DIFFERENT question — "which versions exist in the fleet" rather than "how many
  # are not at the target" — and the two must be distinguishable, both to a reader
  # and to the stub harness that has to answer them differently in one run.
  # `|| true`, and it is load-bearing: with no cluster the grep matches nothing,
  # `pipefail` turns that into a failed pipeline, and `set -e` then kills the
  # script on the assignment — so the tfvars fallback below could never be
  # reached. An empty answer is a legitimate answer here; a dead script is not.
  kubectl get nodes --no-headers -o "custom-columns=V:$1" 2>/dev/null |
    sed -E 's/^Talos \((v[^)]+)\)$/\1/' | grep -E '^v' | sort -u | paste -sd, - || true
}

CLUSTER_K8S="$(cluster_versions '.status.nodeInfo.kubeletVersion')"
CLUSTER_TALOS="$(cluster_versions '.status.nodeInfo.osImage')"

if [ -n "$CLUSTER_K8S" ] && [ -n "$CLUSTER_TALOS" ]; then
  K8S_FROM="$CLUSTER_K8S"; TALOS_FROM="$CLUSTER_TALOS"; SOURCE="the cluster"
else
  # No cluster to ask (DRY_RUN, or an apiserver that is down). Fall back to the
  # tfvars and SAY so, rather than presenting a guess as a reading.
  K8S_FROM="$(tfvar_get kubernetes_version)"; TALOS_FROM="$(tfvar_get talos_version)"
  SOURCE="the tfvars (no cluster answered — this is what it CLAIMS, not what runs)"
fi

# A single value means every node agrees; a comma means the fleet is mixed and
# the step has to run whatever any file says.
K8S_DONE=0;   [ "$K8S_FROM" = "$K8S_TO" ] && K8S_DONE=1
TALOS_DONE=0; [ "$TALOS_FROM" = "$TALOS_TO" ] && TALOS_DONE=1

# Same version is NOT the same image. The schematic carries the system
# extensions, and a version comparison is blind to it: on 2026-08-19 a fleet ran
# the schematic that broke OVH while its own config named the fixed one, and
# this gate called the work done. So ask a node which schematic it runs.
#
# BEST EFFORT, deliberately. The tunnels are usually shut this early, and a
# check that cannot run must SAY so — not block a legitimate upgrade, and not
# wave a stale fleet through in silence.
SCHEMATIC_NOTE=""
if [ "$TALOS_DONE" = 1 ]; then
  WANT_SCH="$(awk '/variable "talos_installer_schematic_id"/,/^}/' \
                "$ROOT/infrastructure/opentofu/cluster/variables.tf" 2>/dev/null |
              grep -oE '[0-9a-f]{64}' | head -1)" || WANT_SCH=""
  # -n 127.0.0.1 through the tunnel: apid answers for the node behind it, so this
  # needs no node address and therefore no kubectl, no tofu and no credentials.
  TUN="127.0.0.1:$((50000 + ${TF_VAR_talos_tunnel_port_offset:-0}))"
  HAVE_SCH="$(talosctl get extensions -e "$TUN" -n 127.0.0.1 -o json 2>/dev/null |
              jq -s -r '.[] | select(.spec.metadata.name == "schematic") | .spec.metadata.version' 2>/dev/null | head -1)" || HAVE_SCH=""
  if [ -n "$WANT_SCH" ] && [ -n "$HAVE_SCH" ] && [ "$WANT_SCH" != "$HAVE_SCH" ]; then
    TALOS_DONE=0
    SCHEMATIC_NOTE="  ⚠ same version, DIFFERENT schematic — the fleet runs ${HAVE_SCH:0:12}…, the config pins ${WANT_SCH:0:12}…
    The system extensions differ, so this IS a reinstall and the Talos step will run."
  elif [ -z "$HAVE_SCH" ]; then
    SCHEMATIC_NOTE="  ? the running schematic could not be read (no tunnel open yet) — only the version was compared."
  fi
fi

echo "  Talos      ${TALOS_FROM} → ${TALOS_TO}   (read from ${SOURCE})"
echo "  Kubernetes ${K8S_FROM} → ${K8S_TO}"
case "${K8S_FROM}${TALOS_FROM}" in
  *,*) echo "  ⚠ the fleet is MIXED — this is a resume, and every step below will run." ;;
esac
[ -n "$SCHEMATIC_NOTE" ] && echo "$SCHEMATIC_NOTE"

if [ "$K8S_DONE" = 1 ] && [ "$TALOS_DONE" = 1 ]; then
  # Loud, and a failure — not a skip. A lane that quietly exercises nothing is
  # indistinguishable from a lane that passed, and this one costs money to run.
  fail "every node already runs both target versions (Talos ${TALOS_TO}, Kubernetes
  ${K8S_TO}), so this run would upgrade nothing.

  An upgrade can only be PROVEN from one patch below. Editing the tfvars is not
  enough — this script reads the CLUSTER, not the file, so a tfvars that claims
  an older version changes nothing here. The cluster itself has to start lower:

    1. set talos_version / kubernetes_version one patch below in
       envs/${ROLE}-${PROVIDER}.tfvars
    2. deploy that cluster (task cluster-up …)
    3. task cluster-upgrade …, which moves it to the targets in cluster/variables.tf

  UPGRADE_TALOS_TO / UPGRADE_K8S_TO override the targets upward instead, but only
  if a newer patch actually exists upstream."
fi

# --- the path, announced before anything moves --------------------------------
# Built and validated up front, then walked below. A run that discovers half way
# that the next step is unsupported has already landed the ones before it, and a
# cluster stranded on an intermediate pair is worse than one that never started.
if ! UPGRADE_PATH="$(version_path "$TALOS_FROM" "$K8S_FROM" "$TALOS_TO" "$K8S_TO")"; then
  fail "no supported upgrade path from Talos ${TALOS_FROM} / Kubernetes ${K8S_FROM}
  to Talos ${TALOS_TO} / Kubernetes ${K8S_TO}. The ranges are in
  cluster/version-support.json, which is also what the plan-time guard reads."
fi
PATH_STEPS="$(printf '%s' "$UPGRADE_PATH" | grep -c .)"
if [ "$PATH_STEPS" -gt 1 ]; then
  echo
  echo "▶ This is a ${PATH_STEPS}-step climb, one minor at a time (talos k8s):"
  printf '%s' "$UPGRADE_PATH" | nl -w4 -s'  ' | sed 's/^/    /'
  echo "  Every step is a full apply, so the plan-time pair guard runs on each one."
fi

if [ "${DRY_RUN:-}" = "1" ]; then
  # Guarded exactly as the real path is, or the dry run would show a rewrite the
  # real run never performs.
  if [ "$K8S_DONE" = 0 ]; then tfvar_set kubernetes_version "$K8S_TO"; fi
  if [ "$TALOS_DONE" = 0 ]; then tfvar_set talos_version "$TALOS_TO"; fi
  echo "--- what the tfvars would become ---"
  diff -u "$ROOT/infrastructure/opentofu/cluster/envs/${ROLE}-${PROVIDER}.tfvars" "$TFVARS" || true
  ok "dry run: versions resolved and the tfvars rewrite is well-formed"
  exit 0
fi

# --- The service probe (#41) ---------------------------------------------------
# The apiserver probe below measures the control plane; this one measures a
# workload behind a Service while its pods are drained off node after node.
# It goes through the apiserver's service proxy, so a sample taken while the
# apiserver is down says nothing about the Service: it is logged BLIND, not FAIL.
SVC_NS=upgrade-probe
SVC_PATH="/api/v1/namespaces/${SVC_NS}/services/http:upgrade-probe:80/proxy/hostname"
SVC_LOG="$(mktemp)"
SVC_REPORTED=0

# Reported, never gated: nobody has measured this yet, so there is no ceiling to
# hold it to. BLIND samples neither extend nor break an outage.
report_svc_probe() {
  local fails blind total longest keep elapsed=$(( SECONDS - ${SVC_STARTED:-$SECONDS} ))
  SVC_REPORTED=1
  # One snapshot: the probe is still appending, and four reads of a growing file
  # disagree with each other.
  keep="${ROOT}/.upgrade-probe-${PROVIDER}-${ROLE}.service.log"
  cp "$SVC_LOG" "$keep" 2>/dev/null || keep="$SVC_LOG"
  fails="$(grep -c ' FAIL$' "$keep" || true)"
  blind="$(grep -c ' BLIND$' "$keep" || true)"
  total="$(wc -l <"$keep")"
  longest="$(awk '$2=="FAIL"{r++; if (r>m) m=r; next} $2=="ok"{r=0} END{print m+0}' "$keep")"
  echo "  service probe: ${fails} FAIL, ${blind} BLIND in ${total} samples, longest outage ${longest}s, total downtime ~${fails}s (samples in ${keep})"
  # Up to two requests per sample, so half the apiserver probe's floor.
  if [ "$elapsed" -ge 30 ] && [ "$total" -lt $(( elapsed / 8 )) ]; then
    fail "the service probe wrote ${total} sample(s) in ${elapsed}s — it is not measuring, so no claim about the service can be made"
  fi
}

cleanup() { # every exit — success, failure, interrupt
  kill "${PROBE_PID:-}" "${SVC_PROBE_PID:-}" 2>/dev/null || true
  # A subshell: `fail` inside it must not skip the namespace deletion below.
  [ "$SVC_REPORTED" = 1 ] || ( report_svc_probe ) || true
  kubectl delete namespace "$SVC_NS" --ignore-not-found --wait=false >/dev/null 2>&1 ||
    echo "  ⚠ could not delete namespace ${SVC_NS} — remove it by hand" >&2
  rm -f "${PROBE_LOG:-}" "$SVC_LOG"
}
# bash runs the EXIT trap on a TERM as well, so no INT/TERM trap is needed: the
# stub harness interrupts a run mid-step and checks the workload is deleted.
trap cleanup EXIT

# The PDB only where a drain can honour it: on a single schedulable node both
# replicas sit there, and the budget would hold that node's drain to its timeout.
SCHEDULABLE="$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.taints[*].effect}{"\n"}{end}' 2>/dev/null |
  grep -cv NoSchedule || true)"
SVC_PDB=""
if [ "${SCHEDULABLE:-0}" -ge 2 ]; then
  SVC_PDB="---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: upgrade-probe, namespace: ${SVC_NS}}
spec:
  maxUnavailable: 1
  selector: {matchLabels: {app: upgrade-probe}}"
else
  echo "  ⚠ ${SCHEDULABLE:-0} schedulable node(s): no PDB, the service probe measures a non-HA outage"
fi

# agnhost netexec is the Kubernetes e2e test server; /hostname names the pod
# that answered, so the samples show traffic moving between replicas.
kubectl apply -f - >/dev/null <<EOF || fail "could not create the service probe in namespace ${SVC_NS}"
apiVersion: v1
kind: Namespace
metadata: {name: ${SVC_NS}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: upgrade-probe, namespace: ${SVC_NS}}
spec:
  replicas: 2
  selector: {matchLabels: {app: upgrade-probe}}
  template:
    metadata: {labels: {app: upgrade-probe}}
    spec:
      topologySpreadConstraints:
        - {maxSkew: 1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: ScheduleAnyway,
           labelSelector: {matchLabels: {app: upgrade-probe}}}
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: netexec
          image: registry.k8s.io/e2e-test-images/agnhost:2.66.1@sha256:6e2eef87d0dc77e070a7549bc5fdfa290c0fefe3359eb33c2ad1eda692fe66a4
          args: [netexec, --http-port=8080]
          ports: [{containerPort: 8080}]
          readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 2}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
---
apiVersion: v1
kind: Service
metadata: {name: upgrade-probe, namespace: ${SVC_NS}}
spec:
  selector: {app: upgrade-probe}
  ports: [{name: http, port: 80, targetPort: 8080}]
${SVC_PDB}
EOF
kubectl -n "$SVC_NS" rollout status deployment/upgrade-probe --timeout=180s >/dev/null ||
  fail "the service probe's pods never became ready — nothing could be measured, so nothing was upgraded"

svc_probe() {
  local out
  while :; do
    if out="$(kubectl get --raw="$SVC_PATH" --request-timeout=2s 2>/dev/null)"; then
      printf '%s ok %s\n' "$(date +%H:%M:%S)" "$out"
    elif kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1; then
      printf '%s FAIL\n' "$(date +%H:%M:%S)"
    else
      printf '%s BLIND\n' "$(date +%H:%M:%S)"
    fi
    sleep 1
  done >>"$SVC_LOG"
}
svc_probe &
SVC_PROBE_PID=$!
SVC_STARTED=$SECONDS

# --- The probe ----------------------------------------------------------------
# One second apart, against the endpoint in the kubeconfig — never a tunnel to a
# single node, which measures the node we are deliberately taking away.

PROBE_LOG="$(mktemp)"
# Each sample carries the wall-clock time it was taken. Without it a run can say
# the API was gone for 8 seconds but never WHICH eight — and the two candidate
# causes are told apart precisely by where the gap falls: at the moment a node
# disappears (an etcd election) or while it reboots (the load balancer still
# routing to it). A number with no timestamp cannot arbitrate between them.
probe() {
  while :; do
    if kubectl get --raw=/readyz --request-timeout=2s >/dev/null 2>&1; then
      printf '%s ok\n' "$(date +%H:%M:%S)"
    else
      printf '%s FAIL\n' "$(date +%H:%M:%S)"
    fi
    sleep 1
  done >>"$PROBE_LOG"
}
probe &
PROBE_PID=$!
# When the sampling started, so report_probe can tell "few samples because the
# step was quick" from "few samples because the probe is dead".
PROBE_STARTED=$SECONDS

# The assertion is about the LONGEST CONSECUTIVE outage, not the total number of
# failed samples — those are different claims and only the first matches the
# message this used to print ("unreachable for ~Ns"). Eighteen one-second blips
# spread over a control-plane roll is an HA cluster working as designed; eighteen
# in a row is the API being down. Counting them the same way cannot tell a
# healthy rolling restart from a total outage. Measured 2026-08-16: OVH 4 fails
# in 31 samples, Scaleway 18 in 59, on identical health-check settings.
#
# The log is also KEPT when the assertion trips: the old trap deleted the only
# evidence at exactly the moment someone would need it.
report_probe() {
  local fails total longest keep
  fails="$(grep -c FAIL "$PROBE_LOG" || true)"
  total="$(wc -l <"$PROBE_LOG")"
  # An EMPTY log satisfies "longest outage 0s ≤ 15s". If the probe died at the
  # start — no kubeconfig yet, no kubectl on PATH — the assertion below concludes
  # from no evidence and the run is called clean.
  #
  # The floor is RELATIVE to how long the probe has been alive, not a fixed count:
  # the probe samples about once a second, so expect roughly one sample per second
  # and demand a quarter of that. A fixed floor would fail a legitimately fast
  # step, which is the mirror defect — a guard written for the pathological case
  # firing on the normal one. Inert below 30s for the same reason.
  local elapsed=$(( SECONDS - ${PROBE_STARTED:-0} ))
  if [ "$elapsed" -ge 30 ] && [ "$total" -lt $(( elapsed / 4 )) ]; then
    fail "the probe wrote ${total} sample(s) in ${elapsed}s — it is not measuring, so no claim about the outage can be made"
  fi
  longest="$(awk '/FAIL/{r++; if (r>m) m=r; next} {r=0} END{print m+0}' "$PROBE_LOG")"
  echo "  probe: ${fails} FAIL in ${total} samples (~1s apart), longest outage ${longest}s"
  # Kept on EVERY run, not only on the failing one. A green run is the baseline
  # the next is compared against, and it was being deleted — so an investigation
  # started from a single number and no samples.
  keep="${ROOT}/.upgrade-probe-${PROVIDER}-${ROLE}.log"
  cp "$PROBE_LOG" "$keep" 2>/dev/null || true
  echo "  samples kept in ${keep}"
  [ "$longest" -le "$MAX_PROBE_FAILS" ] && return 0
  fail "the API was unreachable for ${longest}s in a row, over the ${MAX_PROBE_FAILS}s this lane allows (samples in ${keep})"
}

# --- One step of the climb ------------------------------------------------------
#
# Each of these was a `if [ "$X_DONE" = 0 ]` block moving straight to the target.
# They are functions now because the path can have seven steps, and every one of
# them is the same operation against a different version. Nothing inside changed.

upgrade_k8s_to() { # <version>
  local target="$1"
  echo "--- Kubernetes → ${target} ---"
  tfvar_set kubernetes_version "$target"
  task infra-apply ROLE="$ROLE" PROVIDER="$PROVIDER" KEY="$KEY" APPROVE=auto

  # Talos reconciles the static pods and the kubelets; the node's reported
  # version is the observable end of that, and it is not instant.
  echo "waiting for every kubelet to report ${target}"
  local seen stale
  for _ in $(seq 1 60); do
    # COUNT THE NODES, not just the stale ones. `grep -cvx` over the output of a
    # kubectl that answered nothing returns 0, which reads exactly like "every
    # kubelet is on the target" — a dead apiserver used to pass this.
    seen="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null |
             grep -c . || true)"
    stale="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null |
             grep -cvx "$target" || true)"
    [ "$seen" -gt 0 ] && [ "$stale" -eq 0 ] && break
    sleep 10
  done
  [ "${seen:-0}" -gt 0 ] || fail "the apiserver reported no nodes at all — nothing was verified, and this is not an upgrade that succeeded"
  [ "${stale:-1}" -eq 0 ] || fail "${stale} kubelet(s) still not on ${target} after 10 minutes"
  ok "every kubelet on ${target} (${seen} node(s) seen)"
  report_probe
}

upgrade_talos_to() { # <version>
  local target="$1"
  echo "--- Talos → ${target} ---"

  # The nodes ignore their image attribute, but the image DATA SOURCE still has
  # to resolve, and it derives its name from talos_version. Without this the
  # plan fails on an image the account does not have.
  task image-build PROVIDER="$PROVIDER" VERSION="$target" ENSURE=1

  tfvar_set talos_version "$target"
  task infra-apply ROLE="$ROLE" PROVIDER="$PROVIDER" KEY="$KEY" APPROVE=auto

  # One node at a time, health-gated between each; control planes first because
  # a worker's upgrade needs a healthy control plane to drain against.
  # --yes: there is no terminal here, and without it rolling-replace stops at its
  # confirmation prompt and exits 1 — which is how an unattended lane discovers
  # that a script it depends on was only ever run by hand.
  task cluster-roll PROVIDER="$PROVIDER" ROLE="$ROLE" KEY="$KEY" APPROVE=auto -- --cp-only --upgrade
  task cluster-roll PROVIDER="$PROVIDER" ROLE="$ROLE" KEY="$KEY" APPROVE=auto -- --workers-only --upgrade

  # Same trap as the kubelet count above: with no nodes returned, `grep -cv`
  # answers 0 and a dead cluster reports a clean Talos upgrade.
  local osimages running
  osimages="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.osImage}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
  running="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.osImage}{"\n"}{end}' 2>/dev/null |
              grep -cv "$target" || true)"
  [ "$osimages" -gt 0 ] || fail "the apiserver reported no nodes at all after the Talos roll — nothing was verified"
  [ "$running" -eq 0 ] || fail "${running} node(s) are not running Talos ${target}"
  ok "every node on Talos ${target} (${osimages} node(s) seen)"
  report_probe
}

# --- Walk the path, one minor at a time -----------------------------------------
#
# Kubernetes first within a step, when both move — it reboots nothing, so it
# isolates the control-plane roll from the node roll. The path builder never
# produces a step that moves both, but the order is stated rather than assumed.
#
# Each step is a full apply, so the plan-time pair guard runs on every one of
# them: an intermediate the matrix does not support cannot slip through here.

# A function, and not for tidiness: it is the only way to exercise a seven-step
# dispatch without a test fixture pinning versions that look real. The harness
# feeds it a path with the two upgrade_* stubbed out and reads the call order.
walk_path() { # <talos-from> <k8s-from> <total>   — reads "talos k8s" lines on stdin
  local prev_t="$1" prev_k="$2" total="$3" step=0 st sk line
  # Drain stdin BEFORE the first step, never between two. Inside the loop
  # `task cluster-roll` reaches ssh and talosctl, and both READ STDIN — the same
  # stdin that feeds this loop. On Scaleway the Talos roll of step 2 ate steps
  # 3-7: the climb ended, exited 0, and announced a version the cluster never ran.
  local -a steps=()
  mapfile -t steps
  for line in "${steps[@]}"; do
    read -r st sk <<<"$line"
    [ -n "$st" ] || continue
    step=$((step + 1))
    if [ "$total" -gt 1 ]; then
      echo
      echo "════ step ${step}/${total} — Talos ${st}, Kubernetes ${sk}"
    fi
    [ "$sk" = "$prev_k" ] || upgrade_k8s_to "$sk"
    [ "$st" = "$prev_t" ] || upgrade_talos_to "$st"
    prev_t="$st"; prev_k="$sk"
  done
}

# A here-string, NOT a pipe. `printf | walk_path` puts the loop in a subshell,
# where `fail` exits the subshell and the run carries on past a step that did not
# land — measured: the harness went 35/8 the moment it was a pipe. The here-string
# fixes that and does NOT protect the stream: walk_path drains it before the first
# step because the steps themselves read stdin. Both traps, one line apart.
walk_path "$TALOS_FROM" "$K8S_FROM" "$PATH_STEPS" <<<"$UPGRADE_PATH"

# --- What a clean upgrade leaves behind ----------------------------------------

# Zero destroys. A plan that wants to replace nodes means the boot image and the
# running version have disagreed — that plan would take the cluster down.
# See modules/providers/provider-contract.md § "Node image drift".
task infra-plan ROLE="$ROLE" PROVIDER="$PROVIDER" KEY="$KEY" STRICT=1 ||
  fail "the plan is not empty after the upgrade — read provider-contract.md § Node image drift before re-running anything"
ok "plan empty after the upgrade"

# One verifier, and it is the release scope: Talos, Cilium, no Flux. The
# full-platform check that waited for 35 Flux Kustomizations was deleted with the
# staging lane it served — 0.1.0 disables Flux, so a cluster that has it is
# outside what this release validates and infra-verify says so rather than
# quietly verifying something else.
ok "verifying against the infrastructure floor"

# Through the TASK, not the script. infra-verify reads `tofu output` for the
# topology, the app LB and the bucket names, and that needs AWS_* — which this
# repository deliberately never sets ambiently: the Taskfile's provider-env
# anchor derives them per provider. Called directly from here, the verifier
# cannot read the state and reports two checks it could not perform.
#
# Measured on a live Scaleway cluster 2026-08-17: 7 passed / 2 failed from here,
# 9 passed / 0 failed through `task verify`, same cluster, same second. Both
# failures were the guards added that morning refusing to conclude from an
# unanswered question — the old code would have read the empty output as "no
# application load balancer" and gone green.
task cluster-verify PROVIDER="$PROVIDER" ROLE="$ROLE"

report_probe
report_svc_probe
echo "✓ ${PROVIDER}/${ROLE}: upgraded ${TALOS_FROM}→${TALOS_TO} / ${K8S_FROM}→${K8S_TO}, in place"
