#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Create a GKE Standard cluster for sunk-anywhere.
#
# Conventions contract: docs/gke/deployment-guide.md
#
# What this script does (in order):
#   1. Verify prerequisites (gcloud, kubectl, helm, jq).
#   2. Verify gcloud auth + required APIs enabled (container, compute,
#      iamcredentials, monitoring).
#   3. Prompt for confirmation (unless --yes).
#   4. Run `gcloud container clusters create` with the budget-profile
#      sizing from deploy-sunk-on-gke SKILL.md.
#   5. Fetch credentials into the caller's active kubeconfig, or an
#      explicit --kubeconfig path.
#   6. Sanity-check Ready nodes.
#
# Budget: ~$6.40/day idle (2x e2-standard-4 on-demand). No NAT cost
# compared with EKS because GKE Standard does not require a NAT
# gateway for Workload Identity / egress.
#
# Follow-up steps (not in this script): cert-manager + MOCO install,
# NFS server apply, SUNK + Slurm helm installs, patch-gke-tolerations.sh,
# install-monitoring.sh. See skills/gke/deploy-sunk-on-gke/SKILL.md.
set -euo pipefail

CLUSTER_NAME="sunk"
ZONE="us-central1-a"
PROJECT_ID="${PROJECT_ID:-}"
CPU_POOL="cpu-4"
CPU_MACHINE="e2-standard-4"
CPU_NODE_COUNT=2
RELEASE_CHANNEL="regular"
ASSUME_YES="false"
DRY_RUN="false"
KUBECONFIG_FLAG=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --name NAME            Cluster name (default: sunk)
  --zone ZONE            GCP zone (default: us-central1-a)
  --project PROJECT_ID   GCP project (default: \$PROJECT_ID env)
  --machine TYPE         CPU machine type (default: e2-standard-4)
  --nodes N              CPU node count (default: 2, minimum 1)
  --pool NAME            Node pool label (default: cpu-4)
  --release-channel CH   GKE release channel (default: regular)
  --kubeconfig FILE      Write credentials to FILE instead of the default kubeconfig
  --dry-run              Print the gcloud command; do not create
  --yes                  Skip confirmation prompt
  -h, --help             Show this help

Estimated cost: ~\$6.40/day idle for the default 2x e2-standard-4 profile.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)             CLUSTER_NAME="$2"; shift 2 ;;
            --zone)             ZONE="$2"; shift 2 ;;
            --project)          PROJECT_ID="$2"; shift 2 ;;
            --machine)          CPU_MACHINE="$2"; shift 2 ;;
            --nodes)            CPU_NODE_COUNT="$2"; shift 2 ;;
            --pool)             CPU_POOL="$2"; shift 2 ;;
            --release-channel)  RELEASE_CHANNEL="$2"; shift 2 ;;
            --kubeconfig)       KUBECONFIG_FLAG="--kubeconfig=$2"; shift 2 ;;
            --dry-run)          DRY_RUN="true"; shift ;;
            --yes)              ASSUME_YES="true"; shift ;;
            -h|--help)          usage; exit 0 ;;
            *) usage >&2; die "unknown argument: $1" ;;
        esac
    done
    [[ -n "$PROJECT_ID" ]] || die "--project or \$PROJECT_ID is required"
    if [[ "$CPU_NODE_COUNT" -lt 1 ]]; then
        die "--nodes must be >= 1 (GKE requires at least 1 node at create time)"
    fi
}

check_prerequisites() {
    local missing=()
    for bin in gcloud kubectl helm jq; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            missing+=("$bin")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "missing required tools: ${missing[*]}. Install them and rerun."
    fi
}

check_auth_and_apis() {
    local account
    account="$(gcloud config get-value account 2>/dev/null || true)"
    if [[ -z "$account" || "$account" == "(unset)" ]]; then
        die "gcloud auth not configured. Run: gcloud auth login"
    fi
    echo "GCP account:  $account"
    echo "GCP project:  $PROJECT_ID"
    echo "GCP zone:     $ZONE"
    echo
    echo "Enabling required APIs (idempotent)..."
    gcloud services enable \
        container.googleapis.com \
        compute.googleapis.com \
        iamcredentials.googleapis.com \
        monitoring.googleapis.com \
        --project="$PROJECT_ID"
}

confirm() {
    if [[ "$ASSUME_YES" == "true" ]]; then return; fi
    echo
    echo "Will create GKE cluster '$CLUSTER_NAME' in '$PROJECT_ID/$ZONE'"
    echo "  nodes: $CPU_NODE_COUNT x $CPU_MACHINE (pool label: $CPU_POOL)"
    echo "  release channel: $RELEASE_CHANNEL"
    echo "  estimated cost: ~\$6.40/day idle (2x e2-standard-4)"
    echo "Proceed? [y/N]"
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || die "aborted by user"
}

run_dry_run() {
    cat <<EOF
gcloud container clusters create "$CLUSTER_NAME" \\
  --project="$PROJECT_ID" --zone="$ZONE" \\
  --num-nodes="$CPU_NODE_COUNT" \\
  --machine-type="$CPU_MACHINE" \\
  --node-labels="cloud.google.com/gke-nodepool=$CPU_POOL" \\
  --release-channel="$RELEASE_CHANNEL" \\
  --enable-ip-alias \\
  --workload-pool="$PROJECT_ID.svc.id.goog"
EOF
    echo
    echo "Dry run complete. No GCP resources were created."
}

create_cluster() {
    echo "Creating GKE cluster (this takes ~5-8 minutes)..."
    if ! gcloud container clusters create "$CLUSTER_NAME" \
        --project="$PROJECT_ID" --zone="$ZONE" \
        --num-nodes="$CPU_NODE_COUNT" \
        --machine-type="$CPU_MACHINE" \
        --node-labels="cloud.google.com/gke-nodepool=$CPU_POOL" \
        --release-channel="$RELEASE_CHANNEL" \
        --enable-ip-alias \
        --workload-pool="$PROJECT_ID.svc.id.goog"; then
        die "gcloud container clusters create failed. You may need to run 'gcloud container clusters delete $CLUSTER_NAME --zone=$ZONE --project=$PROJECT_ID' to clean up partial state."
    fi
}

fetch_credentials() {
    echo "Fetching credentials..."
    if [[ -n "$KUBECONFIG_FLAG" ]]; then
        # Pass via env since gcloud honors KUBECONFIG
        local kc="${KUBECONFIG_FLAG#--kubeconfig=}"
        KUBECONFIG="$kc" gcloud container clusters get-credentials "$CLUSTER_NAME" \
            --zone="$ZONE" --project="$PROJECT_ID"
    else
        gcloud container clusters get-credentials "$CLUSTER_NAME" \
            --zone="$ZONE" --project="$PROJECT_ID"
    fi
}

verify_nodes() {
    echo "Verifying nodes..."
    if ! kubectl $KUBECONFIG_FLAG get nodes; then
        die "kubectl get nodes failed. Is the kubeconfig pointing at the new cluster?"
    fi
    local ready_count
    ready_count="$(kubectl $KUBECONFIG_FLAG get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ')"
    if [[ "$ready_count" -lt "$CPU_NODE_COUNT" ]]; then
        echo "WARN: expected $CPU_NODE_COUNT Ready nodes, found $ready_count. They may still be joining."
    fi
}

main() {
    parse_args "$@"
    check_prerequisites

    if [[ "$DRY_RUN" == "true" ]]; then
        run_dry_run
        return 0
    fi

    check_auth_and_apis
    confirm

    create_cluster
    fetch_credentials
    verify_nodes

    echo
    echo "GKE cluster '$CLUSTER_NAME' is ready."
    echo "Next steps (from deploy-sunk-on-gke skill):"
    echo "  1. helm install cert-manager + MOCO + SUNK + Slurm"
    echo "  2. kubectl apply -f infrastructure/gke/nfs-server.yaml"
    echo "  3. bash infrastructure/gke/patch-gke-tolerations.sh"
    echo "  4. bash infrastructure/gke/install-monitoring.sh --project $PROJECT_ID"
}

main "$@"
