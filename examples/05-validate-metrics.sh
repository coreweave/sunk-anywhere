#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Validate that SUNK metrics are flowing into Google Cloud Monitoring.
# Requires: gcloud CLI authenticated with access to the GCP project.
# Usage: PROJECT_ID=your-project-id bash 05-validate-metrics.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID environment variable}"

ACCESS_TOKEN=$(gcloud auth print-access-token)
BASE="https://monitoring.googleapis.com/v1/projects/${PROJECT_ID}/location/global/prometheus/api/v1/query"

query() {
  local q="$1"
  local label="$2"
  local result
  result=$(curl -s "${BASE}?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$q'))")" \
    -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    for r in results:
        cluster = r['metric'].get('cluster', 'unknown')
        print(f'  {cluster}: {r[\"value\"][1]}')
else:
    print('  (no data)')
" 2>/dev/null)
  echo "$label"
  echo "$result"
  echo ""
}

echo "=== SUNK Metrics Validation ==="
echo ""

query "slurm_nodes_total" "Slurm nodes (by cluster):"
query "slurm_queue_running" "Running jobs (by cluster):"
query "sum by (cluster) (slurm_partition_cpu_total)" "Total CPUs (by cluster):"
query "sum by (cluster) (slurm_partition_gpu_total)" "Total GPUs (by cluster):"
query "DCGM_FI_DEV_GPU_UTIL" "GPU utilization % (by cluster):"
query "problem_gauge{reason=~\".*CheckFailed\"}" "GCM failures (should be empty if healthy):"
query "slurm_job_state" "Job states (all clusters):"

echo "=== Done ==="
echo "View dashboards at: https://console.cloud.google.com/monitoring/dashboards?project=${PROJECT_ID}"
