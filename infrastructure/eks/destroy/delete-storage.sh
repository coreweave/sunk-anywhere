#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Symmetric teardown for storage resources created by
# infrastructure/eks/storage/setup-efs.sh and the NFS fallback pod.
#
# Removes (in order):
#   1. PV/PVCs for slurm-home-efs and slurm-home-nfs
#   2. NFS server pod/service and its backing PVC
#   3. EFS mount targets (waits for each to be deleted)
#   4. EFS filesystem
#   5. EFS security group `sunk-efs-${CLUSTER_NAME}`
#
# Resources are selected by the `ManagedBy=sunk-anywhere` tag as blast-radius
# filter, per docs/eks/conventions.md.
#
# Idempotent: missing resources are not errors.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
SLURM_NAMESPACE="${SLURM_NAMESPACE:-tenant-slurm}"

usage() {
  cat <<EOF
Usage: $0 [--cluster NAME] [--region REGION] [--profile PROFILE]

Tears down slurm-home EFS + NFS resources, then deletes the EFS filesystem
(found by tag ManagedBy=sunk-anywhere) and its security group.
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
# 1. Kubernetes PV/PVC for slurm-home-* (namespace may be gone already)
# -------------------------------------------------------------------
echo "==> [1/5] Deleting slurm-home PV/PVCs"
if kubectl get namespace "$SLURM_NAMESPACE" >/dev/null 2>&1; then
  kubectl delete pvc slurm-home-efs slurm-home-nfs -n "$SLURM_NAMESPACE" --ignore-not-found --timeout=2m
else
  echo "    Namespace $SLURM_NAMESPACE not present, skipping PVC delete"
fi
kubectl delete pv slurm-home-efs slurm-home-nfs --ignore-not-found --timeout=2m

# -------------------------------------------------------------------
# 2. NFS server pod/service + its backing PVC
# -------------------------------------------------------------------
echo "==> [2/5] Deleting NFS server pod + service"
kubectl delete service nfs-server -n "$SLURM_NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl delete pod nfs-server -n "$SLURM_NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl delete deployment nfs-server -n "$SLURM_NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl delete pvc nfs-server-data -n "$SLURM_NAMESPACE" --ignore-not-found 2>/dev/null || true

# -------------------------------------------------------------------
# 3. EFS mount targets (by tag)
# -------------------------------------------------------------------
echo "==> [3/5] Looking up EFS filesystem by tag ManagedBy=sunk-anywhere"
EFS_IDS=$(aws efs describe-file-systems \
  --region "$REGION" "${PROFILE_FLAG[@]}" \
  --query "FileSystems[?Tags[?Key=='ManagedBy' && Value=='sunk-anywhere']].FileSystemId" \
  --output text 2>/dev/null || echo "")

if [ -z "$EFS_IDS" ]; then
  echo "    No tagged EFS filesystems found, skipping EFS teardown."
else
  for EFS_ID in $EFS_IDS; do
    echo "    Found EFS: $EFS_ID"
    echo "==> [3/5] Deleting mount targets for $EFS_ID"
    MT_IDS=$(aws efs describe-mount-targets \
      --file-system-id "$EFS_ID" \
      --region "$REGION" "${PROFILE_FLAG[@]}" \
      --query "MountTargets[].MountTargetId" --output text 2>/dev/null || echo "")
    for MT in $MT_IDS; do
      echo "    Deleting mount target $MT"
      aws efs delete-mount-target --mount-target-id "$MT" \
        --region "$REGION" "${PROFILE_FLAG[@]}" >/dev/null 2>&1 || true
    done
    # Wait for all mount targets to disappear (up to 5 minutes).
    for _ in $(seq 1 30); do
      REMAINING=$(aws efs describe-mount-targets \
        --file-system-id "$EFS_ID" \
        --region "$REGION" "${PROFILE_FLAG[@]}" \
        --query "length(MountTargets)" --output text 2>/dev/null || echo "0")
      if [ "$REMAINING" = "0" ]; then break; fi
      echo "    Waiting for $REMAINING mount target(s) to delete..."
      sleep 10
    done

    echo "==> [4/5] Deleting EFS filesystem $EFS_ID"
    aws efs delete-file-system --file-system-id "$EFS_ID" \
      --region "$REGION" "${PROFILE_FLAG[@]}" >/dev/null 2>&1 || \
      echo "    WARN: failed to delete $EFS_ID (may already be gone)"
  done
fi

# -------------------------------------------------------------------
# 4. EFS security group
# -------------------------------------------------------------------
echo "==> [5/5] Deleting EFS security group sunk-efs-${CLUSTER_NAME}"
SG_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" "${PROFILE_FLAG[@]}" \
  --filters "Name=group-name,Values=sunk-efs-${CLUSTER_NAME}" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")

if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  echo "    Deleting SG $SG_ID"
  # Retry a few times: ENIs attached to deleted mount targets can linger briefly.
  for _ in $(seq 1 6); do
    if aws ec2 delete-security-group --group-id "$SG_ID" \
        --region "$REGION" "${PROFILE_FLAG[@]}" 2>/dev/null; then
      echo "    SG deleted."
      break
    fi
    echo "    SG still in use (ENI detach pending), retrying in 10s..."
    sleep 10
  done
else
  echo "    Security group sunk-efs-${CLUSTER_NAME} not found, skipping."
fi

echo
echo "==> Done. Storage resources removed."
