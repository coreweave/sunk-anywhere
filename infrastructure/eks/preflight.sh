#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Preflight for the SUNK-on-EKS deploy flow.
#
# Runs before create-cluster.sh. Two jobs, both idempotent:
#   1. Confirm every CLI the later scripts call is on PATH.
#   2. Add the `coreweave` Helm repo so steps 5+ can install `coreweave/sunk`
#      and `coreweave/slurm`. Without this, step 5 fails with a cryptic
#      `Error: chart "sunk" not found` that wastes 5-10 minutes of cluster time.
set -euo pipefail

COREWEAVE_HELM_REPO="${COREWEAVE_HELM_REPO:-}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

check_tools() {
    local missing=()
    for bin in eksctl kubectl aws jq envsubst helm python3; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            missing+=("$bin")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "missing required tools: ${missing[*]}. Install them and rerun."
    fi
    echo "==> Tools OK: eksctl kubectl aws jq envsubst helm python3"
}

add_helm_repo() {
    if [[ -z "$COREWEAVE_HELM_REPO" ]]; then
        die "COREWEAVE_HELM_REPO is not set. The SUNK and Slurm charts are licensed; contact CoreWeave (sunk@coreweave.com) for access instructions, then export COREWEAVE_HELM_REPO=<the repository URL you receive> and rerun."
    fi
    # --force-update so a stale or partially-configured `coreweave` entry
    # gets replaced instead of erroring out on "repo already exists".
    if ! helm repo add coreweave "$COREWEAVE_HELM_REPO" --force-update >/dev/null 2>&1; then
        die "failed to add helm repo coreweave at $COREWEAVE_HELM_REPO"
    fi
    if ! helm repo update coreweave >/dev/null 2>&1; then
        die "failed to refresh helm repo coreweave"
    fi
    echo "==> Helm repo 'coreweave' ready ($COREWEAVE_HELM_REPO)"
}

main() {
    check_tools
    add_helm_repo
    echo
    echo "Preflight OK. Next: infrastructure/eks/create-cluster.sh"
}

main "$@"
