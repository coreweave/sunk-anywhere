#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# ##############################################################################
# # WARNING: UNVALIDATED                                                      #
# # This script is a template for bare-metal/custom Kubernetes clusters.      #
# # You MUST audit your DaemonSets and adjust the list below for your setup.  #
# ##############################################################################
#
# Patch DaemonSets with sunk.coreweave.com/lock NoExecute toleration.
# The SUNK operator applies this taint to any node running NodeSet pods.
# On clusters with shared nodes, this evicts system pods unless they tolerate it.
#
# On bare-metal you control all DaemonSets. This script lists all DaemonSets
# across the cluster and provides a template for patching each one.

set -euo pipefail

LOCK_TOLERATION='{"key":"sunk.coreweave.com/lock","operator":"Exists","effect":"NoExecute"}'
PATCH="[{\"op\":\"add\",\"path\":\"/spec/template/spec/tolerations/-\",\"value\":$LOCK_TOLERATION}]"

echo "=== Listing all DaemonSets that may need the lock taint toleration ==="
echo ""
kubectl get ds --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled
echo ""

echo "=== Patching common system DaemonSets ==="
echo ""

echo "Patching kube-system DaemonSets..."
for ds in kube-proxy; do
  kubectl -n kube-system patch daemonset "$ds" --type=json -p "$PATCH" 2>/dev/null && echo "  $ds: patched" || echo "  $ds: skipped (already patched or not found)"
done

echo ""
echo "Patching cert-manager..."
for deploy in cert-manager cert-manager-cainjector cert-manager-webhook; do
  kubectl patch deployment "$deploy" -n cert-manager --type=json -p "$PATCH" 2>/dev/null && echo "  $deploy: patched" || echo "  $deploy: skipped"
done

echo ""
echo "Patching moco-controller..."
kubectl patch deployment moco-controller -n moco-system --type=json -p "$PATCH" 2>/dev/null && echo "  moco-controller: patched" || echo "  moco-controller: skipped"

echo ""
echo "=== Template for patching additional DaemonSets ==="
echo ""
echo "Review the list above and patch any DaemonSet that runs on compute/GPU nodes:"
echo ""
echo '  kubectl -n <namespace> patch daemonset <name> --type=json -p='"'"'['
echo '    {"op": "add", "path": "/spec/template/spec/tolerations/-",'
echo '     "value": {"key": "sunk.coreweave.com/lock", "operator": "Exists", "effect": "NoExecute"}}'
echo '  ]'"'"
echo ""
echo "Common candidates on bare-metal clusters:"
echo "  - NVIDIA device plugin DaemonSet"
echo "  - Network plugin DaemonSets (Calico, Cilium, Flannel)"
echo "  - Storage CSI node DaemonSets"
echo "  - Monitoring agents (node-exporter, DCGM exporter)"
echo ""
echo "Done. Verify with: kubectl get pods --all-namespaces --no-headers | grep -v Running | grep -v Completed"
