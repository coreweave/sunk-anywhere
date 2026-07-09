#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Symmetric teardown for IRSA service accounts + IAM policies created by
# infrastructure/eks/setup-irsa.sh
#
# For each of the 3 controller IRSA pairings, eksctl deletes both the
# ServiceAccount and the IAM role in a single call. Customer-managed IAM
# policies (which eksctl does NOT own) are deleted separately by ARN.
#
# Idempotent: missing service accounts / roles / policies are not errors.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"

usage() {
  cat <<EOF
Usage: $0 [--cluster NAME] [--region REGION] [--profile PROFILE]

Deletes the 3 IRSA service accounts (ebs-csi-controller-sa,
efs-csi-controller-sa, aws-load-balancer-controller) and the 2
customer-managed IAM policies (EFS, ALB) created by setup-irsa.sh.

The IAM roles are deleted as a side effect of eksctl delete iamserviceaccount.
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

ACCOUNT_ID=$(aws sts get-caller-identity "${PROFILE_FLAG[@]}" --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
  echo "ERROR: unable to determine AWS account id; check profile/credentials"
  exit 2
fi
echo "==> AWS Account: $ACCOUNT_ID"

delete_sa() {
  local ns="$1" name="$2"
  echo "==> Deleting iamserviceaccount $ns/$name"
  if eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" \
      ${PROFILE:+--profile "$PROFILE"} \
      --namespace "$ns" --name "$name" >/dev/null 2>&1; then
    eksctl delete iamserviceaccount \
      --cluster "$CLUSTER_NAME" --region "$REGION" \
      ${PROFILE:+--profile "$PROFILE"} \
      --namespace "$ns" --name "$name" || \
      echo "    WARN: eksctl delete iamserviceaccount $ns/$name returned non-zero"
  else
    echo "    iamserviceaccount $ns/$name not present, skipping"
  fi
}

delete_policy() {
  local policy_name="$1"
  local arn="arn:aws:iam::${ACCOUNT_ID}:policy/${policy_name}"
  echo "==> Deleting IAM policy $policy_name"
  if ! aws iam get-policy --policy-arn "$arn" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
    echo "    Policy $policy_name not present, skipping"
    return 0
  fi
  # Detach any entities still attached before deleting (should be none if eksctl ran cleanly).
  local attached
  attached=$(aws iam list-entities-for-policy --policy-arn "$arn" "${PROFILE_FLAG[@]}" \
    --query "PolicyRoles[].RoleName" --output text 2>/dev/null || echo "")
  for role in $attached; do
    echo "    Detaching policy from role $role"
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" "${PROFILE_FLAG[@]}" 2>/dev/null || true
  done
  # Delete non-default policy versions (required before delete-policy).
  local versions
  versions=$(aws iam list-policy-versions --policy-arn "$arn" "${PROFILE_FLAG[@]}" \
    --query "Versions[?!IsDefaultVersion].VersionId" --output text 2>/dev/null || echo "")
  for v in $versions; do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" "${PROFILE_FLAG[@]}" 2>/dev/null || true
  done
  aws iam delete-policy --policy-arn "$arn" "${PROFILE_FLAG[@]}" 2>/dev/null || \
    echo "    WARN: delete-policy $policy_name returned non-zero"
}

# -------------------------------------------------------------------
# ServiceAccounts (+ their IAM roles, managed by eksctl)
# -------------------------------------------------------------------
delete_sa kube-system ebs-csi-controller-sa
delete_sa kube-system efs-csi-controller-sa
delete_sa kube-system aws-load-balancer-controller

# -------------------------------------------------------------------
# Customer-managed IAM policies (not deleted by eksctl)
# -------------------------------------------------------------------
delete_policy "AmazonEKS_EFS_CSI_Driver_Policy-${CLUSTER_NAME}"
delete_policy "AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"

echo
echo "==> Done. IRSA service accounts + policies removed."
