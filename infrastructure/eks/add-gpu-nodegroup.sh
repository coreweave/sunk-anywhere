#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Add the gpu-workers managed nodegroup to an existing sunk-eks cluster.
#
# Default-on, opt-out via --skip-gpu on the orchestrating skill or
# SUNK_SKIP_GPU=1 in the env. Idempotent: a pre-existing gpu-workers
# nodegroup is detected and the script exits 0.
#
# Default profile per docs/eks/conventions.md:
#   - g6.xlarge (1x NVIDIA L4 24 GB), spot, scale 0..1
#   - AmazonLinux2023, gp3 root @ 200 GiB
#   - Tagged ManagedBy=sunk-anywhere for destroy-all
#
# Override the instance type with --instance-type (g5.xlarge / g5.2xlarge / etc).
# G/VT vCPU quota is checked by infrastructure/eks/create-cluster.sh up-front.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
INSTANCE_TYPE="g6.xlarge"
SPOT="true"
NODEGROUP_NAME="gpu-workers"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

  --cluster NAME         Cluster name (default: sunk-eks)
  --region REGION        AWS region (default: us-east-1)
  --profile PROFILE      AWS CLI profile
  --instance-type TYPE   GPU instance family (default: g6.xlarge for L4)
  --on-demand            Use on-demand instead of spot
  --name NAME            Nodegroup name (default: gpu-workers)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER_NAME="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2;;
    --on-demand) SPOT="false"; shift;;
    --name) NODEGROUP_NAME="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown: $1" >&2; usage >&2; exit 2;;
  esac
done

PROFILE_FLAG=()
if [ -n "$PROFILE" ]; then PROFILE_FLAG=(--profile "$PROFILE"); fi

echo "==> GPU nodegroup: $NODEGROUP_NAME ($INSTANCE_TYPE, spot=$SPOT) on $CLUSTER_NAME/$REGION"

# Idempotency: if the nodegroup already exists and is ACTIVE, exit clean.
status="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" \
            --region "$REGION" "${PROFILE_FLAG[@]}" --query 'nodegroup.status' --output text 2>/dev/null || true)"
if [ "$status" = "ACTIVE" ] || [ "$status" = "CREATING" ] || [ "$status" = "UPDATING" ]; then
  echo "    Nodegroup $NODEGROUP_NAME already $status, skipping."
  exit 0
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<YAML
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER_NAME
  region: $REGION
managedNodeGroups:
  - name: $NODEGROUP_NAME
    instanceType: $INSTANCE_TYPE
    amiFamily: AmazonLinux2023
    desiredCapacity: 1
    minSize: 0
    maxSize: 1
    spot: $SPOT
    volumeSize: 200
    volumeType: gp3
    labels:
      node.coreweave.cloud/class: gpu
      node.coreweave.cloud/state: production
    tags:
      Environment: dev
      Service: sunk
      ManagedBy: sunk-anywhere
      Owner: auto-cleanup
      Nodegroup: $NODEGROUP_NAME
YAML

eksctl create nodegroup --config-file "$TMP" ${PROFILE:+--profile "$PROFILE"}

echo
echo "==> Waiting for nodes to be Ready"
kubectl wait --for=condition=Ready nodes -l "eks.amazonaws.com/nodegroup=$NODEGROUP_NAME" --timeout=15m

echo
echo "==> Done. nvidia.com/gpu allocatable on the new node:"
kubectl get nodes -l "eks.amazonaws.com/nodegroup=$NODEGROUP_NAME" \
  -o json | jq -r '.items[] | "\(.metadata.name): \(.status.allocatable["nvidia.com/gpu"] // "0")"'
