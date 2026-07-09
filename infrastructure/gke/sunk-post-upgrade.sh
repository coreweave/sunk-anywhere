#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Post-upgrade script for SUNK on GKE.
# Run this immediately after every `helm upgrade` of the Slurm chart.
#
# What it does:
#   1. Re-patches gres.conf (destroyed by helm upgrade)
#   2. Re-patches GKE system pod tolerations (may be reverted by GKE upgrades)
#   3. Rolling-restarts GPU worker pods to pick up the new gres.conf
#   4. Resumes GPU nodes in Slurm after they rejoin
#
# Usage:
#   bash infrastructure/sunk-post-upgrade.sh
#   bash infrastructure/sunk-post-upgrade.sh --skip-tolerations
#   bash infrastructure/sunk-post-upgrade.sh --skip-gres
#   NAMESPACE=my-slurm bash infrastructure/sunk-post-upgrade.sh

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
      echo "  --skip-tolerations  Skip GKE system pod toleration patching"
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
    # Build gres.conf content with a line for each GPU pod.
    # Start with AutoDetect (keeps the chart's default, harmless since NVML is unsupported).
    GRES_CONTENT="AutoDetect=nvml"

    for pod in $GPU_PODS; do
      # GPU type detection precedence:
      #   1. The pod's `sunk.coreweave.com/gres-gpu` label (set from the
      #      compute.nodes.<group>.gresGpu values entry by the SUNK chart).
      #   2. Existing gres.conf in the slurm-slurm-conf ConfigMap.
      #   3. The `cloud.google.com/gke-accelerator` label on the node the pod
      #      is scheduled on (e.g., nvidia-l4 -> l4).
      #   4. Fall back to "l4" with a loud warning.
      GPU_TYPE=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.sunk\.coreweave\.com/gres-gpu}' 2>/dev/null || true)
      if [ -z "$GPU_TYPE" ]; then
        GPU_TYPE=$(kubectl get configmap slurm-slurm-conf -n "$NAMESPACE" -o jsonpath='{.data.gres\.conf}' 2>/dev/null | sed -n 's/.*Type=\([^ ]*\).*/\1/p' | head -1 || true)
      fi
      if [ -z "$GPU_TYPE" ]; then
        NODE_NAME=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
        if [ -n "$NODE_NAME" ]; then
          ACCELERATOR=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.cloud\.google\.com/gke-accelerator}' 2>/dev/null || true)
          # Strip the nvidia- prefix: nvidia-l4 -> l4, nvidia-tesla-a100 -> tesla-a100
          GPU_TYPE="${ACCELERATOR#nvidia-}"
        fi
      fi
      if [ -z "$GPU_TYPE" ]; then
        GPU_TYPE="l4"
        echo "  WARNING: Could not detect GPU type for $pod from label, gres.conf, or node accelerator label. Defaulting to '$GPU_TYPE'. Override with compute.nodes.<group>.gresGpu in helm values." >&2
      fi

      # Determine device file count from nvidia.com/gpu resource limit
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

# ---------- Step 2: Re-patch GKE system tolerations ----------

if [ "$SKIP_TOLERATIONS" = true ]; then
  echo "=== Skipping GKE toleration patches (--skip-tolerations) ==="
else
  echo "=== Step 2: Re-patching GKE system tolerations ==="
  if [ -x "$SCRIPT_DIR/patch-gke-tolerations.sh" ]; then
    bash "$SCRIPT_DIR/patch-gke-tolerations.sh"
  else
    echo "  WARNING: patch-gke-tolerations.sh not found at $SCRIPT_DIR/"
    echo "  Run it manually: bash infrastructure/gke/patch-gke-tolerations.sh"
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

  # Give slurmd time to register with slurmctld
  sleep 10
fi

echo ""

# ---------- Step 4: Resume GPU nodes in Slurm ----------

if [ "$SKIP_GRES" = true ]; then
  echo "=== Skipping node resume (no GPU workers) ==="
else
  echo "=== Step 4: Resuming GPU nodes in Slurm ==="

  # Re-discover pod names after restart (they may have new suffixes)
  NEW_GPU_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep gpu-workers | awk '{print $1}')

  LOGIN_POD=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep slurm-login | awk '{print $1}' | head -1)

  if [ -z "$LOGIN_POD" ]; then
    echo "  WARNING: No login pod found. Resume nodes manually:"
    echo "    scontrol update NodeName=<node> State=RESUME"
  else
    # Wait for slurmd on each pod to report Gres=gpu:<type>:N before resuming.
    # If we resume too early, the node briefly drains again with
    # "gres/gpu count reported lower than configured (0 < 1)" and the operator
    # has to chase it manually. The probe is bounded so a genuinely broken pod
    # doesn't stall the script forever.
    RESUME_WAIT_TIMEOUT=120
    for pod in $NEW_GPU_PODS; do
      echo "  Waiting for $pod slurmd to report GRES (timeout ${RESUME_WAIT_TIMEOUT}s) ..."
      deadline=$(( $(date +%s) + RESUME_WAIT_TIMEOUT ))
      gres_ready=0
      while [ "$(date +%s)" -lt "$deadline" ]; do
        gres_line=$(kubectl exec -n "$NAMESPACE" "$LOGIN_POD" -c sshd -- \
          scontrol show node "$pod" 2>/dev/null | grep -oE 'Gres=gpu:[^ ]+' | head -1 || true)
        if [ -n "$gres_line" ] && ! echo "$gres_line" | grep -q '^Gres=gpu:0$\|^Gres=gpu:(null)'; then
          echo "  $pod reports $gres_line"
          gres_ready=1
          break
        fi
        sleep 5
      done
      if [ "$gres_ready" -eq 1 ]; then
        echo "  Resuming $pod ..."
        kubectl exec -n "$NAMESPACE" "$LOGIN_POD" -c sshd -- \
          scontrol update NodeName="$pod" State=RESUME 2>/dev/null \
          || echo "  $pod: scontrol update failed, may need manual resume" >&2
      else
        echo "  $pod: slurmd did not report GRES within ${RESUME_WAIT_TIMEOUT}s. Skipping resume; check 'scontrol show node $pod' and resume manually once Gres looks correct." >&2
      fi
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
