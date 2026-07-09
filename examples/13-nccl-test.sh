#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# NCCL all_reduce_perf smoke test.
#
# NCCL requires >=2 GPUs total: either 2 nodes with 1 GPU each (inter-node) or
# 1 node with >=2 GPUs (intra-node). We probe for both via sinfo.
#
# Precondition: gpu-workers partition exists AND (>=2 nodes OR any node has >=2 GPUs).
# Payload: /opt/nccl-tests/build/all_reduce_perf if present, else skip.
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-gpu-workers}"
TIMEOUT="${TIMEOUT:-300}"
NCCL_BIN="${NCCL_BIN:-/opt/nccl-tests/build/all_reduce_perf}"

echo "=== 13-nccl-test (partition=$PARTITION timeout=${TIMEOUT}s) ==="

if ! sinfo -h -p "$PARTITION" -o '%P' 2>/dev/null | grep -q .; then
  echo "SKIPPED: partition $PARTITION does not exist"
  exit 2
fi

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if [ -z "$NODES" ] || [ "$NODES" = "0" ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

# Count max GPUs on any single node in the partition. sinfo's %G prints gres in
# the form "gpu:<type>:<count>,..." — grab the largest count.
MAX_GPUS_PER_NODE=$(sinfo -h -p "$PARTITION" -N -o '%G' 2>/dev/null \
  | grep -oE 'gpu[:a-z0-9]*:[0-9]+' \
  | awk -F: '{print $NF}' \
  | sort -n | tail -n1)
MAX_GPUS_PER_NODE="${MAX_GPUS_PER_NODE:-0}"

MODE=""
if [ "$NODES" -ge 2 ]; then
  MODE="inter-node (2 nodes x 1 GPU)"
  NCCL_NODES=2
  NCCL_TASKS_PER_NODE=1
  NCCL_GPUS=1
elif [ "$MAX_GPUS_PER_NODE" -ge 2 ]; then
  MODE="intra-node (1 node x $MAX_GPUS_PER_NODE GPUs)"
  NCCL_NODES=1
  NCCL_TASKS_PER_NODE=1
  NCCL_GPUS="$MAX_GPUS_PER_NODE"
else
  echo "SKIPPED: NCCL needs >=2 GPUs total; have $NODES node(s), max $MAX_GPUS_PER_NODE GPU(s)/node"
  exit 2
fi
echo "NCCL mode: $MODE"

# Probe for the NCCL binary on a compute node. We can't assume the login pod has
# it; we have to run inside a slurmd pod.
PROBE=$(srun -p "$PARTITION" --gres=gpu:1 --mem=256M -t 00:01:00 \
  bash -c "[ -x $NCCL_BIN ] && echo FOUND || echo MISSING" 2>&1 | tail -n1 | tr -d '[:space:]')
if [ "$PROBE" != "FOUND" ]; then
  echo "SKIPPED: $NCCL_BIN not present on compute node (got '$PROBE')"
  exit 2
fi

JOBID=$(sbatch --parsable -p "$PARTITION" \
  --nodes="$NCCL_NODES" --ntasks-per-node="$NCCL_TASKS_PER_NODE" \
  --gres=gpu:"$NCCL_GPUS" --mem=2G -t 00:05:00 \
  --wrap="srun --mpi=pmix $NCCL_BIN -b 8 -e 256M -f 2 -g $NCCL_GPUS" 2>&1)
if ! [[ "$JOBID" =~ ^[0-9]+$ ]]; then
  echo "FAIL: sbatch returned: $JOBID"
  exit 1
fi
echo "Submitted NCCL JobID=$JOBID"

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
  sleep 10
done

EXITCODE=$(sacct -j "$JOBID" -n -X -o ExitCode 2>/dev/null | head -n1 | tr -d '[:space:]')
echo "Final State=$STATE ExitCode=$EXITCODE"

if [ "$STATE" = "COMPLETED" ] && [ "$EXITCODE" = "0:0" ]; then
  echo "PASS: NCCL all_reduce_perf COMPLETED ($MODE)"
  exit 0
fi

echo "FAIL: state=$STATE exit=$EXITCODE"
exit 1
