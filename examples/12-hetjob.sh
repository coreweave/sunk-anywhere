#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Heterogeneous job: two components with different resource requests submitted
# as one sbatch using the ":" separator (Slurm native het-job syntax).
# Assert both components run to completion.
#
# Precondition: >=2 nodes in $PARTITION (het-jobs typically need one node per
# component when --exclusive-per-component or differing resources force it; the
# safer gate is >=2 nodes).
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.
#
# Syntax reference: sbatch pack groups are defined by separating arg sets with
# ":". Each component becomes a sub-JobID printed as "A+0", "A+1", etc.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-240}"

echo "=== 12-hetjob (partition=$PARTITION timeout=${TIMEOUT}s) ==="

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if ! [[ "$NODES" =~ ^[0-9]+$ ]] || [ "$NODES" -lt 2 ]; then
  echo "SKIPPED: need >=2 nodes in $PARTITION, have ${NODES:-0}"
  exit 2
fi

OUT=$(sbatch --parsable \
  -p "$PARTITION" --mem=256M --cpus-per-task=1 -t 00:03:00 \
    --wrap='echo component-0 $(hostname); sleep 20' \
  : \
  -p "$PARTITION" --mem=512M --cpus-per-task=1 -t 00:03:00 \
    --wrap='echo component-1 $(hostname); sleep 20' 2>&1)
RC=$?
echo "sbatch: $OUT"
if [ $RC -ne 0 ]; then
  echo "FAIL: sbatch hetjob submit failed (rc=$RC)"
  exit 1
fi

JOBID=$(echo "$OUT" | head -n1 | tr -d '[:space:]' | cut -d';' -f1)
if ! [[ "$JOBID" =~ ^[0-9]+$ ]]; then
  echo "FAIL: could not parse hetjob ID from: $OUT"
  exit 1
fi
echo "Het JobID=$JOBID (components $JOBID+0 and $JOBID+1)"

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

if [ "$COMPLETED" -ge 2 ]; then
  echo "PASS: both hetjob components COMPLETED 0:0"
  exit 0
fi

echo "FAIL: only $COMPLETED components COMPLETED 0:0"
exit 1
