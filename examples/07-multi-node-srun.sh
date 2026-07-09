#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Multi-node srun: assert 2 distinct hostnames come back.
#
# Precondition: >=2 nodes in $PARTITION.
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-120}"

echo "=== 07-multi-node-srun (partition=$PARTITION timeout=${TIMEOUT}s) ==="

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if ! [[ "$NODES" =~ ^[0-9]+$ ]] || [ "$NODES" -lt 2 ]; then
  echo "SKIPPED: need >=2 nodes in $PARTITION, have ${NODES:-0}"
  exit 2
fi

OUT=$(timeout "$TIMEOUT" srun -p "$PARTITION" -N 2 --ntasks-per-node=1 --mem=256M hostname 2>&1)
RC=$?
echo "$OUT"

DISTINCT=$(echo "$OUT" | sort -u | grep -cv '^$')
if [ $RC -eq 0 ] && [ "$DISTINCT" -ge 2 ]; then
  echo "PASS: got $DISTINCT distinct hostnames"
  exit 0
fi

echo "FAIL: srun exit=$RC distinct_hostnames=$DISTINCT"
exit 1
