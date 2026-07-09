#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Basic srun smoke test: single-node hostname.
#
# Precondition: at least 1 compute node Ready in $PARTITION (default cpu-workers).
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.
# Works on EKS and GKE. Override PARTITION/TIMEOUT via env vars.
#
# Runs inside slurm-login-0 sshd container.
#   kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- bash /home/examples/01-basic-srun.sh

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-60}"

echo "=== 01-basic-srun (partition=$PARTITION timeout=${TIMEOUT}s) ==="

NODES=$(sinfo -h -p "$PARTITION" -o '%D' 2>/dev/null | tr -d '[:space:]')
if [ -z "$NODES" ] || [ "$NODES" = "0" ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

OUT=$(timeout "$TIMEOUT" srun -p "$PARTITION" -N1 --mem=256M hostname 2>&1)
RC=$?
echo "$OUT"

if [ $RC -eq 0 ] && [ -n "$OUT" ]; then
  echo "PASS: srun returned hostname in partition $PARTITION"
  exit 0
fi

echo "FAIL: srun exit=$RC"
exit 1
