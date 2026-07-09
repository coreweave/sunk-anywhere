#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Install cluster controllers for SUNK-on-EKS in dependency order.
# Order matters (Codex critique): AWS LB Controller must be ready before any NLB
# annotations take effect, or the login service hangs Pending. EBS CSI must be
# ready before PVCs bind. cert-manager must be ready before MOCO.
#
# Run AFTER setup-irsa.sh. Idempotent.
#
# Installs:
#   1. EBS CSI driver (managed EKS add-on)
#   2. EFS CSI driver (helm)
#   3. AWS Load Balancer Controller (helm)
#   4. cert-manager
#   5. MOCO MySQL operator
#
# Per docs/eks/conventions.md.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"

usage() {
  cat <<EOF
Usage: $0 [--cluster NAME] [--region REGION] [--profile PROFILE]
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

ACCOUNT_ID=$(aws sts get-caller-identity "${PROFILE_FLAG[@]}" --query Account --output text)
echo "==> Cluster: $CLUSTER_NAME, Region: $REGION, Account: $ACCOUNT_ID"

# -------------------------------------------------------------------
# 1. EBS CSI driver (managed EKS add-on)
# -------------------------------------------------------------------
echo "==> [1/5] EBS CSI driver"
EBS_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole-${CLUSTER_NAME}"

if aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver \
    --region "$REGION" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "    Add-on already installed, skipping."
else
  # --resolve-conflicts OVERWRITE: setup-irsa.sh pre-creates the SA with
  # managed-by=eksctl. Without OVERWRITE, the addon refuses to take ownership
  # and enters CREATE_FAILED with ConfigurationConflict on .metadata.labels.
  aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver \
    --region "$REGION" "${PROFILE_FLAG[@]}" \
    --service-account-role-arn "$EBS_ROLE_ARN" \
    --resolve-conflicts OVERWRITE \
    --tags Key=ManagedBy,Value=sunk-anywhere >/dev/null
  aws eks wait addon-active --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver \
    --region "$REGION" "${PROFILE_FLAG[@]}"
fi
kubectl wait --for=condition=Available -n kube-system deployment/ebs-csi-controller --timeout=5m

# -------------------------------------------------------------------
# 2. EFS CSI driver
# -------------------------------------------------------------------
echo "==> [2/5] EFS CSI driver"
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/ >/dev/null
helm repo update >/dev/null
helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=efs-csi-controller-sa \
  --wait --timeout 5m

# -------------------------------------------------------------------
# 3. AWS Load Balancer Controller
# -------------------------------------------------------------------
echo "==> [3/5] AWS Load Balancer Controller"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 5m

# -------------------------------------------------------------------
# 4. cert-manager
# -------------------------------------------------------------------
echo "==> [4/5] cert-manager"
CERT_MANAGER_VERSION="v1.15.3"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
kubectl wait --for=condition=Available -n cert-manager deployment/cert-manager --timeout=5m
kubectl wait --for=condition=Available -n cert-manager deployment/cert-manager-webhook --timeout=5m
kubectl wait --for=condition=Available -n cert-manager deployment/cert-manager-cainjector --timeout=5m

# -------------------------------------------------------------------
# 5. MOCO (MySQL operator)
# -------------------------------------------------------------------
# MOCO releases since ~v0.30 ship a single bundled manifest "moco.yaml"
# that contains the namespace, CRDs, and operator. The separate
# moco-crds.yaml asset was dropped upstream (404).
echo "==> [5/5] MOCO MySQL operator"
MOCO_VERSION="v0.34.0"
kubectl apply --server-side -f "https://github.com/cybozu-go/moco/releases/download/${MOCO_VERSION}/moco.yaml"
kubectl wait --for=condition=Available -n moco-system deployment/moco-controller --timeout=5m

# -------------------------------------------------------------------
# Verification
# -------------------------------------------------------------------
echo
echo "==> Verification"
FAILED=0
check() {
  if kubectl get "$@" >/dev/null 2>&1; then
    echo "    OK: $*"
  else
    echo "    FAIL: $*"; FAILED=$((FAILED+1))
  fi
}
check pods -n kube-system -l app=ebs-csi-controller
check pods -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver
check pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
check pods -n cert-manager
check pods -n moco-system

if [ "$FAILED" -gt 0 ]; then
  echo "ERROR: $FAILED controller(s) missing. Check kubectl logs."
  exit 1
fi

echo
echo "==> Done. Next: run infrastructure/eks/storage/*.sh and infrastructure/eks/observability/install.sh"
