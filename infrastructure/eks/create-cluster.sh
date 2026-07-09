#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Create an EKS cluster for sunk-anywhere using the budget profile.
#
# Conventions contract: docs/eks/conventions.md
# Sibling files:
#   - cluster-config.yaml          eksctl ClusterConfig (templated)
#   - storage/gp3-default.yaml     StorageClass patched as default after create
#
# What this script does (in order):
#   1. Verify prerequisites (eksctl, kubectl, aws, jq, envsubst).
#   2. Verify AWS credentials and print account/arn/region.
#   3. Check Standard vCPU service quota (L-1216C47A) >= 8.
#   4. Prompt for confirmation (unless --yes).
#   5. Render cluster-config.yaml with CLUSTER_NAME and AWS_REGION.
#   6. Run eksctl create cluster against the rendered config.
#   7. Wait for cluster ACTIVE, update local kubeconfig, sanity-check nodes.
#   8. Patch gp2 to non-default and apply gp3 as the default StorageClass.
#
# Budget: ~$5-10/day idle (2x m5.large on-demand + NAT Gateway).
#
# setup-irsa.sh and install-controllers.sh are separate steps; this script
# only produces a cluster with its two initial nodegroups.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_CONFIG="${SCRIPT_DIR}/cluster-config.yaml"
GP3_STORAGECLASS="${SCRIPT_DIR}/storage/gp3-default.yaml"
RENDERED_CONFIG="/tmp/sunk-anywhere-cluster-config.yaml"

CLUSTER_NAME="sunk-eks"
AWS_REGION="us-east-1"
# Honour the caller's exported AWS_PROFILE; only fall back to "default"
# when neither the env var nor --profile flag is set. Without this,
# `AWS_PROFILE=foo bash create-cluster.sh` silently targets "default"
# which is almost always the wrong account.
AWS_PROFILE="${AWS_PROFILE:-default}"
DRY_RUN="false"
ASSUME_YES="false"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --name NAME          Cluster name (default: sunk-eks)
  --region REGION      AWS region (default: us-east-1)
  --profile PROFILE    AWS profile (default: default)
  --dry-run            Render config and print eksctl command; do not create
  --yes                Skip confirmation prompt
  -h, --help           Show this help

Estimated cost: ~\$5-10/day for an empty cluster.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --region)
                AWS_REGION="$2"
                shift 2
                ;;
            --profile)
                AWS_PROFILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --yes)
                ASSUME_YES="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "unknown argument: $1"
                ;;
        esac
    done
}

check_prerequisites() {
    # Tool presence + helm repo setup live in infrastructure/eks/preflight.sh.
    # Re-run it here so direct invocations of create-cluster.sh stay safe
    # without forcing the caller to remember two scripts.
    if ! bash "${SCRIPT_DIR}/preflight.sh" >/dev/null 2>&1; then
        bash "${SCRIPT_DIR}/preflight.sh"  # rerun loud to surface the error
        die "preflight failed"
    fi
}

check_aws_creds() {
    local caller
    if ! caller="$(aws sts get-caller-identity --profile "$AWS_PROFILE" --output json 2>&1)"; then
        echo "$caller" >&2
        die "aws sts get-caller-identity failed for profile '$AWS_PROFILE'. Check credentials."
    fi
    local account arn
    account="$(echo "$caller" | jq -r '.Account')"
    arn="$(echo "$caller" | jq -r '.Arn')"
    echo "AWS account: $account"
    echo "AWS arn:     $arn"
    echo "AWS region:  $AWS_REGION"
    echo "AWS profile: $AWS_PROFILE"
}

# Quota codes used below:
#   L-1216C47A  Standard (A,C,D,H,I,M,R,T,Z) On-Demand vCPU  (control + cpu-workers)
#   L-DB2E81BA  G and VT On-Demand vCPU                       (gpu-workers, on-demand)
#   L-3819A6DF  All G and VT Spot vCPU                        (gpu-workers, spot)
#
# Fallback regions are limited to 4 to keep the cross-region sweep cheap
# (~4 service-quotas calls per quota code). us-east-1 is the default target,
# so the rest are the next most common customer regions for general GPU work.
QUOTA_FALLBACK_REGIONS=(us-east-1 us-east-2 us-west-2 eu-west-1)

# Read one quota value in one region. Prints the value on stdout, nothing on error.
quota_value() {
    local region="$1" code="$2"
    aws service-quotas get-service-quota \
        --service-code ec2 \
        --quota-code "$code" \
        --region "$region" \
        --profile "$AWS_PROFILE" \
        --query 'Quota.Value' --output text 2>/dev/null
}

# Print a table of Standard + G/VT (on-demand) + G/VT (spot) quotas across
# QUOTA_FALLBACK_REGIONS. Used when the target region is too small.
print_cross_region_quota_table() {
    local region std gvt_od gvt_spot
    printf '  %-14s  %-8s  %-12s  %-9s\n' 'Region' 'Std' 'G/VT on-dem' 'G/VT spot' >&2
    for region in "${QUOTA_FALLBACK_REGIONS[@]}"; do
        std="$(quota_value "$region" L-1216C47A)"
        gvt_od="$(quota_value "$region" L-DB2E81BA)"
        gvt_spot="$(quota_value "$region" L-3819A6DF)"
        printf '  %-14s  %-8s  %-12s  %-9s\n' \
            "$region" "${std:-?}" "${gvt_od:-?}" "${gvt_spot:-?}" >&2
    done
}

# Suggest the first alternative region that has >=8 Std AND (if GPU wanted)
# >=8 GVT on-demand or >=8 GVT spot. Empty string if no good candidate.
suggest_alt_region() {
    local want_gpu="$1" region std gvt_od gvt_spot
    for region in "${QUOTA_FALLBACK_REGIONS[@]}"; do
        [[ "$region" == "$AWS_REGION" ]] && continue
        std="$(quota_value "$region" L-1216C47A)"
        awk -v v="${std:-0}" 'BEGIN{exit !(v >= 8)}' || continue
        if [[ "$want_gpu" == "true" ]]; then
            gvt_od="$(quota_value "$region" L-DB2E81BA)"
            gvt_spot="$(quota_value "$region" L-3819A6DF)"
            awk -v o="${gvt_od:-0}" -v s="${gvt_spot:-0}" \
                'BEGIN{exit !(o >= 8 || s >= 8)}' || continue
        fi
        echo "$region"
        return
    done
}

# Infer whether this deploy wants the GPU nodegroup by reading the slurm
# values file if present. Default: false (skill's budget default).
gpu_nodegroup_requested() {
    local slurm_values="${SCRIPT_DIR}/../../helm-values/eks/slurm-values.yaml"
    [[ -f "$slurm_values" ]] || { echo "false"; return; }
    # Grep the simple case: `gpu-workers: \n ...enabled: true` within
    # compute.nodes. A full yaml parse is overkill for a hint.
    if awk '/^    gpu-workers:/{flag=1;next} flag && /^    [a-z]/{flag=0} flag && /enabled:[[:space:]]*true/{print;exit}' \
        "$slurm_values" | grep -q .; then
        echo "true"
    else
        echo "false"
    fi
}

check_vcpu_quota() {
    local std_value want_gpu alt
    want_gpu="$(gpu_nodegroup_requested)"

    if ! std_value="$(quota_value "$AWS_REGION" L-1216C47A)"; then
        die "failed to read Standard vCPU quota (L-1216C47A) in $AWS_REGION. Check permissions."
    fi
    echo "Standard vCPU quota (L-1216C47A) in $AWS_REGION: $std_value"
    # 2x m5.large control + 1x cpu-workers + bootstrap headroom => >= 8.
    if awk -v v="${std_value:-0}" 'BEGIN{exit !(v < 8)}'; then
        echo >&2
        echo "Standard vCPU quota is ${std_value:-0} in $AWS_REGION, need >= 8." >&2
        echo "Cross-region snapshot (GPU columns matter if you plan to enable gpu-workers):" >&2
        print_cross_region_quota_table
        alt="$(suggest_alt_region "$want_gpu")"
        if [[ -n "$alt" ]]; then
            echo >&2
            echo "Suggestion: re-run with --region $alt (has >=8 Std${want_gpu:+ and GPU} headroom)." >&2
        fi
        die "insufficient Standard vCPU quota in $AWS_REGION"
    fi

    if [[ "$want_gpu" != "true" ]]; then
        return
    fi

    # GPU was requested: check both on-demand and spot GVT. Pass if either has headroom.
    local gvt_od gvt_spot
    gvt_od="$(quota_value "$AWS_REGION" L-DB2E81BA)"
    gvt_spot="$(quota_value "$AWS_REGION" L-3819A6DF)"
    echo "G/VT on-demand vCPU (L-DB2E81BA) in $AWS_REGION: ${gvt_od:-0}"
    echo "G/VT spot vCPU      (L-3819A6DF) in $AWS_REGION: ${gvt_spot:-0}"
    if awk -v o="${gvt_od:-0}" -v s="${gvt_spot:-0}" 'BEGIN{exit !(o < 8 && s < 8)}'; then
        echo >&2
        echo "GPU was requested but neither G/VT on-demand nor G/VT spot has >=8 vCPU in $AWS_REGION." >&2
        echo "Cross-region snapshot:" >&2
        print_cross_region_quota_table
        alt="$(suggest_alt_region "true")"
        if [[ -n "$alt" ]]; then
            echo >&2
            echo "Suggestion: re-run with --region $alt (has GPU headroom)." >&2
        else
            echo >&2
            echo "No fallback region has GPU headroom either. Either request an increase or" >&2
            echo "set compute.nodes.gpu-workers.enabled: false and deploy CPU-only." >&2
        fi
        die "insufficient G/VT vCPU quota in $AWS_REGION for the GPU nodegroup"
    fi
}

confirm() {
    if [[ "$ASSUME_YES" == "true" ]]; then
        return
    fi
    echo
    echo "Will create EKS cluster '$CLUSTER_NAME' in region '$AWS_REGION' (profile: $AWS_PROFILE)."
    echo "Estimated cost: ~\$5-10/day. Proceed? [y/N]"
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        die "aborted by user"
    fi
}

render_config() {
    if [[ ! -f "$CLUSTER_CONFIG" ]]; then
        die "cluster config not found: $CLUSTER_CONFIG"
    fi
    # Single quotes here are intentional: envsubst uses the literal string
    # '${CLUSTER_NAME} ${AWS_REGION}' as its allowlist of vars to expand.
    # shellcheck disable=SC2016
    CLUSTER_NAME="$CLUSTER_NAME" AWS_REGION="$AWS_REGION" \
        envsubst '${CLUSTER_NAME} ${AWS_REGION}' \
        < "$CLUSTER_CONFIG" > "$RENDERED_CONFIG"
    echo "Rendered cluster config: $RENDERED_CONFIG"
}

run_dry_run() {
    echo
    echo "=== Rendered cluster-config.yaml ==="
    cat "$RENDERED_CONFIG"
    echo
    echo "=== eksctl command that would run ==="
    echo "eksctl create cluster --config-file $RENDERED_CONFIG --profile $AWS_PROFILE"
    echo
    echo "Dry run complete. No AWS resources were created."
}

create_cluster() {
    echo "Creating EKS cluster (this takes ~15-20 minutes)..."
    if ! eksctl create cluster --config-file "$RENDERED_CONFIG" --profile "$AWS_PROFILE"; then
        die "eksctl create cluster failed. Review output above; you may need to run 'eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION --profile $AWS_PROFILE' to clean up partial state."
    fi
}

wait_for_active() {
    echo "Waiting for cluster to be ACTIVE..."
    if ! aws eks wait cluster-active \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE"; then
        die "cluster did not reach ACTIVE state. Check 'aws eks describe-cluster --name $CLUSTER_NAME'."
    fi
}

update_kubeconfig() {
    echo "Updating local kubeconfig..."
    if ! aws eks update-kubeconfig \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE"; then
        die "aws eks update-kubeconfig failed. Check your kubeconfig permissions."
    fi
}

verify_nodes() {
    echo "Verifying nodes..."
    if ! kubectl get nodes; then
        die "kubectl get nodes failed. Is the kubeconfig pointing at the new cluster?"
    fi
    local ready_count
    ready_count="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ')"
    if [[ "$ready_count" -lt 2 ]]; then
        echo "WARN: expected >= 2 Ready nodes, found $ready_count. They may still be joining."
    fi
}

apply_gp3_default() {
    if [[ ! -f "$GP3_STORAGECLASS" ]]; then
        die "gp3 StorageClass manifest not found: $GP3_STORAGECLASS"
    fi
    echo "Patching gp2 to non-default..."
    if kubectl get storageclass gp2 >/dev/null 2>&1; then
        kubectl patch storageclass gp2 \
            -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    else
        echo "gp2 StorageClass not present, skipping patch"
    fi
    echo "Applying gp3 as the default StorageClass..."
    kubectl apply -f "$GP3_STORAGECLASS"
}

print_cost_estimate() {
    # Advisory — never fatal. The whole point is showing the user $/day
    # before they say yes, not gating on an arbitrary ceiling. The
    # estimator's exit code is ignored.
    local slurm_values="${SCRIPT_DIR}/../../helm-values/eks/slurm-values.yaml"
    local extra=()
    [[ -f "$slurm_values" ]] && extra+=(--slurm-values "$slurm_values")
    echo
    echo "==> Projected cost (before you confirm):"
    python3 "${SCRIPT_DIR}/cost-estimate.py" \
        --cluster-config "$CLUSTER_CONFIG" \
        --region "$AWS_REGION" \
        "${extra[@]}" || true
    echo
}

main() {
    parse_args "$@"
    check_prerequisites
    check_aws_creds
    check_vcpu_quota
    print_cost_estimate
    confirm
    render_config

    if [[ "$DRY_RUN" == "true" ]]; then
        run_dry_run
        return 0
    fi

    create_cluster
    wait_for_active
    update_kubeconfig
    verify_nodes
    apply_gp3_default

    echo
    echo "EKS cluster '$CLUSTER_NAME' is ready."
    echo "Next: run infrastructure/eks/setup-irsa.sh."
}

main "$@"
