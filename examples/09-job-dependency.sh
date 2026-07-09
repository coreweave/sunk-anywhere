#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Job dependency: B waits for A via --dependency=afterok:$A.
# Assert B starts AFTER A completes and both end COMPLETED.
#
# Precondition: >=1 node in $PARTITION.
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-240}"

echo "=== 09-job-dependency (partition=$PARTITION timeout=${TIMEOUT}s) ==="

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if [ -z "$NODES" ] || [ "$NODES" = "0" ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

JOBA=$(sbatch --parsable -p "$PARTITION" --mem=256M --cpus-per-task=1 -t 00:03:00 \
  --wrap='sleep 30' 2>&1)
if ! [[ "$JOBA" =~ ^[0-9]+$ ]]; then
  echo "FAIL: sbatch A returned: $JOBA"
  exit 1
fi
echo "JobA=$JOBA"

JOBB=$(sbatch --parsable -p "$PARTITION" --mem=256M --cpus-per-task=1 -t 00:03:00 \
  --dependency=afterok:"$JOBA" --wrap='echo B ran' 2>&1)
if ! [[ "$JOBB" =~ ^[0-9]+$ ]]; then
  echo "FAIL: sbatch B returned: $JOBB"
  scancel "$JOBA" 2>/dev/null
  exit 1
fi
echo "JobB=$JOBB depends on JobA=$JOBA"

trap 'scancel "$JOBA" "$JOBB" 2>/dev/null' EXIT

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE_A=$(sacct -j "$JOBA" -n -X -o State 2>/dev/null | head -n1 | tr -d '[:space:]')
  STATE_B=$(sacct -j "$JOBB" -n -X -o State 2>/dev/null | head -n1 | tr -d '[:space:]')
  case "$STATE_B" in
    COMPLETED|FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE|PREEMPTED)
      break
      ;;
  esac
  sleep 5
done

END_A=$(sacct -j "$JOBA" -n -X -o End 2>/dev/null | head -n1 | tr -d '[:space:]')
START_B=$(sacct -j "$JOBB" -n -X -o Start 2>/dev/null | head -n1 | tr -d '[:space:]')
EXIT_A=$(sacct -j "$JOBA" -n -X -o ExitCode 2>/dev/null | head -n1 | tr -d '[:space:]')
EXIT_B=$(sacct -j "$JOBB" -n -X -o ExitCode 2>/dev/null | head -n1 | tr -d '[:space:]')

echo "A: State=$STATE_A Exit=$EXIT_A End=$END_A"
echo "B: State=$STATE_B Exit=$EXIT_B Start=$START_B"

if [ "$STATE_A" != "COMPLETED" ] || [ "$EXIT_A" != "0:0" ]; then
  echo "FAIL: job A did not complete cleanly"
  exit 1
fi
if [ "$STATE_B" != "COMPLETED" ] || [ "$EXIT_B" != "0:0" ]; then
  echo "FAIL: job B did not complete cleanly"
  exit 1
fi

# Compare End(A) <= Start(B) lexicographically (sacct emits ISO-ish timestamps
# which sort correctly as strings for same-day times).
if [[ -n "$END_A" && -n "$START_B" && "$START_B" < "$END_A" ]]; then
  echo "FAIL: B started ($START_B) before A ended ($END_A)"
  exit 1
fi

echo "PASS: B started at/after A ended; both COMPLETED"
exit 0
