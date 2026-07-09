#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Install CloudWatch observability for SUNK on EKS.
#
# Default-on, opt-out via --skip-cloudwatch on the orchestrating skill or
# SUNK_SKIP_CLOUDWATCH=1 in the env. Idempotent.
#
# Provisions:
#   1. IRSA role  AmazonEKS_CloudWatchAgent_Role-<cluster> for cloudwatch-agent
#      with the AWS-managed CloudWatchAgentServerPolicy.
#   2. EKS managed add-on  amazon-cloudwatch-observability  (cloudwatch-agent
#      DaemonSet + fluent-bit DaemonSet + DCGM exporter + neuron-monitor +
#      observability controller-manager). Tagged ManagedBy=sunk-anywhere.
#   3. Lock-taint tolerations on the agent + fluent-bit + dcgm DaemonSets so
#      SUNK's sunk.coreweave.com/lock=true:NoExecute taint does not evict
#      them when a Slurm job pins a node.
#   4. CloudWatch dashboards (cluster + jobs) from
#      infrastructure/eks/dashboards/cloudwatch/*.json , templated with the
#      cluster name.
#
#   5. Prometheus scrape of slurm-syncer + dcgm-exporter via the
#      AmazonCloudWatchAgent CR (see observability/cloudwatch-prometheus-*).
#      Adds ~50 streams under namespace `ContainerInsights/Prometheus` —
#      strictly whitelisted via emf_processor.metric_declaration so the
#      ~439 series exposed at idle are NOT all forwarded.
#
# Cost notes (us-east-2, 6-node sunk-eks idle):
#   - ContainerInsights enhanced metrics: ~$5-15/day on a 6-node cluster,
#     dominated by per-container publishing volume.
#   - Prometheus scrape (#5): ~50 streams * $0.30/metric = ~$15/month.
#     Whitelist tightening pushes this lower; removing the metric_declaration
#     would balloon to 400+ streams (~$120/month).
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sunk-eks}"
REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--cluster NAME] [--region REGION] [--profile PROFILE]

Default-on observability backend that publishes ContainerInsights metrics
to CloudWatch and provisions the SUNK cluster + jobs dashboards. Idempotent.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER_NAME="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

PROFILE_FLAG=()
if [ -n "$PROFILE" ]; then PROFILE_FLAG=(--profile "$PROFILE"); fi

ACCOUNT_ID=$(aws sts get-caller-identity "${PROFILE_FLAG[@]}" --query Account --output text)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CW_DASH_DIR="${SCRIPT_DIR}/dashboards/cloudwatch"
ROLE_NAME="AmazonEKS_CloudWatchAgent_Role-${CLUSTER_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo "==> Cluster: $CLUSTER_NAME, Region: $REGION, Account: $ACCOUNT_ID"

# -------------------------------------------------------------------
# 1. IRSA role for cloudwatch-agent
# -------------------------------------------------------------------
echo "==> [1/4] IRSA role $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "    Role exists, skipping create."
else
  eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$REGION" \
    ${PROFILE:+--profile "$PROFILE"} \
    --namespace amazon-cloudwatch \
    --name cloudwatch-agent \
    --role-name "$ROLE_NAME" \
    --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
    --tags "ManagedBy=sunk-anywhere" \
    --approve --override-existing-serviceaccounts >/dev/null
fi

# -------------------------------------------------------------------
# 2. amazon-cloudwatch-observability EKS add-on
# -------------------------------------------------------------------
echo "==> [2/4] amazon-cloudwatch-observability add-on"
if aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name amazon-cloudwatch-observability \
    --region "$REGION" "${PROFILE_FLAG[@]}" >/dev/null 2>&1; then
  echo "    Add-on already installed, skipping."
else
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" --region "$REGION" "${PROFILE_FLAG[@]}" \
    --addon-name amazon-cloudwatch-observability \
    --service-account-role-arn "$ROLE_ARN" \
    --resolve-conflicts OVERWRITE \
    --tags ManagedBy=sunk-anywhere >/dev/null
  aws eks wait addon-active --cluster-name "$CLUSTER_NAME" \
    --addon-name amazon-cloudwatch-observability \
    --region "$REGION" "${PROFILE_FLAG[@]}"
fi

# -------------------------------------------------------------------
# 3. Lock-taint tolerations on the addon's pods
# -------------------------------------------------------------------
echo "==> [3/4] Patching lock-taint tolerations"
PATCH='[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"sunk.coreweave.com/lock","operator":"Exists","effect":"NoExecute"}}]'
for ds in cloudwatch-agent fluent-bit dcgm-exporter; do
  if kubectl -n amazon-cloudwatch get daemonset "$ds" >/dev/null 2>&1; then
    kubectl -n amazon-cloudwatch patch daemonset "$ds" --type=json -p "$PATCH" >/dev/null 2>&1 \
      && echo "    $ds: tolerations patched" \
      || echo "    $ds: already tolerated (or patch rejected)"
  fi
done

# -------------------------------------------------------------------
# 4. CloudWatch dashboards
# -------------------------------------------------------------------
echo "==> [4/4] CloudWatch dashboards"
if [ ! -d "$CW_DASH_DIR" ]; then
  echo "    WARN: $CW_DASH_DIR not found; skipping dashboard create"
else
  for f in "$CW_DASH_DIR"/*.json; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .json)"
    body="$(sed "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" "$f")"
    aws cloudwatch put-dashboard \
      --dashboard-name "${name}" \
      --dashboard-body "$body" \
      --region "$REGION" "${PROFILE_FLAG[@]}" >/dev/null
    # CloudWatch dashboards do not support resource tags via put-dashboard;
    # the destroy script identifies them by name pattern (sunk-eks-*)
    # instead of relying on tags.
    echo "    pushed: $name"
  done
fi

# -------------------------------------------------------------------
# 5. Prometheus scrape (slurm-syncer + dcgm-exporter -> CWAgent EMF)
# -------------------------------------------------------------------
echo "==> [5/5] Prometheus scrape config (slurm + DCGM)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROM_CM="$SCRIPT_DIR/observability/cloudwatch-prometheus-config.yaml"
PROM_PATCH="$SCRIPT_DIR/observability/cloudwatch-prometheus-cr-patch.sh"

if kubectl get ns tenant-slurm >/dev/null 2>&1 && kubectl get ns monitoring >/dev/null 2>&1; then
  if [ -f "$PROM_CM" ]; then
    kubectl apply -f "$PROM_CM"
  else
    echo "    WARN: $PROM_CM missing, skipping ConfigMap"
  fi
  if [ -x "$PROM_PATCH" ]; then
    CLUSTER_NAME="$CLUSTER_NAME" AWS_REGION="$REGION" "$PROM_PATCH"
  else
    echo "    WARN: $PROM_PATCH missing or not executable, skipping CR patch"
  fi
else
  echo "    Skipping: tenant-slurm or monitoring ns not present yet."
  echo "    Re-run this script after Slurm + observability install."
fi

echo
echo "==> Done. CloudWatch console:"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards"
echo "    Look for: ${CLUSTER_NAME}-cluster-cloudwatch, ${CLUSTER_NAME}-jobs-cloudwatch"
echo "    Prometheus metrics: namespace ContainerInsights/Prometheus"
