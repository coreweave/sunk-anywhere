#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Concurrency probe: run a k8s pod (via kubectl) and a Slurm job at the same
# time and assert neither interferes with the other.
#
# Orchestrator-side script: must be invoked from the host (where kubectl works),
# NOT from inside slurm-login-0. run-all.sh handles both call sites.
#
# Precondition: kubectl available, slurm-login-0 pod up, >=1 node in $PARTITION.
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

NS="${NS:-tenant-slurm}"
LOGIN_POD="${LOGIN_POD:-slurm-login-0}"
LOGIN_CTR="${LOGIN_CTR:-sshd}"
PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-180}"
POD_NAME="sunk-concurrent-pod"
# run-all.sh exports these so host-side tests pin to the same kubeconfig/context
# as the runner. They are intentionally unquoted in kubectl invocations below
# so an empty value expands to nothing.
KUBECONFIG_FLAG="${KUBECONFIG_FLAG:-}"
CONTEXT_FLAG="${CONTEXT_FLAG:-}"

echo "=== 16-pod-and-slurm-concurrent (ns=$NS partition=$PARTITION) ==="

if ! command -v kubectl >/dev/null 2>&1; then
  echo "SKIPPED: kubectl not on PATH (run from host with cluster access)"
  exit 2
fi

if ! kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG get pod -n "$NS" "$LOGIN_POD" >/dev/null 2>&1; then
  echo "SKIPPED: $LOGIN_POD not found in $NS"
  exit 2
fi

NODES=$(kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG exec -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- \
  sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if [ -z "$NODES" ] || [ "$NODES" = "0" ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

cleanup() {
  kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG delete pod -n "$NS" "$POD_NAME" --ignore-not-found --wait=false >/dev/null 2>&1
  if [ -n "$JOBID" ]; then
    kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG exec -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- scancel "$JOBID" 2>/dev/null
  fi
}
trap cleanup EXIT

# Make sure no stale copy from a previous run is lingering.
kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG delete pod -n "$NS" "$POD_NAME" --ignore-not-found --wait=true >/dev/null 2>&1

# Submit the pod.
cat <<EOF | kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NS
spec:
  restartPolicy: Never
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  containers:
    - name: test
      image: busybox:1.36
      command: ["sh", "-c", "sleep 45 && echo pod-ok"]
      resources:
        requests: { cpu: 50m, memory: 32Mi }
        limits:   { memory: 64Mi }
EOF

# Submit the Slurm job at the same time.
JOBID=$(kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG exec -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- \
  sbatch --parsable -p "$PARTITION" --mem=256M --cpus-per-task=1 -t 00:03:00 \
    --wrap='echo slurm-ok; sleep 45' 2>&1 | tr -d '[:space:]')
if ! [[ "$JOBID" =~ ^[0-9]+$ ]]; then
  echo "FAIL: slurm submit returned: $JOBID"
  exit 1
fi
echo "Pod=$POD_NAME  SlurmJob=$JOBID"

DEADLINE=$(( $(date +%s) + TIMEOUT ))
POD_PHASE=""
LAST_POD_PHASE=""
JOB_STATE=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  POD_PHASE=$(kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG get pod -n "$NS" "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ -n "$POD_PHASE" ] && LAST_POD_PHASE="$POD_PHASE"
  JOB_STATE=$(kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG exec -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- \
    sacct -j "$JOBID" -n -X -o State 2>/dev/null | head -n1 | tr -d '[:space:]')
  echo "  pod=$POD_PHASE (last=$LAST_POD_PHASE) slurm=$JOB_STATE"
  if [ "$LAST_POD_PHASE" = "Succeeded" ] && [ "$JOB_STATE" = "COMPLETED" ]; then
    break
  fi
  if [ "$LAST_POD_PHASE" = "Failed" ] || [[ "$JOB_STATE" =~ ^(FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE|PREEMPTED)$ ]]; then
    break
  fi
  sleep 5
done
# Prefer the last non-empty pod phase observed. k8s can garbage-collect a
# Succeeded, restartPolicy:Never pod before our poll loop captures it.
POD_PHASE="$LAST_POD_PHASE"

EXITCODE=$(kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG exec -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- \
  sacct -j "$JOBID" -n -X -o ExitCode 2>/dev/null | head -n1 | tr -d '[:space:]')
echo "Final: pod=$POD_PHASE  slurm State=$JOB_STATE Exit=$EXITCODE"

if [ "$POD_PHASE" = "Succeeded" ] && [ "$JOB_STATE" = "COMPLETED" ] && [ "$EXITCODE" = "0:0" ]; then
  echo "PASS: pod and Slurm job both finished cleanly"
  exit 0
fi

echo "FAIL: pod=$POD_PHASE slurm=$JOB_STATE exit=$EXITCODE"
exit 1
