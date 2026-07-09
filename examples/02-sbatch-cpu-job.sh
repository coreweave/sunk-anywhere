#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# sbatch CPU smoke test: submit a wrapped job, poll sacct, assert COMPLETED.
#
# Precondition: >=1 node in $PARTITION.
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.
# Note: --mem=256M is explicit because the budget profile's DefMemPerCPU=3000
# would otherwise request 3 GiB per CPU, which m5.large (8 GiB) cannot satisfy
# comfortably alongside system reserve. See deploy-notes BUG #9.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-180}"

echo "=== 02-sbatch-cpu-job (partition=$PARTITION timeout=${TIMEOUT}s) ==="

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if [ -z "$NODES" ] || [ "$NODES" = "0" ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

JOBID=$(sbatch --parsable -p "$PARTITION" --mem=256M --cpus-per-task=1 -t 00:03:00 \
  --wrap='echo hello; hostname; sleep 60' 2>&1)
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
  echo "PASS: job $JOBID completed cleanly"
  exit 0
fi

echo "FAIL: state=$STATE exit=$EXITCODE"
exit 1
