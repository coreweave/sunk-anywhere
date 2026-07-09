#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Patch the AmazonCloudWatchAgent CR (managed by the
# amazon-cloudwatch-observability addon) to enable Prometheus scraping of the
# in-cluster sunk-syncer and dcgm-exporter endpoints. Resulting metrics land
# in the CloudWatch namespace `ContainerInsights/Prometheus`.
#
# The companion ConfigMap (cloudwatch-prometheus-config.yaml) defines WHICH
# endpoints to scrape. This script wires the agent to read that ConfigMap and
# applies a strict EMF metric_declaration whitelist — without it the agent
# would forward all ~439 series from idle, blowing past the budget.
#
# Idempotent: re-running this overwrites the agent config to the desired
# state. Restarts the cwagent DaemonSet at the end so the new prometheus
# config takes effect.
set -euo pipefail

NS="amazon-cloudwatch"
CR="cloudwatch-agent"
REGION="${AWS_REGION:-us-east-2}"
CLUSTER="${CLUSTER_NAME:-sunk-eks}"

if ! kubectl get amazoncloudwatchagent -n "$NS" "$CR" >/dev/null 2>&1; then
  echo "ERROR: AmazonCloudWatchAgent/$CR not found in $NS — is the addon installed?" >&2
  exit 1
fi

echo "==> Patching $NS/$CR with prometheus scrape config"

# The agent's `.spec.config` is a JSON STRING (not a structured block). We
# inject a `prometheus` block under logs.metrics_collected and keep the
# existing kubernetes/application_signals collectors intact.
#
# WHITELIST DERIVATION: the metric_selectors below are sourced from an audit
# of internal CoreWeave Grafana dashboards and the in-tree grafana-values.yaml.
# We mirror what those
# dashboards plot so customers using only CloudWatch get parity with what
# CoreWeave engineers see in Grafana. Per-job metrics (slurm_job_*, singular)
# are deliberately EXCLUDED — each job_id becomes a separate stream at
# $0.30/month, which doesn't scale. Use Grafana for per-job introspection.
# Dimensions are split across multiple declarations because cluster-aggregate
# metrics (slurm_nodes_*, slurm_queue_*) only need [ClusterName], while
# per-node and per-partition metrics need richer dimensions to be useful.
NEW_CONFIG=$(cat <<'JSON'
{
  "agent": {"region": "us-east-2"},
  "logs": {
    "metrics_collected": {
      "application_signals": {"hosted_in": "sunk-eks"},
      "kubernetes": {
        "cluster_name": "sunk-eks",
        "enhanced_container_insights": true
      },
      "prometheus": {
        "prometheus_config_path": "/etc/prometheusconfig/prometheus.yaml",
        "emf_processor": {
          "metric_namespace": "ContainerInsights/Prometheus",
          "metric_declaration": [
            {
              "source_labels": ["job"],
              "label_matcher": "^sunk-syncer$",
              "dimensions": [["ClusterName"]],
              "metric_selectors": [
                "^slurm_jobs_(running|pending|completed|failed)$",
                "^slurm_nodes_(alloc|comp|down|drain|err|fail|idle|maint|mix|not_responding|resv|total)$",
                "^slurm_queue_(canceled|completed|completing|configuring|failed|node_fail|pending|pending_dependency|preempted|running|suspended|timeout)$",
                "^slurm_scheduler_(backfilled_jobs_total|backfill_cycle_(last|mean)_seconds|backfill_depth_mean|cycle_(last|mean)_seconds|cycle_mean_depth|cycles_per_minute|dbd_queue|jobs_(cancelled|completed|failed|pending|running|started|submitted)|queue|threads)$",
                "^slurm_controller_rpc_count$"
              ]
            },
            {
              "source_labels": ["job"],
              "label_matcher": "^sunk-syncer$",
              "dimensions": [["ClusterName","message_type"]],
              "metric_selectors": [
                "^slurm_controller_rpc_mean_duration_seconds$"
              ]
            },
            {
              "source_labels": ["job"],
              "label_matcher": "^sunk-syncer$",
              "dimensions": [["ClusterName","node"]],
              "metric_selectors": [
                "^slurm_node_(state|cpu_(alloc|idle|total)|gpu_(alloc|idle|total)|mem_(alloc|total)|drain_time)$"
              ]
            },
            {
              "source_labels": ["job"],
              "label_matcher": "^sunk-syncer$",
              "dimensions": [["ClusterName","partition"]],
              "metric_selectors": [
                "^slurm_partition_(cpu|gpu|mem)_(alloc|idle|total)$"
              ]
            },
            {
              "source_labels": ["job"],
              "label_matcher": "^dcgm-exporter$",
              "dimensions": [["ClusterName"], ["ClusterName","Hostname","gpu"]],
              "metric_selectors": [
                "^DCGM_FI_DEV_(GPU_UTIL|MEM_COPY_UTIL|FB_USED|FB_FREE|POWER_USAGE|GPU_TEMP|MEM_CLOCK|SM_CLOCK|XID_ERRORS)$",
                "^DCGM_FI_DEV_ECC_(SBE|DBE)_VOL_TOTAL$",
                "^DCGM_FI_PROF_(GR_ENGINE_ACTIVE|SM_ACTIVE|SM_OCCUPANCY|PIPE_TENSOR_ACTIVE|DRAM_ACTIVE|NVLINK_(RX|TX)_BYTES|PCIE_(RX|TX)_BYTES)$"
              ]
            }
          ]
        }
      }
    }
  },
  "traces": {"traces_collected": {"application_signals": {}}}
}
JSON
)

# Sub in the live cluster name + region so this script is reusable across
# clusters.
NEW_CONFIG="${NEW_CONFIG//us-east-2/$REGION}"
NEW_CONFIG="${NEW_CONFIG//sunk-eks/$CLUSTER}"
# Compact to a single line — `.spec.config` is a string, not a JSON object.
NEW_CONFIG_COMPACT=$(printf '%s' "$NEW_CONFIG" | jq -c .)

# Build a JSON-merge-patch document. We need to:
#   1. Replace .spec.config with the new config string.
#   2. Append a configmap-backed volume + matching volumeMount.
# The CR's volumes/volumeMounts are ARRAYS — JSON merge replaces them
# wholesale. So we read the live arrays, append our entries, and write back.
EXISTING_VOLUMES=$(kubectl get amazoncloudwatchagent -n "$NS" "$CR" -o json | jq '.spec.volumes')
EXISTING_VOLUMEMOUNTS=$(kubectl get amazoncloudwatchagent -n "$NS" "$CR" -o json | jq '.spec.volumeMounts')

NEW_VOLUMES=$(echo "$EXISTING_VOLUMES" | jq '
  map(select(.name != "prometheusconfig"))
  + [{"name":"prometheusconfig","configMap":{"name":"prometheus-config"}}]
')
NEW_VOLUMEMOUNTS=$(echo "$EXISTING_VOLUMEMOUNTS" | jq '
  map(select(.name != "prometheusconfig"))
  + [{"name":"prometheusconfig","mountPath":"/etc/prometheusconfig","readOnly":true}]
')

PATCH=$(jq -n \
  --arg config "$NEW_CONFIG_COMPACT" \
  --argjson volumes "$NEW_VOLUMES" \
  --argjson volumeMounts "$NEW_VOLUMEMOUNTS" \
  '{spec: {config: $config, volumes: $volumes, volumeMounts: $volumeMounts}}')

echo "==> Applying merge patch"
kubectl patch amazoncloudwatchagent -n "$NS" "$CR" --type=merge -p "$PATCH"

# The addon's operator should re-roll the DaemonSet on its own, but force a
# rollout to make the wait below deterministic.
echo "==> Restarting cloudwatch-agent DaemonSet"
kubectl rollout restart daemonset -n "$NS" cloudwatch-agent
kubectl rollout status daemonset -n "$NS" cloudwatch-agent --timeout=3m

echo
echo "==> Done. Verify metrics arrive within ~2 minutes:"
echo "    aws cloudwatch list-metrics --region $REGION \\"
echo "      --namespace ContainerInsights/Prometheus \\"
echo "      --query 'Metrics[].MetricName' --output text | tr '\\t' '\\n' | sort -u"
