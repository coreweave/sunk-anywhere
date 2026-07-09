#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Overcommit memory: submit a job with --mem=100G. No node in the budget
# profile has that much, so the job must stay PENDING with a resource reason.
# Assert reason matches one of Resources/NodeConfig/BadConstraints/PartitionConfig/ReqNodeNotAvail
# within WAIT seconds, then cancel the job.
#
# This catches regressions of BUG #9-style accounting where a node may advertise
# more RealMemory than it physically has.
#
# Precondition: >=1 node in $PARTITION.
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-cpu-workers}"
WAIT="${WAIT:-30}"

echo "=== 14-overcommit-mem (partition=$PARTITION wait=${WAIT}s) ==="

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if [ -z "$NODES" ] || [ "$NODES" = "0" ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

OUT=$(sbatch --parsable -p "$PARTITION" --mem=100G -t 00:03:00 --wrap='echo should not run' 2>&1)
JOBID=$(echo "$OUT" | head -n1 | tr -d '[:space:]')
if ! [[ "$JOBID" =~ ^[0-9]+$ ]]; then
  # Some sites reject at submit time — that's also a valid "enforcement" signal.
  if echo "$OUT" | grep -qiE 'memory|resources|invalid|configuration'; then
    echo "PASS: sbatch rejected 100G request at submit: $OUT"
    exit 0
  fi
  echo "FAIL: sbatch did not return a JobID and did not reject cleanly: $OUT"
  exit 1
fi
echo "Submitted JobID=$JOBID"

trap 'scancel "$JOBID" 2>/dev/null' EXIT

DEADLINE=$(( $(date +%s) + WAIT ))
REASON=""
STATE=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE=$(squeue -h -j "$JOBID" -o '%T' 2>/dev/null | tr -d '[:space:]')
  REASON=$(squeue -h -j "$JOBID" -o '%r' 2>/dev/null | tr -d '[:space:]')
  echo "  state=$STATE reason=$REASON"
  if [ "$STATE" = "PENDING" ] && [ -n "$REASON" ] && [ "$REASON" != "None" ]; then
    break
  fi
  sleep 3
done

case "$REASON" in
  Resources|NodeConfig|BadConstraints|PartitionConfig|ReqNodeNotAvail*|QOSMaxMemoryPerJob|MaxMemPerLimit|MemoryPerJobLimit)
    echo "PASS: job PENDING with resource-style reason ($REASON); enforcement works"
    exit 0
    ;;
esac

echo "FAIL: did not see expected pending reason (state=$STATE reason=$REASON)"
exit 1
