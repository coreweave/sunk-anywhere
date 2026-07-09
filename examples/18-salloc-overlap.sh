#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Interactive salloc + --overlap: exercise the interactive-debugging workflow
# where a user grabs an allocation with salloc and then fires off multiple
# srun commands that share the reservation (--overlap) instead of queueing.
#
# Driven non-interactively:
#   1. salloc --no-shell  -> hold a background allocation
#   2. srun --overlap --jobid=$JID ... three times, sequentially
#   3. Assert all three ran on the allocation's node, and that only ONE
#      JobId ever existed (steps share the parent allocation)
#   4. scancel to release
#
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-180}"

echo "=== 18-salloc-overlap (partition=$PARTITION timeout=${TIMEOUT}s) ==="

NODES=$(sinfo -h -N -p "$PARTITION" -o '%N' 2>/dev/null | sort -u | grep -cv '^$')
if [ -z "$NODES" ] || [ "$NODES" -eq 0 ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

# salloc --no-shell returns once the allocation is granted without spawning
# an interactive shell. Emits "salloc: Granted job allocation <JID>" on stderr.
ALLOC_OUT=$(salloc --no-shell -p "$PARTITION" --mem=128M --cpus-per-task=1 -t 00:05:00 2>&1)
RC=$?
echo "$ALLOC_OUT"
if [ $RC -ne 0 ]; then
  echo "FAIL: salloc returned $RC"
  exit 1
fi

JID=$(echo "$ALLOC_OUT" | grep -oE 'Granted job allocation [0-9]+' | awk '{print $NF}')
if [ -z "$JID" ]; then
  echo "FAIL: could not parse JobId from salloc output"
  exit 1
fi
echo "Allocation JobId=$JID"

trap 'scancel "$JID" 2>/dev/null' EXIT

# Wait for the allocation to be in RUNNING with a node assigned.
DEADLINE=$(( $(date +%s) + 60 ))
ALLOC_NODE=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  S=$(squeue -h -j "$JID" -o '%T' 2>/dev/null | tr -d '[:space:]')
  N=$(squeue -h -j "$JID" -o '%N' 2>/dev/null | tr -d '[:space:]')
  if [ "$S" = "RUNNING" ] && [ -n "$N" ]; then
    ALLOC_NODE="$N"
    break
  fi
  sleep 3
done

if [ -z "$ALLOC_NODE" ]; then
  echo "FAIL: allocation never reached RUNNING"
  exit 1
fi
echo "Allocated node: $ALLOC_NODE"

# Run three overlapping steps inside the same allocation.
STEP_NODES=()
for i in 1 2 3; do
  OUT=$(srun --overlap --jobid="$JID" -n1 hostname 2>&1)
  RC=$?
  if [ $RC -ne 0 ]; then
    echo "FAIL: srun --overlap step $i returned $RC: $OUT"
    exit 1
  fi
  STEP_NODES+=("$OUT")
  echo "  step $i ran on: $OUT"
done

# Every step should have landed on the allocation's node.
for n in "${STEP_NODES[@]}"; do
  if [ "$n" != "$ALLOC_NODE" ]; then
    echo "FAIL: step ran on $n but allocation was on $ALLOC_NODE"
    exit 1
  fi
done

# sacct should show one parent JobId with .0, .1, .2 step records.
STEPS=$(sacct -j "$JID" -n -P -o JobID 2>/dev/null | grep -c "^${JID}\.")
if [ "$STEPS" -lt 3 ]; then
  echo "FAIL: expected >=3 step records in sacct for JobId=$JID, got $STEPS"
  sacct -j "$JID" -n -P -o JobID,State,NodeList 2>/dev/null
  exit 1
fi

echo "PASS: 3 srun --overlap steps shared allocation $JID on $ALLOC_NODE"
exit 0
