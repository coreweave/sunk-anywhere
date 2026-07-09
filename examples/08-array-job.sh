#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Array job: submit 4 tasks, wait for all to finish, assert all COMPLETED.
#
# Precondition: >=1 node in $PARTITION.
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-240}"

echo "=== 08-array-job (partition=$PARTITION timeout=${TIMEOUT}s) ==="

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if [ -z "$NODES" ] || [ "$NODES" = "0" ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

JOBID=$(sbatch --parsable -p "$PARTITION" --array=1-4 --mem=256M --cpus-per-task=1 -t 00:03:00 \
  --wrap='echo task $SLURM_ARRAY_TASK_ID' 2>&1)
if ! [[ "$JOBID" =~ ^[0-9]+$ ]]; then
  echo "FAIL: sbatch did not return a JobID: $JOBID"
  exit 1
fi
echo "Submitted array JobID=$JOBID"

trap 'scancel "$JOBID" 2>/dev/null' EXIT

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  ACTIVE=$(squeue -h -j "$JOBID" 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "$ACTIVE" = "0" ] && break
  sleep 5
done

LINES=$(sacct -j "$JOBID" -n -X -o JobID,State,ExitCode 2>/dev/null)
echo "$LINES"

COMPLETED=$(echo "$LINES" | awk '$2=="COMPLETED" && $3=="0:0"' | wc -l | tr -d '[:space:]')
TOTAL=$(echo "$LINES" | grep -cv '^$')

if [ "$COMPLETED" = "4" ] && [ "$TOTAL" = "4" ]; then
  echo "PASS: all 4 array tasks COMPLETED 0:0"
  exit 0
fi

echo "FAIL: completed=$COMPLETED total=$TOTAL"
exit 1
