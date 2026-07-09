#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Patch GCM DaemonSet for GKE COS (Container-Optimized OS) nodes.
#
# On GKE, the NVIDIA driver is installed at /home/kubernetes/bin/nvidia/
# rather than /usr/local/nvidia/. GCM health checks need:
#   1. NVML library (libnvidia-ml.so) for check-nvidia-smi
#   2. nv-hostengine running for check-dcgmi
#   3. DCGM diagnostic plugins (symlinked from cudaless)
#   4. GPU persistence mode enabled
#
# This script patches the GCM DaemonSet to handle all four.
# Run after: helm install gcm oci://ghcr.io/facebookresearch/charts/gcm

set -euo pipefail

NAMESPACE="${GCM_NAMESPACE:-kube-system}"
DAEMONSET="${GCM_DAEMONSET:-gcm-health-checks}"

echo "Patching $DAEMONSET in $NAMESPACE for GKE..."

kubectl patch ds "$DAEMONSET" -n "$NAMESPACE" --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "LD_LIBRARY_PATH",
      "value": "/usr/local/nvidia/lib64:/host/home/kubernetes/bin/nvidia/lib64"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "PATH",
      "value": "/usr/local/nvidia/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/host/home/kubernetes/bin/nvidia/bin"
    }
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/command",
    "value": ["/bin/sh", "-c"]
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/args",
    "value": [
      "NVIDIA_LIB=/host/home/kubernetes/bin/nvidia/lib64; if [ -f ${NVIDIA_LIB}/libnvidia-ml.so ]; then nv-hostengine -n -b ALL >/dev/null 2>&1 & ln -sf /usr/libexec/datacenter-gpu-manager-4/plugins/cudaless /usr/libexec/datacenter-gpu-manager-4/plugins/cuda13 2>/dev/null; /host/home/kubernetes/bin/nvidia/bin/nvidia-smi -pm 1 >/dev/null 2>&1; sleep 2; echo \"GPU node: nv-hostengine started, persistence mode enabled\"; fi; exec /usr/local/bin/node-problem-detector --logtostderr --config.custom-plugin-monitor=/config/gcm_monitor.json --prometheus-address=0.0.0.0 --prometheus-port=20357 --port=0"
    ]
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "nvidia-libs",
      "hostPath": {
        "path": "/home/kubernetes/bin/nvidia/lib64",
        "type": "DirectoryOrCreate"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "nvidia-libs",
      "mountPath": "/usr/local/nvidia/lib64",
      "readOnly": true
    }
  }
]'

echo "Waiting for rollout..."
kubectl rollout status ds/"$DAEMONSET" -n "$NAMESPACE" --timeout=120s

echo ""
echo "Verifying GCM pods..."
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=gcm -o wide

echo ""
echo "Done. Health checks run every 5 minutes. Check status with:"
echo "  kubectl get node <GPU_NODE> -o json | jq '.status.conditions[] | select(.type | test(\"Gcm\"))'"
