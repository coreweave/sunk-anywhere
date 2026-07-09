#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Exclusive jobs: two jobs forced onto different nodes. Uses `--mem` set to
# >50% of node RealMemory so two jobs cannot fit on the same node even when
# the partition has OverSubscribe=FORCE:N (which would otherwise let them
# share). This makes the test compatible with examples/10-cpu-share.sh
# which requires OverSubscribe=FORCE:2.
#
# Precondition: >=2 nodes in $PARTITION.
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-180}"

echo "=== 11-different-nodes (partition=$PARTITION timeout=${TIMEOUT}s) ==="

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if ! [[ "$NODES" =~ ^[0-9]+$ ]] || [ "$NODES" -lt 2 ]; then
  echo "SKIPPED: need >=2 nodes in $PARTITION, have ${NODES:-0}"
  exit 2
fi

# Read the smallest RealMemory across partition nodes; ask for 60% of it.
REAL_MEM=$(sinfo -h -N -p "$PARTITION" -o '%m' 2>/dev/null | sort -n | head -1 | tr -d '[:space:]')
if ! [[ "$REAL_MEM" =~ ^[0-9]+$ ]] || [ "$REAL_MEM" -lt 100 ]; then
  echo "SKIPPED: could not read RealMemory for $PARTITION (got '$REAL_MEM')"
  exit 2
fi
JOB_MEM=$(( REAL_MEM * 6 / 10 ))
echo "Node RealMemory=$REAL_MEM MB; requesting --mem=${JOB_MEM}M per job"

J1=$(sbatch --parsable -p "$PARTITION" --exclusive --mem="${JOB_MEM}M" -t 00:03:00 \
  --wrap='sleep 60' 2>&1)
J2=$(sbatch --parsable -p "$PARTITION" --exclusive --mem="${JOB_MEM}M" -t 00:03:00 \
  --wrap='sleep 60' 2>&1)
if ! [[ "$J1" =~ ^[0-9]+$ ]] || ! [[ "$J2" =~ ^[0-9]+$ ]]; then
  echo "FAIL: sbatch returned J1=$J1 J2=$J2"
  scancel "$J1" "$J2" 2>/dev/null
  exit 1
fi
echo "J1=$J1 J2=$J2"

trap 'scancel "$J1" "$J2" 2>/dev/null' EXIT

DEADLINE=$(( $(date +%s) + TIMEOUT ))
N1=""; N2=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  S1=$(squeue -h -j "$J1" -o '%T' 2>/dev/null | tr -d '[:space:]')
  S2=$(squeue -h -j "$J2" -o '%T' 2>/dev/null | tr -d '[:space:]')
  N1=$(squeue -h -j "$J1" -o '%N' 2>/dev/null | tr -d '[:space:]')
  N2=$(squeue -h -j "$J2" -o '%N' 2>/dev/null | tr -d '[:space:]')
  if [ "$S1" = "RUNNING" ] && [ "$S2" = "RUNNING" ] && [ -n "$N1" ] && [ -n "$N2" ]; then
    break
  fi
  sleep 5
done

echo "J1 on $N1, J2 on $N2"
if [ -z "$N1" ] || [ -z "$N2" ]; then
  echo "FAIL: could not capture node assignments (N1=$N1 N2=$N2)"
  exit 1
fi
if [ "$N1" != "$N2" ]; then
  echo "PASS: exclusive jobs on different nodes ($N1, $N2)"
  exit 0
fi

echo "FAIL: both exclusive jobs on the same node ($N1); scheduler did not honor --exclusive"
exit 1
