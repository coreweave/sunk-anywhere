#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Validate GCM (GPU Cluster Monitoring) health checks on GPU nodes.
# Run after deploying GCM via the setup-sunk-gpu-monitoring skill.
# Usage: bash 06-validate-gcm-health.sh

set -euo pipefail

echo "=== GCM Health Check Validation ==="
echo ""

# Find GPU nodes. Use the first provider label that actually returns
# nodes so this script runs on GKE, EKS, or bare-metal without
# needing a flag. Extend the list when adding providers.
GPU_NODES=""
for selector in \
    "cloud.google.com/gke-accelerator" \
    "eks.amazonaws.com/nodegroup=gpu-workers" \
    "node.coreweave.cloud/class=gpu" ; do
    GPU_NODES=$(kubectl get nodes -l "$selector" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    [ -n "$GPU_NODES" ] && break
done

if [ -z "$GPU_NODES" ]; then
  echo "No GPU nodes found. Skipping GCM validation."
  exit 0
fi

ALL_PASS=true
for node in $GPU_NODES; do
  echo "Node: $node"
  kubectl get node "$node" -o json 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
conditions = [c for c in data['status']['conditions'] if c['type'].startswith('Gcm')]
if not conditions:
    print('  No GCM conditions found. Is GCM deployed?')
else:
    for c in conditions:
        status = 'PASS' if c['status'] == 'False' else 'FAIL'
        print(f'  {c[\"type\"]}: {status} ({c[\"reason\"]})')
" 2>/dev/null
  echo ""
done

echo "=== Expected: 6 checks, all PASS ==="
echo "  GcmXidErrorsProblem, GcmSmiEccProblem, GcmSmiDisconnectedProblem,"
echo "  GcmProcZombieProblem, GcmDcgmiNvlinkStatusProblem, GcmDcgmiDiagProblem"
