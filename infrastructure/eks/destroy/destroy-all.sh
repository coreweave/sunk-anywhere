#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Master teardown for SUNK-on-EKS. Runs each delete-*.sh in reverse order of
# the create-* bootstrap scripts. Collects errors and continues; prints a
# summary at the end and checks for residual AWS resources tagged
# ManagedBy=sunk-anywhere (per docs/eks/conventions.md).
#
# SAFETY: prompts for confirmation unless --yes is given. Dry-run mode prints
# the plan without executing anything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
DRY_RUN="false"
ASSUME_YES="false"

STEPS=(
  "delete-slurm.sh"
  "delete-observability.sh"
  "delete-storage.sh"
  "delete-controllers.sh"
  "delete-irsa.sh"
  "delete-cluster.sh"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --cluster NAME       Cluster name (default: sunk-eks)
  --region REGION      AWS region (default: us-east-1)
  --profile PROFILE    AWS profile (default: unset)
  --dry-run            Print the plan without executing
  --yes                Skip confirmation prompt
  -h, --help           Show this help

Runs (in order):
  1. delete-slurm.sh          Helm releases + slurm namespace
  2. delete-observability.sh  kube-prometheus-stack, DCGM, PodMonitor, monitoring ns
  3. delete-storage.sh        PV/PVC + EFS + security group
  4. delete-controllers.sh    MOCO, cert-manager, ALB controller, EFS CSI, EBS CSI add-on
  5. delete-irsa.sh           IRSA service accounts + IAM policies
  6. delete-cluster.sh        eksctl delete cluster (control plane + nodegroups + VPC)

Blast-radius filter: tag ManagedBy=sunk-anywhere. A residual-resource check
runs at the end.
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER_NAME="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --dry-run) DRY_RUN="true"; shift;;
    --yes) ASSUME_YES="true"; shift;;
    -h|--help) usage;;
    *) echo "Unknown: $1"; usage;;
  esac
done

PROFILE_FLAG=()
if [ -n "$PROFILE" ]; then PROFILE_FLAG=(--profile "$PROFILE"); fi

FORWARDED_ARGS=(--cluster "$CLUSTER_NAME" --region "$REGION")
if [ -n "$PROFILE" ]; then
  FORWARDED_ARGS+=(--profile "$PROFILE")
fi

confirm() {
  if [ "$ASSUME_YES" = "true" ]; then return; fi
  echo
  echo "Will DESTROY cluster '$CLUSTER_NAME' and all tagged AWS resources (EFS, SG, IAM roles, policies). THIS IS IRREVERSIBLE. Continue? [y/N]"
  read -r answer
  if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
    echo "Aborted by user."
    exit 1
  fi
}

print_plan() {
  echo "==> Destroy plan for cluster '$CLUSTER_NAME' in $REGION (profile: ${PROFILE:-default})"
  echo
  echo "    Steps (in order):"
  local i=1
  for step in "${STEPS[@]}"; do
    echo "      $i. $SCRIPT_DIR/$step ${FORWARDED_ARGS[*]}"
    i=$((i+1))
  done
  echo
  echo "    Followed by a residual-resources check via resourcegroupstaggingapi"
  echo "    for tag ManagedBy=sunk-anywhere in $REGION."
}

run_step() {
  local script="$1"
  local path="$SCRIPT_DIR/$script"
  echo
  echo "============================================================"
  echo "==> Running $script"
  echo "============================================================"
  if [ ! -x "$path" ]; then
    echo "ERROR: $path is not executable or not found"
    return 1
  fi
  "$path" "${FORWARDED_ARGS[@]}"
}

main() {
  echo "==> SUNK-on-EKS destroy-all"
  echo "    Cluster: $CLUSTER_NAME"
  echo "    Region:  $REGION"
  echo "    Profile: ${PROFILE:-default}"

  if [ "$DRY_RUN" = "true" ]; then
    print_plan
    echo
    echo "Dry run complete. No resources touched."
    exit 0
  fi

  confirm

  local failures=()
  for step in "${STEPS[@]}"; do
    if ! run_step "$step"; then
      echo "WARN: step $step failed, continuing"
      failures+=("$step")
    fi
  done

  # CloudWatch dashboards do NOT support resource tags via put-dashboard, and
  # the cluster-logging log groups created by eksctl do not carry our
  # ManagedBy tag either. Both leak through the tag-based residual sweep
  # below, so delete them by name pattern matching the cluster.
  echo
  echo "============================================================"
  echo "==> Cleaning CloudWatch dashboards (by name)"
  echo "============================================================"
  local cw_dashes
  cw_dashes=$(aws cloudwatch list-dashboards --region "$REGION" "${PROFILE_FLAG[@]}" \
    --dashboard-name-prefix "${CLUSTER_NAME}-" \
    --query 'DashboardEntries[].DashboardName' --output text 2>/dev/null || true)
  if [ -n "$cw_dashes" ] && [ "$cw_dashes" != "None" ]; then
    # delete-dashboards takes up to 100 names per call; we have at most 2-3.
    # shellcheck disable=SC2086
    aws cloudwatch delete-dashboards --region "$REGION" "${PROFILE_FLAG[@]}" \
      --dashboard-names $cw_dashes >/dev/null 2>&1 \
      && echo "    Deleted: $cw_dashes" \
      || echo "    WARN: could not delete some dashboards: $cw_dashes"
  else
    echo "    No CloudWatch dashboards prefixed with '${CLUSTER_NAME}-' found."
  fi

  echo
  echo "============================================================"
  echo "==> Cleaning CloudWatch log groups (by prefix)"
  echo "============================================================"
  local lg
  for lg_prefix in "/aws/eks/${CLUSTER_NAME}/cluster" "/aws/containerinsights/${CLUSTER_NAME}/" "/aws/cloudwatch-agent/${CLUSTER_NAME}"; do
    aws logs describe-log-groups --region "$REGION" "${PROFILE_FLAG[@]}" \
      --log-group-name-prefix "$lg_prefix" \
      --query 'logGroups[].logGroupName' --output text 2>/dev/null \
    | tr '\t' '\n' \
    | while read -r lg; do
        [ -z "$lg" ] && continue
        aws logs delete-log-group --region "$REGION" "${PROFILE_FLAG[@]}" \
          --log-group-name "$lg" >/dev/null 2>&1 \
          && echo "    Deleted: $lg" \
          || echo "    WARN: could not delete: $lg"
      done
  done

  echo
  echo "============================================================"
  echo "==> Summary"
  echo "============================================================"
  if [ "${#failures[@]}" -eq 0 ]; then
    echo "    All steps completed without error."
  else
    echo "    ${#failures[@]} step(s) reported errors:"
    for f in "${failures[@]}"; do
      echo "      - $f"
    done
  fi

  echo
  echo "==> Checking for residual resources tagged ManagedBy=sunk-anywhere in $REGION"
  local residual
  residual=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=ManagedBy,Values=sunk-anywhere" \
    --region "$REGION" "${PROFILE_FLAG[@]}" \
    --query "ResourceTagMappingList[].ResourceARN" \
    --output text 2>/dev/null || echo "")

  if [ -n "$residual" ] && [ "$residual" != "None" ]; then
    echo "WARNING: residual resources tagged ManagedBy=sunk-anywhere remain:"
    for arn in $residual; do
      echo "  - $arn"
    done
    exit 1
  fi

  echo "    No residual tagged resources. Destroy complete."
  if [ "${#failures[@]}" -gt 0 ]; then
    exit 1
  fi
}

main
