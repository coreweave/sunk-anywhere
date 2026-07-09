#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Symmetric teardown for cluster controllers installed by
# infrastructure/eks/install-controllers.sh
#
# Uninstalls (reverse order of install):
#   1. MOCO (moco-system)
#   2. cert-manager (upstream manifest)
#   3. AWS Load Balancer Controller (kube-system)
#   4. EFS CSI driver (kube-system)
#   5. EBS CSI driver EKS managed add-on
#
# Idempotent: missing releases/add-ons are not errors.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.3}"

usage() {
  cat <<EOF
Usage: $0 [--cluster NAME] [--region REGION] [--profile PROFILE]

Uninstalls MOCO, cert-manager, AWS Load Balancer Controller, EFS CSI driver,
and the aws-ebs-csi-driver EKS add-on. Idempotent.
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

PROFILE_FLAG=()
if [ -n "$PROFILE" ]; then PROFILE_FLAG=(--profile "$PROFILE"); fi

echo "==> Cluster: $CLUSTER_NAME, Region: $REGION, Profile: ${PROFILE:-default}"

# -------------------------------------------------------------------
# 1. MOCO
# -------------------------------------------------------------------
echo "==> [1/5] Uninstalling MOCO"
helm uninstall moco -n moco-system 2>/dev/null || echo "    moco release not present, skipping"
kubectl delete namespace moco-system --ignore-not-found --timeout=3m

# -------------------------------------------------------------------
# 2. cert-manager
# -------------------------------------------------------------------
echo "==> [2/5] Uninstalling cert-manager"
kubectl delete -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
  --ignore-not-found --timeout=5m || echo "    WARN: cert-manager delete returned non-zero; check kubectl for stuck resources"

# -------------------------------------------------------------------
# 3. AWS Load Balancer Controller
# -------------------------------------------------------------------
echo "==> [3/5] Uninstalling AWS Load Balancer Controller"
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || \
  echo "    aws-load-balancer-controller release not present, skipping"

# -------------------------------------------------------------------
# 4. EFS CSI driver
# -------------------------------------------------------------------
echo "==> [4/5] Uninstalling EFS CSI driver"
helm uninstall aws-efs-csi-driver -n kube-system 2>/dev/null || \
  echo "    aws-efs-csi-driver release not present, skipping"

# -------------------------------------------------------------------
# 5. EBS CSI driver (managed EKS add-on)
# -------------------------------------------------------------------
echo "==> [5/5] Deleting aws-ebs-csi-driver EKS add-on"
if aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver \
    --region "$REGION" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  aws eks delete-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver \
    --region "$REGION" "${PROFILE_FLAG[@]}" >/dev/null
  echo "    Waiting for add-on to be deleted..."
  aws eks wait addon-deleted --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver \
    --region "$REGION" "${PROFILE_FLAG[@]}" 2>/dev/null || \
    echo "    WARN: addon-deleted wait returned non-zero; verify manually"
else
  echo "    aws-ebs-csi-driver add-on not present, skipping"
fi

echo
echo "==> Done. Controllers removed."
