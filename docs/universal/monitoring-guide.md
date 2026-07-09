# Monitoring Guide

Set up GPU telemetry, Slurm cluster metrics, dashboards, and GPU health checks for SUNK.

## Architecture

SUNK monitoring uses four components that feed into your monitoring platform (Prometheus, Google Cloud Monitoring, etc.):

| Component | What it provides | How it reaches your monitoring stack |
|-----------|-----------------|--------------------------------------|
| **DCGM Exporter** | GPU utilization, temperature, power, VRAM, PCIe, SM/tensor activity | Prometheus scrape (PodMonitor, ServiceMonitor, or provider-managed scraping) |
| **SUNK Syncer** | Slurm node states, job counts, queue depth, scheduler cycles, partition resources | Prometheus scrape on `:8080/metrics` |
| **GCM Health Checks** | GPU hardware validation (XID, ECC, NVLink, DCGM diag, zombies) | NPD node conditions + Prometheus problem_gauge/problem_counter |
| **Dashboards** | Visualization | Provider-specific (Cloud Monitoring JSON, Grafana dashboards, etc.) |

## Step 1: Syncer Metrics

The SUNK syncer exports Slurm metrics on port 8080. Create a monitoring CRD (PodMonitoring, PodMonitor, etc.) so your Prometheus-compatible system scrapes it.

```bash
kubectl apply -f infrastructure/observability/syncer-podmonitoring.yaml
```

### Key Syncer Metrics

| Metric | Description |
|--------|-------------|
| `slurm_nodes_total` / `idle` / `alloc` / `drain` / `down` | Node counts by state |
| `slurm_queue_running` / `pending` / `completed` / `failed` | Job queue state |
| `slurm_job_state` | Per-job state (labels: id, name, user, account, partition, state) |
| `slurm_node_cpu_alloc` / `gpu_alloc` / `mem_alloc` | Per-node resource allocation |
| `slurm_partition_cpu_total` / `gpu_total` | Per-partition totals |
| `slurm_scheduler_cycle_last_seconds` | Scheduler cycle duration |
| `slurm_controller_rpc_count` | RPC call counts by type |

## Step 2: DCGM Exporter

Some providers auto-deploy DCGM Exporter on GPU node pools. If yours does not, install it as a DaemonSet on GPU nodes. Ensure the `LD_LIBRARY_PATH` and `PATH` environment variables point to your provider's NVIDIA driver path (this varies by provider).

### Key DCGM Metrics

| Metric | Description |
|--------|-------------|
| `DCGM_FI_DEV_GPU_UTIL` | GPU core utilization (%) |
| `DCGM_FI_PROF_SM_ACTIVE` | SM active ratio (0-1) |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | Tensor core active ratio (0-1) |
| `DCGM_FI_DEV_GPU_TEMP` | GPU temperature (C) |
| `DCGM_FI_DEV_POWER_USAGE` | Power draw (W) |
| `DCGM_FI_DEV_FB_USED` / `FB_FREE` | VRAM used/free (MiB) |
| `DCGM_FI_PROF_PCIE_TX_BYTES` / `RX_BYTES` | PCIe throughput (bytes/s) |

## Step 3: Dashboards

Dashboards are provided in `infrastructure/observability/` and vary by provider. See your provider's deployment guide for specific instructions.

### Multi-Cluster

When multiple SUNK clusters report to the same monitoring backend, the `cluster` label differentiates data. Set `clusterName` in your slurm-values.yaml to a unique value for each cluster.

## Step 4: GCM GPU Health Checks (Optional)

[GCM](https://github.com/facebookresearch/gcm) runs 6 periodic GPU validation checks via Node Problem Detector.

| Check | What it validates |
|-------|-------------------|
| XID Errors | GPU XID errors in syslog |
| ECC Errors | Uncorrectable/correctable ECC counts |
| GPU Disconnected | GPU count matches expected |
| Zombie Processes | Stale GPU processes |
| NVLink Status | All NVLink lanes up |
| DCGM Diagnostics | Level 1 GPU health check |

### Deploy

```bash
helm install gcm oci://ghcr.io/facebookresearch/charts/gcm \
  --namespace kube-system \
  -f helm-values/gcm-values.yaml
```

Some providers require a post-install patch to mount NVIDIA libraries at non-standard paths. See your provider's adaptations doc for details.

### Verify

```bash
bash examples/06-validate-gcm-health.sh
```

GCM metrics (`problem_gauge`, `problem_counter`) appear in your dashboards under "GPU Health Checks."

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| No syncer metrics | PodMonitoring label mismatch | Label is `app.kubernetes.io/name: sunk-syncer` |
| No DCGM metrics | No GPU nodes or DCGM not deployed | DCGM only runs on GPU nodes; verify DaemonSet is present |
| GCM checks failing | Missing NVIDIA libs | Run provider-specific GCM patch script |
| Dashboard shows no data | Ingestion lag | Wait 2-3 minutes |
