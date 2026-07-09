#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Pyxis container job: submit a job with --container-image and assert the
# payload ran inside the image, not the host. Pyxis sits on top of enroot,
# which needs a seccomp profile file on every node at
# /var/lib/kubelet/seccomp/profiles/enroot.
#
# Pyxis is disabled by default on EKS and GKE (seccomp profile absent). It
# ships enabled only on CoreWeave clusters (cks: true) or when the deployer
# has installed the profile and flipped compute.pyxis.enabled: true.
#
# Behaviour:
#   - Detect pyxis support by asking srun for --help and grepping for
#     --container-image. Skip if absent.
#   - Submit a tiny sbatch that runs `cat /etc/os-release` inside
#     alpine:3.19. Assert the output says "Alpine Linux".
#
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-180}"
IMAGE="${PYXIS_IMAGE:-alpine:3.19}"

echo "=== 17-pyxis-container (partition=$PARTITION image=$IMAGE timeout=${TIMEOUT}s) ==="

NODES=$(sinfo -h -N -p "$PARTITION" -o '%N' 2>/dev/null | sort -u | grep -cv '^$')
if [ -z "$NODES" ] || [ "$NODES" -eq 0 ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

# srun --help exposes the flag only if the pyxis SPANK plugin is loaded.
if ! srun --help 2>&1 | grep -q -- '--container-image'; then
  echo "SKIPPED: pyxis not enabled on this cluster (srun --help has no --container-image)"
  exit 2
fi

# Use /home (shared NFS) so the compute node's writes are visible from the
# login pod where this script runs. /tmp is local to each pod.
LOG=$(mktemp -p "${PYXIS_LOG_DIR:-/home}")
trap 'rm -f "$LOG"' EXIT

JID=$(sbatch --parsable -p "$PARTITION" --mem=256M --cpus-per-task=1 -t 00:03:00 \
  --output="$LOG" \
  --wrap="srun --container-image=$IMAGE cat /etc/os-release" 2>&1)
if ! [[ "$JID" =~ ^[0-9]+$ ]]; then
  echo "FAIL: sbatch returned: $JID"
  exit 1
fi
echo "Submitted job $JID"
trap 'scancel "$JID" 2>/dev/null; rm -f "$LOG"' EXIT

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  S=$(squeue -h -j "$JID" -o '%T' 2>/dev/null | tr -d '[:space:]')
  [ -z "$S" ] && break           # no longer queued -> finished
  sleep 3
done

STATE=$(sacct -j "$JID" -X -n -P -o State 2>/dev/null | head -1 | tr -d '[:space:]')
echo "Final state: $STATE"
echo "--- job output ---"
cat "$LOG" 2>/dev/null || true
echo "--- end output ---"

if [ "$STATE" != "COMPLETED" ]; then
  echo "FAIL: job did not complete (state=$STATE)"
  exit 1
fi

if grep -qi 'Alpine Linux' "$LOG"; then
  echo "PASS: ran inside $IMAGE"
  exit 0
fi

echo "FAIL: output did not identify container image ($IMAGE)"
exit 1
