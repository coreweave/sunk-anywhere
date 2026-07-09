#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Symmetric teardown for the EKS cluster created by
# infrastructure/eks/create-cluster.sh
#
# Calls eksctl delete cluster with --disable-nodegroup-eviction and --force so
# control-plane + all nodegroups + owning VPC resources (NAT gateway, subnets,
# routes) get removed in one shot. eksctl handles eventual-consistency retries
# internally; this script just propagates the exit status.
#
# Idempotent: a missing cluster is not an error.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"

usage() {
  cat <<EOF
Usage: $0 [--cluster NAME] [--region REGION] [--profile PROFILE]

Deletes the EKS cluster $CLUSTER_NAME in region $REGION. Idempotent: if the
cluster does not exist, exits 0.
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
# 1. If cluster is already gone, exit.
# -------------------------------------------------------------------
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
    "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "    Cluster $CLUSTER_NAME not found, nothing to do."
  exit 0
fi

# -------------------------------------------------------------------
# 2. Delete via eksctl. Tolerate eventual-consistency / "not found" noise
#    from the underlying CloudFormation stacks - final verification happens
#    below via describe-cluster.
# -------------------------------------------------------------------
echo "==> Running eksctl delete cluster (this takes ~10-15 minutes)"
set +e
eksctl delete cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  ${PROFILE:+--profile "$PROFILE"} \
  --disable-nodegroup-eviction \
  --force
ECODE=$?
set -e
if [ "$ECODE" -ne 0 ]; then
  echo "    WARN: eksctl exited $ECODE (often eventual-consistency); verifying cluster state..."
fi

# -------------------------------------------------------------------
# 3. Verify describe-cluster returns ResourceNotFoundException.
# -------------------------------------------------------------------
echo "==> Verifying cluster is gone"
for _ in $(seq 1 30); do
  if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
      "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
    echo "    Cluster $CLUSTER_NAME is gone."
    exit 0
  fi
  sleep 10
done

echo "ERROR: cluster $CLUSTER_NAME still exists after eksctl delete. Check AWS console."
exit 1
