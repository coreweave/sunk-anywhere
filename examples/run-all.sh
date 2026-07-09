#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Master runner for the Slurm test suite.
#
# Orchestrates every NN-*.sh and NN-*.yaml in this directory. Runs outside the
# login pod; Slurm shell tests are executed via `kubectl exec`, pod-scheduler
# tests are applied via `kubectl apply`, and test 16 is already orchestrator-side.
#
# Flags:
#   --only=<basename>   run a single test (e.g. --only=02-sbatch-cpu-job.sh)
#   --dry-run           list what would run and skip reasons
#   --ns=<ns>           override namespace (default tenant-slurm)
#   --login-pod=<name>  override login pod (default slurm-login-0)
#
# Exit codes: 0 = no FAIL (SKIPs allowed), 1 = >=1 FAIL.
#
# Per-test timeout: 180s (3 min) via `timeout`.

set -u

NS="tenant-slurm"
LOGIN_POD="slurm-login-0"
LOGIN_CTR="sshd"
ONLY=""
DRY_RUN=0
PER_TEST_TIMEOUT=180
EXAMPLES_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_EXAMPLES_DIR="/home/examples"

KUBECONFIG_FLAG=""
CONTEXT_FLAG=""

for arg in "$@"; do
  case "$arg" in
    --only=*)      ONLY="${arg#--only=}" ;;
    --dry-run)     DRY_RUN=1 ;;
    --ns=*)        NS="${arg#--ns=}" ;;
    --login-pod=*) LOGIN_POD="${arg#--login-pod=}" ;;
    # Pin kubectl to a specific kubeconfig and/or context. Essential when
    # running two cloud verifications on the same host -- without this,
    # bare `kubectl` inherits whichever cluster $KUBECONFIG's current-
    # context points at, which races with parallel `gcloud/eksctl
    # get-credentials` calls.
    --kubeconfig=*) KUBECONFIG_FLAG="--kubeconfig=${arg#--kubeconfig=}" ;;
    --context=*)    CONTEXT_FLAG="--context=${arg#--context=}" ;;
    --help|-h)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) echo "Unknown flag: $arg" ; exit 1 ;;
  esac
done

# --------- cluster capability probe ---------

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found on PATH — cannot orchestrate"
  exit 1
fi

if ! kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG get pod -n "$NS" "$LOGIN_POD" >/dev/null 2>&1; then
  echo "login pod $NS/$LOGIN_POD not found"
  exit 1
fi

KCTL_COMMON="$KUBECONFIG_FLAG $CONTEXT_FLAG"

kexec() {
  kubectl $KCTL_COMMON exec -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- "$@"
}

echo "== Cluster capability probe =="
# sinfo -N lists one line per node; use that for accurate node counts.
TOTAL_NODES=$(kexec sinfo -h -N -o '%N' 2>/dev/null | sort -u | grep -cv '^$' | tr -d '[:space:]')
TOTAL_NODES="${TOTAL_NODES:-0}"
GPU_LINES=$(kexec sinfo -h -N -o '%G' 2>/dev/null | grep -c gpu || true)
CPU_PART_NODES=$(kexec sinfo -h -N -p cpu-workers -o '%N' 2>/dev/null | sort -u | grep -cv '^$' | tr -d '[:space:]')
CPU_PART_NODES="${CPU_PART_NODES:-0}"
GPU_PART_EXISTS=0
if kexec sinfo -h -p gpu-workers -o '%P' 2>/dev/null | grep -q .; then
  GPU_PART_EXISTS=1
fi
echo "  total_nodes=$TOTAL_NODES  cpu-workers_nodes=$CPU_PART_NODES  gpu_part_exists=$GPU_PART_EXISTS  gpu_lines=$GPU_LINES"

# --------- discover tests ---------

# Slurm shell tests run inside the login pod. 16 is orchestrator-side. yaml
# tests are kubectl-applied from the host.
SHELL_TESTS=(
  "01-basic-srun.sh"
  "02-sbatch-cpu-job.sh"
  "03-gpu-stress-test.sh"
  "07-multi-node-srun.sh"
  "08-array-job.sh"
  "09-job-dependency.sh"
  "10-cpu-share.sh"
  "11-different-nodes.sh"
  "12-hetjob.sh"
  "13-nccl-test.sh"
  "14-overcommit-mem.sh"
  "17-pyxis-container.sh"
  "18-salloc-overlap.sh"
)
# Opt-in tests. Not part of the default matrix; runnable via --only=.
#   19-vscode-tunnel.sh -- requires HTTPS egress to update.code.visualstudio.com
#                          and is interactive when VSCODE_TUNNEL_INTERACTIVE=1.
OPT_IN_SHELL_TESTS=(
  "19-vscode-tunnel.sh"
)
YAML_TESTS=(
  "04-validate-pod-scheduler.yaml"
  "15-multi-pod-scheduler.yaml"
)
HOST_SHELL_TESTS=(
  "16-pod-and-slurm-concurrent.sh"
)

# --------- helpers ---------

copy_shell_tests_into_pod() {
  [ $DRY_RUN -eq 1 ] && return 0
  # Only copy shell tests. YAMLs stay host-side. Opt-in tests are copied too
  # so they're reachable via --only= without a manual kubectl cp.
  local tmp
  tmp="$(mktemp -d)"
  for f in "${SHELL_TESTS[@]}" "${OPT_IN_SHELL_TESTS[@]}"; do
    cp "$EXAMPLES_DIR/$f" "$tmp/$f"
  done
  # Ensure target dir exists (login pod has /home on NFS).
  kexec mkdir -p "$REMOTE_EXAMPLES_DIR" >/dev/null 2>&1 || true
  kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG cp -c "$LOGIN_CTR" "$tmp/." "$NS/$LOGIN_POD:$REMOTE_EXAMPLES_DIR" >/dev/null
  kexec bash -c "chmod +x $REMOTE_EXAMPLES_DIR/*.sh" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}

# Portable timeout wrapper: prefers `timeout`, falls back to `gtimeout`
# (coreutils on macOS), then to a bash-native kill-on-deadline pattern.
_run_with_timeout() {
  local t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$t" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$t" "$@"
    return $?
  fi
  # bash-native fallback: run in background, kill after t seconds.
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$t" ] && { kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
    sleep 1
    waited=$((waited+1))
  done
  wait "$pid"
  return $?
}

run_shell_test_in_pod() {
  local name="$1"
  _run_with_timeout "$PER_TEST_TIMEOUT" kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG exec -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- \
    bash "$REMOTE_EXAMPLES_DIR/$name"
  return $?
}

run_host_shell_test() {
  local name="$1"
  # Forward kubeconfig/context to host-side tests so they pin kubectl to the
  # same cluster the runner is targeting. Without this, host-side tests fall
  # back to whatever the current default context happens to be.
  NS="$NS" LOGIN_POD="$LOGIN_POD" LOGIN_CTR="$LOGIN_CTR" \
    KUBECONFIG_FLAG="$KUBECONFIG_FLAG" CONTEXT_FLAG="$CONTEXT_FLAG" \
    _run_with_timeout "$PER_TEST_TIMEOUT" bash "$EXAMPLES_DIR/$name"
  return $?
}

run_yaml_test() {
  local name="$1"
  local path="$EXAMPLES_DIR/$name"
  echo "kubectl apply -f $name"
  if ! kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG apply -f "$path" >/dev/null; then
    echo "FAIL: kubectl apply failed"
    return 1
  fi
  local pods deadline
  pods=$(grep -E '^  name:' "$path" | awk '{print $2}')
  deadline=$(( $(date +%s) + PER_TEST_TIMEOUT ))
  local all_done=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    all_done=1
    for p in $pods; do
      local phase
      phase=$(kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG get pod -n "$NS" "$p" -o jsonpath='{.status.phase}' 2>/dev/null)
      echo "  $p: $phase"
      if [ "$phase" != "Succeeded" ]; then
        all_done=0
      fi
      if [ "$phase" = "Failed" ]; then
        kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG delete -f "$path" --ignore-not-found --wait=false >/dev/null
        echo "FAIL: pod $p entered Failed phase"
        return 1
      fi
    done
    [ $all_done -eq 1 ] && break
    sleep 5
  done
  kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG delete -f "$path" --ignore-not-found --wait=false >/dev/null
  if [ $all_done -eq 1 ]; then
    echo "PASS: all pods in $name reached Succeeded"
    return 0
  fi
  echo "FAIL: timed out waiting for pods in $name"
  return 1
}

# --------- run ---------

declare -a RESULTS=()
PASS=0; FAIL=0; SKIP=0

run_one() {
  local name="$1"
  local kind="$2"
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then
    return
  fi
  if [ $DRY_RUN -eq 1 ]; then
    echo "DRY-RUN would run $kind: $name"
    RESULTS+=("$name  DRY-RUN")
    return
  fi
  echo ""
  echo "---- $name ($kind) ----"
  local rc=0
  case "$kind" in
    shell)      run_shell_test_in_pod "$name" ; rc=$? ;;
    host-shell) run_host_shell_test   "$name" ; rc=$? ;;
    yaml)       run_yaml_test         "$name" ; rc=$? ;;
  esac
  case "$rc" in
    0)   RESULTS+=("$name  PASS")    ; PASS=$((PASS+1)) ;;
    2)   RESULTS+=("$name  SKIPPED") ; SKIP=$((SKIP+1)) ;;
    124) RESULTS+=("$name  FAIL (timeout ${PER_TEST_TIMEOUT}s)") ; FAIL=$((FAIL+1)) ;;
    *)   RESULTS+=("$name  FAIL (rc=$rc)") ; FAIL=$((FAIL+1)) ;;
  esac
}

if [ $DRY_RUN -eq 0 ]; then
  echo "== Copying shell tests into $LOGIN_POD:$REMOTE_EXAMPLES_DIR =="
  copy_shell_tests_into_pod
fi

for t in "${SHELL_TESTS[@]}";      do run_one "$t" shell ; done
# YAML tests interleaved where their number falls.
run_one "04-validate-pod-scheduler.yaml" yaml
run_one "15-multi-pod-scheduler.yaml"    yaml
for t in "${HOST_SHELL_TESTS[@]}"; do run_one "$t" host-shell ; done
# Opt-in shell tests only run when explicitly selected via --only=.
if [ -n "$ONLY" ]; then
  for t in "${OPT_IN_SHELL_TESTS[@]}"; do run_one "$t" shell ; done
fi

echo ""
echo "============================================"
echo " SUMMARY"
echo "============================================"
for r in "${RESULTS[@]}"; do
  printf "  %s\n" "$r"
done
echo "--------------------------------------------"
echo "  PASS=$PASS  SKIP=$SKIP  FAIL=$FAIL"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
