#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# ##############################################################################
# # WARNING: UNVALIDATED                                                      #
# # This script has NOT been tested on a real EKS cluster.                    #
# # If you deploy SUNK on EKS, please report what worked and what broke.      #
# ##############################################################################
#
# Patch EKS system DaemonSets with sunk.coreweave.com/lock NoExecute toleration.
# The SUNK operator applies this taint to any node running NodeSet pods.
# On EKS with shared nodes, this evicts system pods unless they tolerate it.

set -euo pipefail

LOCK_TOLERATION='{"key":"sunk.coreweave.com/lock","operator":"Exists","effect":"NoExecute"}'
PATCH="[{\"op\":\"add\",\"path\":\"/spec/template/spec/tolerations/-\",\"value\":$LOCK_TOLERATION}]"

echo "Patching EKS system DaemonSets in kube-system..."
for ds in aws-node ebs-csi-node kube-proxy; do
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
echo "Done. Verify with: kubectl get pods -n kube-system --no-headers | grep -v Running | grep -v Completed"
