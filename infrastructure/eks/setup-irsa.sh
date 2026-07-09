#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Set up OIDC provider + IRSA roles for SUNK-on-EKS controllers.
# Must run BEFORE install-controllers.sh. Idempotent.
#
# Creates:
#   1. OIDC provider association (eksctl utils associate-iam-oidc-provider)
#   2. IAM roles + ServiceAccounts for:
#      - kube-system/ebs-csi-controller-sa (AmazonEBSCSIDriverPolicy)
#      - kube-system/efs-csi-controller-sa (custom EFS policy)
#      - kube-system/aws-load-balancer-controller (custom ALB policy from AWS GitHub)
#
# Per docs/eks/conventions.md. See eks-deployment-research.md section H for background.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
DRY_RUN="${DRY_RUN:-false}"

usage() {
  cat <<EOF
Usage: $0 [--cluster NAME] [--region REGION] [--profile PROFILE] [--dry-run]

Options:
  --cluster   EKS cluster name (default: sunk-eks, from \$CLUSTER_NAME)
  --region    AWS region (default: us-east-1)
  --profile   AWS CLI profile (default: \$AWS_PROFILE)
  --dry-run   Print planned actions, don't create resources
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER_NAME="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

PROFILE_FLAG=()
if [ -n "$PROFILE" ]; then PROFILE_FLAG=(--profile "$PROFILE"); fi

echo "==> Cluster: $CLUSTER_NAME, Region: $REGION, Profile: ${PROFILE:-default}"

# Verify prerequisites
for cmd in aws eksctl jq kubectl curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 2; }
done

# Verify cluster exists
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "ERROR: Cluster $CLUSTER_NAME not found in $REGION. Run create-cluster.sh first."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity "${PROFILE_FLAG[@]}" --query Account --output text)
echo "==> AWS Account: $ACCOUNT_ID"

run() {
  if $DRY_RUN; then
    echo "  [DRY] $*"
  else
    "$@"
  fi
}

# -------------------------------------------------------------------
# 1. OIDC provider
# -------------------------------------------------------------------
echo "==> [1/4] Associating OIDC provider"
OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" "${PROFILE_FLAG[@]}" \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID="${OIDC_ISSUER##*/}"
echo "    OIDC issuer: $OIDC_ISSUER"

if aws iam list-open-id-connect-providers "${PROFILE_FLAG[@]}" 2>/dev/null | grep -q "$OIDC_ID"; then
  echo "    OIDC provider already associated, skipping."
else
  run eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" --region "$REGION" \
    ${PROFILE:+--profile "$PROFILE"} \
    --approve
fi

# -------------------------------------------------------------------
# 2. EBS CSI driver role
# -------------------------------------------------------------------
echo "==> [2/4] Creating IRSA role for EBS CSI driver"
EBS_ROLE="AmazonEKS_EBS_CSI_DriverRole-${CLUSTER_NAME}"
if aws iam get-role --role-name "$EBS_ROLE" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "    Role $EBS_ROLE exists, skipping."
else
  run eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$REGION" \
    ${PROFILE:+--profile "$PROFILE"} \
    --namespace kube-system \
    --name ebs-csi-controller-sa \
    --role-name "$EBS_ROLE" \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
    --tags "ManagedBy=sunk-anywhere,Environment=dev" \
    --approve --override-existing-serviceaccounts
fi

# -------------------------------------------------------------------
# 3. EFS CSI driver role
# -------------------------------------------------------------------
echo "==> [3/4] Creating IRSA role for EFS CSI driver"
EFS_ROLE="AmazonEKS_EFS_CSI_DriverRole-${CLUSTER_NAME}"

EFS_POLICY_JSON=$(cat <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:CreateAccessPoint",
        "elasticfilesystem:TagResource"
      ],
      "Resource": "*",
      "Condition": { "StringLike": { "aws:RequestTag/efs.csi.aws.com/cluster": "true" } }
    },
    {
      "Effect": "Allow",
      "Action": "elasticfilesystem:DeleteAccessPoint",
      "Resource": "*",
      "Condition": { "StringEquals": { "aws:ResourceTag/efs.csi.aws.com/cluster": "true" } }
    }
  ]
}
POLICY
)

EFS_POLICY_NAME="AmazonEKS_EFS_CSI_Driver_Policy-${CLUSTER_NAME}"
EFS_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${EFS_POLICY_NAME}"
if aws iam get-policy --policy-arn "$EFS_POLICY_ARN" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "    Policy $EFS_POLICY_NAME exists, skipping."
else
  run aws iam create-policy \
    --policy-name "$EFS_POLICY_NAME" \
    --policy-document "$EFS_POLICY_JSON" \
    --tags Key=ManagedBy,Value=sunk-anywhere \
    "${PROFILE_FLAG[@]}"
fi

if aws iam get-role --role-name "$EFS_ROLE" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "    Role $EFS_ROLE exists, skipping."
else
  run eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$REGION" \
    ${PROFILE:+--profile "$PROFILE"} \
    --namespace kube-system \
    --name efs-csi-controller-sa \
    --role-name "$EFS_ROLE" \
    --attach-policy-arn "$EFS_POLICY_ARN" \
    --tags "ManagedBy=sunk-anywhere" \
    --approve --override-existing-serviceaccounts
fi

# -------------------------------------------------------------------
# 4. AWS Load Balancer Controller role
# -------------------------------------------------------------------
echo "==> [4/4] Creating IRSA role for AWS Load Balancer Controller"
ALB_ROLE="AmazonEKS_LoadBalancer_ControllerRole-${CLUSTER_NAME}"
ALB_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
ALB_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${ALB_POLICY_NAME}"

if aws iam get-policy --policy-arn "$ALB_POLICY_ARN" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "    Policy $ALB_POLICY_NAME exists, skipping."
else
  TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
  curl -sL https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json -o "$TMPDIR/alb-policy.json"
  run aws iam create-policy \
    --policy-name "$ALB_POLICY_NAME" \
    --policy-document "file://$TMPDIR/alb-policy.json" \
    --tags Key=ManagedBy,Value=sunk-anywhere \
    "${PROFILE_FLAG[@]}"
fi

if aws iam get-role --role-name "$ALB_ROLE" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "    Role $ALB_ROLE exists, skipping."
else
  run eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$REGION" \
    ${PROFILE:+--profile "$PROFILE"} \
    --namespace kube-system \
    --name aws-load-balancer-controller \
    --role-name "$ALB_ROLE" \
    --attach-policy-arn "$ALB_POLICY_ARN" \
    --tags "ManagedBy=sunk-anywhere" \
    --approve --override-existing-serviceaccounts
fi

echo
echo "==> Verification"
if ! $DRY_RUN; then
  echo "    ServiceAccounts (should show eks.amazonaws.com/role-arn annotation):"
  kubectl get sa -n kube-system ebs-csi-controller-sa efs-csi-controller-sa aws-load-balancer-controller \
    -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}{end}' 2>/dev/null || true
fi

echo
echo "==> Done. Next: run infrastructure/eks/install-controllers.sh"
