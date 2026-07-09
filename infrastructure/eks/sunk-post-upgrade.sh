#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# ##############################################################################
# # WARNING: UNVALIDATED                                                      #
# # This script has NOT been tested on a real EKS cluster.                    #
# # If you deploy SUNK on EKS, please report what worked and what broke.      #
# ##############################################################################
#
# Post-upgrade script for SUNK on EKS.
# Run this immediately after every `helm upgrade` of the Slurm chart.
#
# What it does:
#   1. Re-patches gres.conf (destroyed by helm upgrade)
#   2. Re-patches EKS system DaemonSet tolerations
#   3. Rolling-restarts GPU worker pods to pick up the new gres.conf
#   4. Resumes GPU nodes in Slurm after they rejoin
#
# Usage:
#   bash infrastructure/eks/sunk-post-upgrade.sh
#   bash infrastructure/eks/sunk-post-upgrade.sh --skip-tolerations
#   bash infrastructure/eks/sunk-post-upgrade.sh --skip-gres
#   NAMESPACE=my-slurm bash infrastructure/eks/sunk-post-upgrade.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-tenant-slurm}"
SKIP_TOLERATIONS=false
SKIP_GRES=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
  case "$arg" in
    --skip-tolerations) SKIP_TOLERATIONS=true ;;
    --skip-gres) SKIP_GRES=true ;;
    --help|-h)
      echo "Usage: $0 [--skip-tolerations] [--skip-gres]"
      echo ""
      echo "Run after every helm upgrade of the Slurm chart."
      echo ""
      echo "Options:"
      echo "  --skip-tolerations  Skip EKS system DaemonSet toleration patching"
      echo "  --skip-gres         Skip gres.conf patching (CPU-only clusters)"
      echo ""
      echo "Environment:"
      echo "  NAMESPACE           Slurm namespace (default: tenant-slurm)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

# ---------- Step 1: Re-patch gres.conf ----------

if [ "$SKIP_GRES" = true ]; then
  echo "=== Skipping gres.conf patch (--skip-gres) ==="
else
  echo "=== Step 1: Re-patching gres.conf ==="

  GPU_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep gpu-workers | awk '{print $1}')

  if [ -z "$GPU_PODS" ]; then
    echo "  No GPU worker pods found in $NAMESPACE. Skipping gres.conf patch."
    SKIP_GRES=true
  else
    # AutoDetect=off because the slurm-controller image on EKS is built without
    # nvml support. Leaving AutoDetect=nvml causes slurmd to drop the explicit
    # File= directive ("Ignoring file-less GPU gpu:l4 from final GRES list")
    # and the node lands in INVALID_REG. The explicit File= line below still
    # tells slurmctld which device to advertise; nvml autodetect is only an
    # optimization and is not needed once File= is set.
    GRES_CONTENT="AutoDetect=off"

    for pod in $GPU_PODS; do
      # 1) Pod label set by SUNK (best signal).
      GPU_TYPE=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.sunk\.coreweave\.com/gres-gpu}' 2>/dev/null || true)
      # 2) Existing slurm.conf Gres= line (e.g. "Gres=gpu:l4:1") — much more
      #    reliable than the gres.conf line, which may have been overwritten
      #    by a previous run of this script with a wrong default.
      if [ -z "$GPU_TYPE" ]; then
        GPU_TYPE=$(kubectl get configmap slurm-slurm-conf -n "$NAMESPACE" -o jsonpath='{.data.slurm\.conf}' 2>/dev/null | grep -oE 'Gres=gpu:[a-z0-9_-]+' | head -1 | cut -d: -f2 || true)
      fi
      # 3) Nodeset YAML in helm values (last-resort, requires repo path).
      if [ -z "$GPU_TYPE" ]; then
        GPU_TYPE=$(kubectl get configmap slurm-slurm-conf -n "$NAMESPACE" -o jsonpath='{.data.gres\.conf}' 2>/dev/null | sed -n 's/.*Type=\([^ ]*\).*/\1/p' | head -1 || true)
      fi
      if [ -z "$GPU_TYPE" ]; then
        GPU_TYPE="l4"
        echo "  WARNING: Could not detect GPU type, defaulting to '$GPU_TYPE'"
      fi

      GPU_COUNT=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].resources.limits.nvidia\.com/gpu}' 2>/dev/null || echo "1")
      GPU_COUNT="${GPU_COUNT:-1}"

      if [ "$GPU_COUNT" -gt 1 ] 2>/dev/null; then
        LAST_IDX=$((GPU_COUNT - 1))
        DEVICE_FILE="/dev/nvidia[0-${LAST_IDX}]"
      else
        DEVICE_FILE="/dev/nvidia0"
      fi

      GRES_CONTENT="${GRES_CONTENT}\nNodeName=${pod} Name=gpu Type=${GPU_TYPE} File=${DEVICE_FILE}"
      echo "  ${pod}: Type=${GPU_TYPE} File=${DEVICE_FILE}"
    done

    kubectl patch configmap slurm-slurm-conf -n "$NAMESPACE" --type=merge \
      -p "{\"data\":{\"gres.conf\":\"${GRES_CONTENT}\"}}"
    echo "  gres.conf patched."
  fi
fi

echo ""

# ---------- Step 2: Re-patch EKS system tolerations ----------

if [ "$SKIP_TOLERATIONS" = true ]; then
  echo "=== Skipping EKS toleration patches (--skip-tolerations) ==="
else
  echo "=== Step 2: Re-patching EKS system tolerations ==="
  if [ -x "$SCRIPT_DIR/patch-eks-tolerations.sh" ]; then
    bash "$SCRIPT_DIR/patch-eks-tolerations.sh"
  else
    echo "  WARNING: patch-eks-tolerations.sh not found at $SCRIPT_DIR/"
    echo "  Run it manually: bash infrastructure/eks/patch-eks-tolerations.sh"
  fi
fi

echo ""

# ---------- Step 3: Restart GPU worker pods ----------

if [ "$SKIP_GRES" = true ]; then
  echo "=== Skipping GPU pod restart (no GPU workers) ==="
else
  echo "=== Step 3: Restarting GPU worker pods to pick up new gres.conf ==="

  for pod in $GPU_PODS; do
    echo "  Deleting $pod ..."
    kubectl delete pod -n "$NAMESPACE" "$pod" --wait=false
  done

  echo "  Waiting for GPU pods to restart ..."
  kubectl wait --for=condition=Ready pod -n "$NAMESPACE" -l sunk.coreweave.com/role=compute --timeout=120s 2>/dev/null || true

  sleep 10
fi

echo ""

# ---------- Step 4: Resume GPU nodes in Slurm ----------

if [ "$SKIP_GRES" = true ]; then
  echo "=== Skipping node resume (no GPU workers) ==="
else
  echo "=== Step 4: Resuming GPU nodes in Slurm ==="

  NEW_GPU_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep gpu-workers | awk '{print $1}')
  LOGIN_POD=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep slurm-login | awk '{print $1}' | head -1)

  if [ -z "$LOGIN_POD" ]; then
    echo "  WARNING: No login pod found. Resume nodes manually:"
    echo "    scontrol update NodeName=<node> State=RESUME"
  else
    for pod in $NEW_GPU_PODS; do
      echo "  Resuming $pod ..."
      kubectl exec -n "$NAMESPACE" "$LOGIN_POD" -c sshd -- \
        scontrol update NodeName="$pod" State=RESUME 2>/dev/null || echo "  $pod: not yet registered, may need manual resume"
    done
  fi
fi

echo ""

# ---------- Step 5: Verify ----------

echo "=== Verification ==="

LOGIN_POD=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep slurm-login | awk '{print $1}' | head -1)

if [ -n "$LOGIN_POD" ]; then
  echo ""
  echo "Node status (sinfo):"
  kubectl exec -n "$NAMESPACE" "$LOGIN_POD" -c sshd -- sinfo 2>/dev/null || echo "  sinfo failed"

  echo ""
  echo "Quick job test (srun hostname):"
  kubectl exec -n "$NAMESPACE" "$LOGIN_POD" -c sshd -- srun --mem=100 hostname 2>/dev/null || echo "  srun failed (nodes may still be registering, retry in 30s)"
else
  echo "  No login pod found. Verify manually:"
  echo "    kubectl exec -n $NAMESPACE slurm-login-0 -c sshd -- sinfo"
fi

echo ""
echo "=== Post-upgrade complete ==="
