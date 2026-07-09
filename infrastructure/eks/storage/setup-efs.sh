#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Create the managed EFS filesystem backing the `efs-sc` StorageClass.
#
# Provisions (idempotent, tag-based reuse):
#   1. Security group `sunk-efs-<CLUSTER>` allowing inbound 2049 from the cluster's
#      shared node SG (falls back to the VPC CIDR if that lookup is ambiguous).
#   2. EFS filesystem with creation-token `sunk-<CLUSTER>`, generalPurpose performance,
#      bursting throughput (cheapest; ~$30/mo for 100GB).
#   3. One mount target per cluster subnet, each attached to the SG above.
#   4. Applies the efs-sc StorageClass manifest (substitutes the FS ID).
#
# Per docs/eks/conventions.md. Run AFTER install-controllers.sh.
#
# The final FS ID is printed and also persisted to /tmp/sunk-efs-id so that
# efs-pv-home.yaml.template can be rendered by a follow-up step.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
# Throughput in MiB/s is only used for provisioned-throughput mode. Bursting mode
# (the default here) ignores the value; we accept the flag for forward-compat.
THROUGHPUT_MIBPS="64"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_TEMPLATE="${SCRIPT_DIR}/efs-storageclass.yaml.template"

usage() {
  cat <<EOF
Usage: $0 [--cluster NAME] [--region REGION] [--profile PROFILE] [--size THROUGHPUT_MIBPS]

  --cluster NAME         EKS cluster name (default: sunk-eks)
  --region REGION        AWS region (default: us-east-1)
  --profile PROFILE      AWS CLI profile (optional)
  --size THROUGHPUT      MiB/s for provisioned-throughput mode (default: 64).
                         Ignored in bursting mode (the mode this script sets).
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER_NAME="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --size) THROUGHPUT_MIBPS="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown argument: $1" >&2; usage;;
  esac
done

PROFILE_FLAG=()
if [ -n "$PROFILE" ]; then PROFILE_FLAG=(--profile "$PROFILE"); fi

AWS=(aws --region "$REGION" "${PROFILE_FLAG[@]}")

CREATION_TOKEN="sunk-${CLUSTER_NAME}"
FS_NAME="sunk-${CLUSTER_NAME}"
SG_NAME="sunk-efs-${CLUSTER_NAME}"

echo "==> Cluster: $CLUSTER_NAME  Region: $REGION  Throughput: ${THROUGHPUT_MIBPS} MiB/s (bursting mode ignores this)"

# ---------------------------------------------------------------------------
# 1. Discover VPC and subnets from the cluster.
# ---------------------------------------------------------------------------
echo "==> [1/5] Discovering VPC and subnets for cluster"
VPC_ID=$("${AWS[@]}" eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
SUBNETS=$("${AWS[@]}" eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "ERROR: could not resolve VPC for cluster $CLUSTER_NAME" >&2
  exit 1
fi

echo "    VPC: $VPC_ID"
echo "    Subnets: $SUBNETS"

# ---------------------------------------------------------------------------
# 2. Security group allowing inbound 2049 (NFS) from the cluster.
# ---------------------------------------------------------------------------
echo "==> [2/5] Security group $SG_NAME"
SG_ID=$("${AWS[@]}" ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$("${AWS[@]}" ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "NFS/2049 from sunk-anywhere cluster ${CLUSTER_NAME}" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},{Key=ManagedBy,Value=sunk-anywhere},{Key=Environment,Value=dev}]" \
    --query 'GroupId' --output text)
  echo "    Created SG: $SG_ID"
else
  echo "    Reusing SG: $SG_ID"
fi

# Identify the cluster's node shared SG (simpler and tighter than the VPC CIDR).
# `cluster.resourcesVpcConfig.clusterSecurityGroupId` is the SG EKS attaches to
# every managed nodegroup. If unavailable, fall back to the VPC CIDR.
CLUSTER_SG=$("${AWS[@]}" eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || echo "None")

INGRESS_DESC="pre-existing"
# shellcheck disable=SC2016  # JMESPath literal; single quotes intentional
if ! "${AWS[@]}" ec2 describe-security-groups --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`2049`]' --output text | grep -q .; then
  if [ -n "$CLUSTER_SG" ] && [ "$CLUSTER_SG" != "None" ]; then
    "${AWS[@]}" ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --ip-permissions "IpProtocol=tcp,FromPort=2049,ToPort=2049,UserIdGroupPairs=[{GroupId=${CLUSTER_SG},Description=sunk-anywhere nodes}]" \
      >/dev/null
    INGRESS_DESC="from cluster SG ${CLUSTER_SG}"
  else
    VPC_CIDR=$("${AWS[@]}" ec2 describe-vpcs --vpc-ids "$VPC_ID" \
      --query 'Vpcs[0].CidrBlock' --output text)
    "${AWS[@]}" ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" --protocol tcp --port 2049 --cidr "$VPC_CIDR" >/dev/null
    INGRESS_DESC="from VPC CIDR ${VPC_CIDR}"
  fi
  echo "    Added 2049 ingress ${INGRESS_DESC}"
else
  echo "    Ingress 2049 already present"
fi

# ---------------------------------------------------------------------------
# 3. EFS filesystem (idempotent via creation-token).
# ---------------------------------------------------------------------------
echo "==> [3/5] EFS filesystem (creation-token=${CREATION_TOKEN})"
FS_ID=$("${AWS[@]}" efs describe-file-systems \
  --creation-token "$CREATION_TOKEN" \
  --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || echo "None")

if [ "$FS_ID" = "None" ] || [ -z "$FS_ID" ]; then
  FS_ID=$("${AWS[@]}" efs create-file-system \
    --creation-token "$CREATION_TOKEN" \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags "Key=Name,Value=${FS_NAME}" "Key=ManagedBy,Value=sunk-anywhere" "Key=Environment,Value=dev" \
    --query 'FileSystemId' --output text)
  echo "    Created filesystem: $FS_ID"
else
  echo "    Reusing filesystem: $FS_ID"
fi

# ---------------------------------------------------------------------------
# 4. Wait for filesystem to be available.
# ---------------------------------------------------------------------------
echo "==> [4/5] Waiting for filesystem to reach 'available'"
for _ in $(seq 1 60); do
  STATE=$("${AWS[@]}" efs describe-file-systems --file-system-id "$FS_ID" \
    --query 'FileSystems[0].LifeCycleState' --output text)
  if [ "$STATE" = "available" ]; then
    echo "    Filesystem is available"
    break
  fi
  echo "    State=$STATE, retrying in 5s..."
  sleep 5
done

# ---------------------------------------------------------------------------
# 5. Mount targets, one per cluster subnet.
# ---------------------------------------------------------------------------
echo "==> [5/5] Mount targets"
EXISTING_MTS=$("${AWS[@]}" efs describe-mount-targets --file-system-id "$FS_ID" \
  --query 'MountTargets[].SubnetId' --output text 2>/dev/null || true)

for SUBNET in $SUBNETS; do
  if echo "$EXISTING_MTS" | tr '\t' '\n' | grep -qx "$SUBNET"; then
    echo "    Mount target for $SUBNET already exists"
    continue
  fi
  MT_ID=$("${AWS[@]}" efs create-mount-target \
    --file-system-id "$FS_ID" \
    --subnet-id "$SUBNET" \
    --security-groups "$SG_ID" \
    --query 'MountTargetId' --output text)
  echo "    Created $MT_ID for subnet $SUBNET"
done

echo "    Waiting for mount targets to reach 'available'"
for _ in $(seq 1 120); do
  # shellcheck disable=SC2016  # JMESPath literal; single quotes intentional
  PENDING=$("${AWS[@]}" efs describe-mount-targets --file-system-id "$FS_ID" \
    --query 'MountTargets[?LifeCycleState!=`available`].MountTargetId' \
    --output text)
  if [ -z "$PENDING" ]; then
    echo "    All mount targets are available"
    break
  fi
  echo "    Pending: $PENDING"
  sleep 5
done

# ---------------------------------------------------------------------------
# Persist FS ID and apply StorageClass manifest.
# ---------------------------------------------------------------------------
echo "$FS_ID" > /tmp/sunk-efs-id
echo
echo "==> EFS filesystem ID: $FS_ID (also written to /tmp/sunk-efs-id)"

if [ -f "$SC_TEMPLATE" ]; then
  echo "==> Applying StorageClass efs-sc"
  sed "s/__EFS_FS_ID__/${FS_ID}/g" "$SC_TEMPLATE" | kubectl apply -f -
else
  echo "WARNING: $SC_TEMPLATE not found; skipping StorageClass apply" >&2
fi

echo
echo "==> Done. Next: render efs-pv-home.yaml.template and kubectl apply."
echo "    sed 's/__EFS_FS_ID__/${FS_ID}/g' $(dirname "$SC_TEMPLATE")/efs-pv-home.yaml.template | kubectl apply -f -"
