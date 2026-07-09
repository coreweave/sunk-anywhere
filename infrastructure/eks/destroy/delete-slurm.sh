#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Symmetric teardown for SUNK + Slurm Helm releases in the slurm namespace.
#
# Undoes what `helm install slurm` and `helm install sunk` did during bringup.
# Idempotent: missing releases / missing namespace / missing PVCs are not errors.
#
# Per docs/eks/conventions.md, the `slurm` namespace is managed by SUNK + Slurm.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
NAMESPACE="${SLURM_NAMESPACE:-tenant-slurm}"
SUNK_NAMESPACE="${SUNK_NAMESPACE:-sunk}"

usage() {
  cat <<EOF
Usage: $0 [--cluster NAME] [--region REGION] [--profile PROFILE]

Uninstalls SUNK + Slurm Helm releases, drains leftover PVCs, deletes the slurm
namespace. Safe to re-run.
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

export AWS_PROFILE="${PROFILE:-${AWS_PROFILE:-}}"
export AWS_REGION="$REGION"

# Pin kubectl/helm to the cluster under destroy -- the caller's default
# kubeconfig context may point at a different cluster (concurrent agent
# runs, recent `get-credentials` against a GKE/EKS cluster, etc.).
# Without this, helm uninstall silently skips if the context resolves to
# a cluster where the release doesn't exist.
CLUSTER_ARN="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.arn' --output text 2>/dev/null || true)"
if [ -n "$CLUSTER_ARN" ] && [ "$CLUSTER_ARN" != "None" ]; then
  export KUBECTL_ARGS="--context=$CLUSTER_ARN"
  export HELM_KUBECONTEXT="$CLUSTER_ARN"
  echo "==> Pinning kubectl/helm to context: $CLUSTER_ARN"
else
  echo "    WARN: could not resolve cluster ARN; using current kubectl context"
  KUBECTL_ARGS=""
fi

echo "==> Cluster: $CLUSTER_NAME, Region: $REGION, Namespace: $NAMESPACE"

if ! kubectl $KUBECTL_ARGS get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "    Namespace $NAMESPACE not present, nothing to do."
  exit 0
fi

echo "==> [1/5] helm uninstall slurm -n $NAMESPACE"
helm uninstall slurm -n "$NAMESPACE" ${HELM_KUBECONTEXT:+--kube-context=$HELM_KUBECONTEXT} 2>/dev/null || echo "    slurm release not present, skipping"

echo "==> [2/5] helm uninstall sunk -n $SUNK_NAMESPACE"
helm uninstall sunk -n "$SUNK_NAMESPACE" ${HELM_KUBECONTEXT:+--kube-context=$HELM_KUBECONTEXT} 2>/dev/null || echo "    sunk release not present, skipping"

echo "==> [3/5] Waiting for pods to terminate (up to 5m)"
if ! kubectl $KUBECTL_ARGS wait --for=delete pods --all -n "$NAMESPACE" --timeout=5m 2>/dev/null; then
  echo "    WARN: some pods still present after 5m; continuing"
  kubectl $KUBECTL_ARGS get pods -n "$NAMESPACE" 2>/dev/null || true
fi

echo "==> [4/5] Deleting leftover PVCs in $NAMESPACE + $SUNK_NAMESPACE"
kubectl $KUBECTL_ARGS delete pvc --all -n "$NAMESPACE" --ignore-not-found --timeout=2m
kubectl $KUBECTL_ARGS delete pvc --all -n "$SUNK_NAMESPACE" --ignore-not-found --timeout=2m

echo "==> [5/5] Deleting namespaces $NAMESPACE + $SUNK_NAMESPACE"
kubectl $KUBECTL_ARGS delete namespace "$NAMESPACE" --ignore-not-found --timeout=5m
kubectl $KUBECTL_ARGS delete namespace "$SUNK_NAMESPACE" --ignore-not-found --timeout=5m

echo
echo "==> Done. SUNK + Slurm removed."
