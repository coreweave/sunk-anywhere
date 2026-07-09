#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# GPU smoke test: nvidia-smi via Slurm on the gpu-workers partition.
#
# Preconditions:
#   - gpu-workers partition exists
#   - sinfo -h -p gpu-workers -o %D > 0
# If either fails we exit SKIPPED (2).
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-gpu-workers}"
TIMEOUT="${TIMEOUT:-180}"

echo "=== 03-gpu-stress-test (partition=$PARTITION timeout=${TIMEOUT}s) ==="

if ! sinfo -h -p "$PARTITION" -o '%P' 2>/dev/null | grep -q .; then
  echo "SKIPPED: partition $PARTITION does not exist (gpu-workers.enabled=false?)"
  exit 2
fi

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if [ -z "$NODES" ] || [ "$NODES" = "0" ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

JOBID=$(sbatch --parsable -p "$PARTITION" --gres=gpu:1 --mem=256M --cpus-per-task=1 -t 00:03:00 \
  --wrap='nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader' 2>&1)
if ! [[ "$JOBID" =~ ^[0-9]+$ ]]; then
  echo "FAIL: sbatch did not return a JobID: $JOBID"
  exit 1
fi
echo "Submitted JobID=$JOBID"

trap 'scancel "$JOBID" 2>/dev/null' EXIT

DEADLINE=$(( $(date +%s) + TIMEOUT ))
STATE=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE=$(sacct -j "$JOBID" -n -X -o State 2>/dev/null | head -n1 | tr -d '[:space:]')
  case "$STATE" in
    COMPLETED|FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE|PREEMPTED)
      break
      ;;
  esac
  sleep 5
done

EXITCODE=$(sacct -j "$JOBID" -n -X -o ExitCode 2>/dev/null | head -n1 | tr -d '[:space:]')
echo "Final State=$STATE ExitCode=$EXITCODE"

if [ "$STATE" = "COMPLETED" ] && [ "$EXITCODE" = "0:0" ]; then
  echo "PASS: GPU job $JOBID completed"
  exit 0
fi

echo "FAIL: state=$STATE exit=$EXITCODE"
exit 1
