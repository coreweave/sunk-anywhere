#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Install kube-prometheus-stack + DCGM + dashboards for SUNK on EKS.
# Run AFTER SUNK + Slurm are deployed (PodMonitor selects sunk-syncer in slurm namespace).
# Safe to re-run; helm upgrade --install is idempotent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH_DIR="${HERE}/../dashboards"
NS="${MONITORING_NS:-monitoring}"
RELEASE="${RELEASE:-kube-prometheus-stack}"

echo "==> Namespace: $NS, Release: $RELEASE"

echo "==> Adding prometheus-community helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo "==> Creating namespace $NS"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating dashboard ConfigMap from $DASH_DIR"
kubectl -n "$NS" create configmap sunk-eks-dashboards \
  --from-file="$DASH_DIR" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" label configmap sunk-eks-dashboards grafana_dashboard=1 --overwrite

echo "==> Installing $RELEASE"
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$NS" \
  --version "^65" \
  -f "${HERE}/kube-prometheus-stack-values.yaml" \
  --wait --timeout 5m

echo "==> Applying syncer PodMonitor (slurm ns)"
kubectl apply -f "${HERE}/syncer-podmonitor.yaml"

echo "==> Applying DCGM exporter (runs on gpu-workers only)"
kubectl apply -f "${HERE}/dcgm-exporter.yaml"

echo
echo "==> Done. Grafana admin password:"
kubectl -n "$NS" get secret "${RELEASE}-grafana" -o jsonpath='{.data.admin-password}' | base64 -d; echo
echo
echo "==> Port-forward Grafana:"
echo "    kubectl -n $NS port-forward svc/${RELEASE}-grafana 3000:80"
echo "    Open http://localhost:3000 (user: admin)"
