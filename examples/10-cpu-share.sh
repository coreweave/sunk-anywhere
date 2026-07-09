#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# CPU sharing: submit enough tiny concurrent jobs that at least one node must
# carry >=2 of them. Slurm's default scheduler spreads across nodes first;
# with NODES+1 small jobs, pigeonhole says some node gets two.
#
# Precondition: >=1 node in $PARTITION with >=2 free CPUs and enough RAM for
#   small jobs (--mem=64M fits on tiny m5.large RealMemory=512M nodes).
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-180}"
JOB_MEM="${JOB_MEM:-64M}"

echo "=== 10-cpu-share (partition=$PARTITION timeout=${TIMEOUT}s mem=$JOB_MEM) ==="

# Use sinfo -N (one line per node) and de-dupe, so we don't trip over
# partition-view quirks that can return 0 or blank on %D.
NODES=$(sinfo -h -N -p "$PARTITION" -o '%N' 2>/dev/null | sort -u | grep -cv '^$')
if [ -z "$NODES" ] || [ "$NODES" -eq 0 ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

N_JOBS=$(( NODES + 1 ))
JOBS=()
for i in $(seq 1 "$N_JOBS"); do
  JID=$(sbatch --parsable -p "$PARTITION" --mem="$JOB_MEM" --cpus-per-task=1 -t 00:03:00 \
    --wrap='sleep 90' 2>&1)
  if ! [[ "$JID" =~ ^[0-9]+$ ]]; then
    echo "FAIL: sbatch #$i returned: $JID"
    for j in "${JOBS[@]}"; do scancel "$j" 2>/dev/null; done
    exit 1
  fi
  JOBS+=("$JID")
done
echo "Submitted ${#JOBS[@]} jobs: ${JOBS[*]}"

trap 'for j in "${JOBS[@]}"; do scancel "$j" 2>/dev/null; done' EXIT

# Wait until every job is RUNNING AND has a non-empty node assignment.
# A job can briefly be RUNNING before squeue exposes %N; without this double
# condition we were collecting empty node names and wrongly FAIL'ing.
DEADLINE=$(( $(date +%s) + TIMEOUT ))
ALL_PLACED=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  PLACED=0
  PENDING=""
  for j in "${JOBS[@]}"; do
    S=$(squeue -h -j "$j" -o '%T' 2>/dev/null | tr -d '[:space:]')
    N=$(squeue -h -j "$j" -o '%N' 2>/dev/null | tr -d '[:space:]')
    if [ "$S" = "RUNNING" ] && [ -n "$N" ]; then
      PLACED=$((PLACED+1))
    else
      PENDING="$PENDING $j($S)"
    fi
  done
  if [ "$PLACED" -eq "${#JOBS[@]}" ]; then
    ALL_PLACED=1
    break
  fi
  sleep 3
done

if [ "$ALL_PLACED" -ne 1 ]; then
  echo "FAIL: not all jobs reached RUNNING with a node before timeout. Pending:$PENDING"
  # Dump queue for debug, then fall through — trap scancels everything.
  squeue -u "$(whoami)" 2>/dev/null || true
  exit 1
fi

# Collect node assignments via squeue, falling back to scontrol if empty.
declare -A NODE_COUNT
for j in "${JOBS[@]}"; do
  N=$(squeue -h -j "$j" -o '%N' 2>/dev/null | tr -d '[:space:]')
  if [ -z "$N" ]; then
    N=$(scontrol show job "$j" 2>/dev/null | awk -F= '/NodeList=/ {print $2; exit}' | awk '{print $1}')
  fi
  echo "  job $j on $N"
  if [ -n "$N" ] && [ "$N" != "(null)" ]; then
    NODE_COUNT["$N"]=$(( ${NODE_COUNT["$N"]:-0} + 1 ))
  fi
done

MAX=0
for n in "${!NODE_COUNT[@]}"; do
  if [ "${NODE_COUNT[$n]}" -gt "$MAX" ]; then
    MAX="${NODE_COUNT[$n]}"
  fi
done

if [ "$MAX" -ge 2 ]; then
  echo "PASS: at least one node carried >=2 jobs (max=$MAX)"
  exit 0
fi

echo "FAIL: every job landed on its own node; CPU sharing did not happen"
exit 1
