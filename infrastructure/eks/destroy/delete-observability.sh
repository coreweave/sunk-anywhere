#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Symmetric teardown for the observability stack installed by
# infrastructure/eks/observability/install.sh
#
# Removes: kube-prometheus-stack release, syncer PodMonitor in slurm ns,
# DCGM exporter DaemonSet, monitoring namespace.
#
# Idempotent: missing releases / resources are not errors.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBS_DIR="${SCRIPT_DIR}/../observability"

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
NAMESPACE="${MONITORING_NS:-monitoring}"
RELEASE="${RELEASE:-kube-prometheus-stack}"
SLURM_NAMESPACE="${SLURM_NAMESPACE:-tenant-slurm}"

usage() {
  cat <<EOF
Usage: $0 [--cluster NAME] [--region REGION] [--profile PROFILE]

Uninstalls kube-prometheus-stack, deletes DCGM exporter + syncer PodMonitor,
deletes the monitoring namespace.
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER_NAME="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown: $1"; usage;;
  esac
done

export AWS_PROFILE="${PROFILE:-${AWS_PROFILE:-}}"
export AWS_REGION="$REGION"

echo "==> Cluster: $CLUSTER_NAME, Region: $REGION, Namespace: $NAMESPACE"

echo "==> [1/4] helm uninstall $RELEASE -n $NAMESPACE"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || echo "    $RELEASE release not present, skipping"
else
  echo "    Namespace $NAMESPACE not present, skipping helm uninstall"
fi

echo "==> [2/4] Deleting sunk-syncer PodMonitor in $SLURM_NAMESPACE"
kubectl delete podmonitor sunk-syncer -n "$SLURM_NAMESPACE" --ignore-not-found

echo "==> [3/4] Deleting DCGM exporter"
if [ -f "${OBS_DIR}/dcgm-exporter.yaml" ]; then
  kubectl delete -f "${OBS_DIR}/dcgm-exporter.yaml" --ignore-not-found
else
  echo "    Manifest ${OBS_DIR}/dcgm-exporter.yaml not found; deleting by label as fallback"
  kubectl delete daemonset -l app=dcgm-exporter --all-namespaces --ignore-not-found 2>/dev/null || true
fi

echo "==> [4/4] Deleting namespace $NAMESPACE"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=5m

echo
echo "==> Done. Observability stack removed."
