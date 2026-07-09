#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Validate SUNK metrics pipeline on EKS.
# Requires: kube-prometheus-stack installed (see infrastructure/eks/observability/install.sh).
set -euo pipefail

SLURM_NS="${SLURM_NS:-tenant-slurm}"
MON_NS="${MON_NS:-monitoring}"
RELEASE="${RELEASE:-kube-prometheus-stack}"

ok=0; fail=0
chk() { if "$@"; then echo "  OK: $*"; ok=$((ok+1)); else echo "  FAIL: $*"; fail=$((fail+1)); fi }

echo "==> 1. Syncer pod is running"
chk kubectl -n "$SLURM_NS" get pod -l app.kubernetes.io/name=sunk-syncer -o jsonpath='{.items[0].status.phase}' | grep -q Running

echo "==> 2. Syncer metrics endpoint returns slurm_node_state"
SYNCER_POD=$(kubectl -n "$SLURM_NS" get pod -l app.kubernetes.io/name=sunk-syncer -o name | head -1)
chk kubectl -n "$SLURM_NS" exec "$SYNCER_POD" -- wget -qO- http://localhost:8080/metrics | grep -q slurm_node_state

echo "==> 3. Prometheus is running"
chk kubectl -n "$MON_NS" get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}' | grep -q Running

echo "==> 4. PodMonitor sunk-syncer exists"
chk kubectl -n "$SLURM_NS" get podmonitor sunk-syncer >/dev/null

echo "==> 5. Prometheus is scraping syncer (check target status)"
PROM_POD=$(kubectl -n "$MON_NS" get pod -l app.kubernetes.io/name=prometheus -o name | head -1)
chk kubectl -n "$MON_NS" exec "$PROM_POD" -c prometheus -- wget -qO- http://localhost:9090/api/v1/targets | grep -q '"health":"up".*sunk-syncer'

echo "==> 6. Grafana is running"
chk kubectl -n "$MON_NS" get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.phase}' | grep -q Running

echo "==> 7. Dashboard ConfigMap exists"
chk kubectl -n "$MON_NS" get configmap sunk-eks-dashboards >/dev/null

echo
echo "Passed: $ok, Failed: $fail"
[ "$fail" -eq 0 ]
