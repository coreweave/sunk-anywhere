#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Install Cloud Monitoring dashboards + Workload Identity binding for SUNK on GKE.
#
# This runs automatically at the end of deploy-sunk-on-gke. Customers do
# not call it directly. The contract is zero-touch: the customer approves
# once and provides --project; everything observability-related is set up
# from there.
#
# What this script does (idempotent):
#   1. Enables iamcredentials.googleapis.com and monitoring.googleapis.com.
#   2. Creates the `gmp-reader` GSA and grants it roles/monitoring.viewer.
#   3. Binds `gmp-reader` to the `monitoring/default` KSA via Workload
#      Identity (annotates the KSA with iam.gke.io/gcp-service-account).
#   4. Loops over every `*-gcm-dashboard.json` in
#      infrastructure/observability/ and applies it via
#      `gcloud monitoring dashboards create`, skipping ones that already
#      exist by displayName.
#
# Safe to re-run. Every step tolerates pre-existing state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARDS_DIR="${SCRIPT_DIR}/../observability"

PROJECT_ID="${PROJECT_ID:-}"
GSA_NAME="gmp-reader"
KSA_NAMESPACE="monitoring"
KSA_NAME="default"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --project PROJECT_ID   GCP project (default: \$PROJECT_ID env)
  --gsa NAME             GSA name to create/use (default: gmp-reader)
  --namespace NS         KSA namespace (default: monitoring)
  --ksa NAME             KSA name to annotate (default: default)
  -h, --help             Show this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)    PROJECT_ID="$2"; shift 2 ;;
            --gsa)        GSA_NAME="$2"; shift 2 ;;
            --namespace)  KSA_NAMESPACE="$2"; shift 2 ;;
            --ksa)        KSA_NAME="$2"; shift 2 ;;
            -h|--help)    usage; exit 0 ;;
            *) usage >&2; die "unknown argument: $1" ;;
        esac
    done
    [[ -n "$PROJECT_ID" ]] || die "--project or \$PROJECT_ID is required"
    for bin in gcloud kubectl jq; do
        command -v "$bin" >/dev/null 2>&1 || die "missing required tool: $bin"
    done
}

enable_apis() {
    echo "==> Enabling monitoring APIs (idempotent)"
    gcloud services enable \
        iamcredentials.googleapis.com \
        monitoring.googleapis.com \
        --project="$PROJECT_ID"
}

ensure_gsa() {
    local gsa_email="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
    echo "==> Ensuring GSA $gsa_email"
    if ! gcloud iam service-accounts describe "$gsa_email" \
            --project="$PROJECT_ID" >/dev/null 2>&1; then
        gcloud iam service-accounts create "$GSA_NAME" \
            --display-name="GMP dashboard datasource reader" \
            --project="$PROJECT_ID"
    fi
    echo "==> Granting roles/monitoring.viewer"
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${gsa_email}" \
        --role="roles/monitoring.viewer" \
        --condition=None \
        --quiet >/dev/null
}

bind_workload_identity() {
    local gsa_email="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
    echo "==> Binding $KSA_NAMESPACE/$KSA_NAME KSA to $gsa_email"
    gcloud iam service-accounts add-iam-policy-binding "$gsa_email" \
        --project="$PROJECT_ID" \
        --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${KSA_NAMESPACE}/${KSA_NAME}]" \
        --role="roles/iam.workloadIdentityUser" \
        --quiet >/dev/null

    kubectl get namespace "$KSA_NAMESPACE" >/dev/null 2>&1 \
        || kubectl create namespace "$KSA_NAMESPACE"
    kubectl get serviceaccount "$KSA_NAME" -n "$KSA_NAMESPACE" >/dev/null 2>&1 \
        || kubectl create serviceaccount "$KSA_NAME" -n "$KSA_NAMESPACE"
    kubectl annotate serviceaccount -n "$KSA_NAMESPACE" "$KSA_NAME" \
        "iam.gke.io/gcp-service-account=${gsa_email}" \
        --overwrite
}

install_dashboards() {
    echo "==> Installing GCM dashboards from $DASHBOARDS_DIR"
    shopt -s nullglob
    local files=( "${DASHBOARDS_DIR}"/*-gcm-dashboard.json )
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "WARN: no *-gcm-dashboard.json files found under $DASHBOARDS_DIR"
        return
    fi

    local existing
    existing="$(gcloud monitoring dashboards list \
        --project="$PROJECT_ID" \
        --format="value(displayName)" 2>/dev/null || true)"

    for f in "${files[@]}"; do
        local name
        name="$(jq -r '.displayName' "$f")"
        if grep -Fxq "$name" <<<"$existing"; then
            echo "  - skip: '$name' already exists"
            continue
        fi
        echo "  - create: '$name' from $(basename "$f")"
        gcloud monitoring dashboards create \
            --project="$PROJECT_ID" \
            --config-from-file="$f" >/dev/null
    done
}

main() {
    parse_args "$@"
    enable_apis
    ensure_gsa
    bind_workload_identity
    install_dashboards
    echo
    echo "Monitoring setup complete for project $PROJECT_ID."
    echo "  - View dashboards: https://console.cloud.google.com/monitoring/dashboards?project=${PROJECT_ID}"
    echo "  - GMP datasource KSA: ${KSA_NAMESPACE}/${KSA_NAME} (annotated for $GSA_NAME)"
}

main "$@"
