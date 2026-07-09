#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Install monitoring stack for SUNK on EKS — part of the main deploy flow.
#
# Zero-touch UX contract: the customer supplies initial approval and
# their account context (AWS_PROFILE / AWS_REGION). Nothing else. After
# this script finishes, Grafana is reachable via port-forward and the
# seeded SUNK dashboards appear without manual import.
#
# This is a thin wrapper around infrastructure/eks/observability/install.sh,
# kept at this path for naming parity with the GKE equivalent
# (infrastructure/gke/install-monitoring.sh) so the top-level deploy
# skills can invoke a consistent command regardless of cloud.
#
# What the underlying script does (idempotent):
#   1. Adds the prometheus-community helm repo and creates `monitoring`.
#   2. Creates a dashboard ConfigMap from infrastructure/eks/dashboards/
#      labeled `grafana_dashboard=1` for Grafana sidecar discovery.
#   3. Installs kube-prometheus-stack with
#      infrastructure/eks/observability/kube-prometheus-stack-values.yaml
#      (retention, storage, tolerations, nodeSelector tuned for budget).
#   4. Applies the syncer PodMonitor and DCGM exporter.
#
# NOTE on --set vs --set-string: kube-prometheus-stack's
# `sidecar.dashboards.labelValue` requires the string-typed form
# (`--set-string sidecar.dashboards.labelValue=1`). We avoid the pitfall
# by setting the label explicitly via kubectl instead of passing it
# through --set. Leaving this comment as a breadcrumb for anyone who
# wants to switch to the sidecar-discovery mechanism later.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INNER="${SCRIPT_DIR}/observability/install.sh"

if [[ ! -x "$INNER" ]]; then
    echo "ERROR: $INNER is missing or not executable" >&2
    exit 1
fi

exec "$INNER" "$@"
