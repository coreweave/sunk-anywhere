---
name: setup-sunk-gpu-monitoring
description: >
  Deploy GPU and Slurm metrics collection using DCGM Exporter, SUNK Syncer,
  and Prometheus-compatible scraping for a SUNK cluster on any provider.
  Includes optional Grafana dashboards. Use when setting up GPU observability,
  monitoring GPU utilization/temperature/power, deploying DCGM exporter,
  configuring Prometheus scraping for GPU or Slurm metrics, verifying syncer
  metrics, checking Slurm node/job/scheduler metrics, or adding Grafana dashboards.
  Trigger phrases: "set up GPU monitoring", "deploy DCGM exporter", "GPU
  metrics", "monitor GPU nodes", "Grafana GPU dashboard", "DCGM on SUNK",
  "syncer metrics", "Slurm metrics", "slurm_node_state", "slurm_jobs_running".
---

# Setup SUNK Monitoring (GPU + Syncer)

Deploy GPU and Slurm cluster metrics collection using DCGM Exporter, SUNK Syncer, and Prometheus-compatible scraping for a SUNK cluster. This skill is provider-agnostic; provider-specific notes are called out where applicable.

## Prerequisites

- Base SUNK deployed with GPU compute nodes (see your provider's deploy and GPU skills under `skills/<provider>/`)
- `monitoring` namespace created: `kubectl create namespace monitoring`

## Scope: what this skill covers

This skill covers the default monitoring stack: DCGM exporter, syncer
metrics, and provider-appropriate scrape configuration (GMP / Prometheus
Operator / standalone Prometheus), plus an optional Grafana.

`facebookresearch/gcm` (GPU Cluster Monitoring — surfaces per-GPU health
as Kubernetes Node conditions) is **NOT** part of the default. It is an
optional extra layer for clusters that need on-node health probing
beyond DCGM metrics. On GKE, install GCM with
`helm-values/gke/gcm-values.yaml` and follow the GCM section in
`skills/gke/deploy-sunk-on-gke/SKILL.md` (Step 9). Skip GCM unless the
user explicitly asks for it.

## Step 1: Deploy DCGM Exporter (Manual DaemonSet)

The DCGM Helm chart (`gpu-helm-charts/dcgm-exporter`) hardcodes `priorityClassName: system-node-critical`, which some managed Kubernetes providers block with quota restrictions on non-system namespaces. **Deploy manually instead.**

### ConfigMap for Metrics Selection

Create `infrastructure/observability/dcgm-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: exporter-metrics-config-map
  namespace: monitoring
data:
  metrics: |
    DCGM_FI_DEV_GPU_UTIL,    gauge, GPU utilization (%).
    DCGM_FI_DEV_MEM_COPY_UTIL, gauge, Memory utilization (%).
    DCGM_FI_DEV_GPU_TEMP,    gauge, GPU temperature (C).
    DCGM_FI_DEV_POWER_USAGE, gauge, Power draw (W).
    DCGM_FI_DEV_FB_USED,     gauge, Framebuffer memory used (MiB).
    DCGM_FI_DEV_FB_FREE,     gauge, Framebuffer memory free (MiB).
    DCGM_FI_DEV_SM_CLOCK,    gauge, SM clock frequency (MHz).
    DCGM_FI_DEV_XID_ERRORS,  gauge, Last XID error encountered.
    DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION, counter, Total energy since boot (mJ).
```

### DaemonSet

Create `infrastructure/observability/dcgm-exporter.yaml`:

Key requirements:
- **DaemonSet** (not Deployment) targeting GPU nodes via nodeAffinity
- **Tolerations** for BOTH the GPU taint (`nvidia.com/gpu` NoSchedule) AND the SUNK lock taint (`sunk.coreweave.com/lock` NoExecute)
- **Privileged security context** for DCGM access
- **NVIDIA driver path**: mount the host NVIDIA driver directory to `/usr/local/nvidia`. The host path varies by provider:
  - **GKE**: `/home/kubernetes/bin/nvidia`
  - **EKS** (GPU-optimized AMI): `/usr/local/nvidia`
  - **Bare-metal**: `/usr/local/nvidia` (or wherever the driver is installed)
- **LD_LIBRARY_PATH**: `/usr/local/nvidia/lib64`
- **NVIDIA_VISIBLE_DEVICES**: `all`
- Metrics on port 9400 at `/metrics`

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels: {app.kubernetes.io/name: dcgm-exporter}
  template:
    metadata:
      labels: {app.kubernetes.io/name: dcgm-exporter}
    spec:
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
        - key: "sunk.coreweave.com/lock"
          operator: "Exists"
          effect: "NoExecute"
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: YOUR_GPU_NODE_LABEL_KEY
                    operator: In
                    values: ["YOUR_GPU_NODE_LABEL_VALUE"]
      containers:
        - name: dcgm-exporter
          image: nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04
          securityContext: {privileged: true}
          args: ["-f", "/etc/dcgm-exporter/default-counters.csv"]
          ports:
            - {name: metrics, containerPort: 9400}
          env:
            - {name: DCGM_EXPORTER_KUBERNETES, value: "true"}
            - {name: DCGM_EXPORTER_LISTEN, value: ":9400"}
            - name: NODE_NAME
              valueFrom:
                fieldRef: {fieldPath: spec.nodeName}
            - {name: NVIDIA_VISIBLE_DEVICES, value: "all"}
            - {name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility"}
            - {name: LD_LIBRARY_PATH, value: "/usr/local/nvidia/lib64"}
          resources:
            requests: {cpu: 50m, memory: 256Mi}
            limits: {cpu: 200m, memory: 512Mi}
          volumeMounts:
            - {name: pod-gpu-resources, mountPath: /var/lib/kubelet/pod-resources, readOnly: true}
            - {name: metrics-config, mountPath: /etc/dcgm-exporter/default-counters.csv, subPath: metrics}
            - {name: nvidia-dir, mountPath: /usr/local/nvidia, readOnly: true}
      volumes:
        - name: pod-gpu-resources
          hostPath: {path: /var/lib/kubelet/pod-resources}
        - name: metrics-config
          configMap:
            name: exporter-metrics-config-map
            items: [{key: metrics, path: metrics}]
        - name: nvidia-dir
          hostPath: {path: /home/kubernetes/bin/nvidia}  # CHANGE THIS per provider (see notes above)
```

### ClusterIP Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: dcgm-exporter
  namespace: monitoring
  labels: {app.kubernetes.io/name: dcgm-exporter}
spec:
  type: ClusterIP
  selector: {app.kubernetes.io/name: dcgm-exporter}
  ports:
    - {name: metrics, port: 9400, targetPort: 9400, protocol: TCP}
```

Replace `YOUR_GPU_NODE_LABEL_KEY`/`YOUR_GPU_NODE_LABEL_VALUE` with the labels identifying your GPU nodes, and update the `nvidia-dir` hostPath for your provider. Then deploy:

```bash
kubectl apply -f infrastructure/observability/dcgm-configmap.yaml
kubectl apply -f infrastructure/observability/dcgm-exporter.yaml
```

## Step 2: Enable Prometheus Scraping

How you scrape DCGM metrics depends on your monitoring stack.

### Google Managed Prometheus (GKE)

Create a `PodMonitoring` CRD:

```yaml
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: dcgm-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels: {app.kubernetes.io/name: dcgm-exporter}
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

### Prometheus Operator (kube-prometheus-stack)

Create a `PodMonitor`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: dcgm-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels: {app.kubernetes.io/name: dcgm-exporter}
  podMetricsEndpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

### Standalone Prometheus

Add a scrape config:

```yaml
scrape_configs:
  - job_name: dcgm-exporter
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [monitoring]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        regex: dcgm-exporter
        action: keep
```

## Step 3: Deploy Grafana (Optional)

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm install grafana grafana/grafana -n monitoring -f infrastructure/observability/grafana-values.yaml
```

Key values for `grafana-values.yaml`:

```yaml
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://YOUR_PROMETHEUS_ENDPOINT:9090
        isDefault: true
        access: proxy

tolerations:
  - key: "sunk.coreweave.com/lock"
    operator: "Exists"
    effect: "NoExecute"

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: YOUR_CPU_NODE_LABEL_KEY
              operator: In
              values: ["YOUR_CPU_NODE_LABEL_VALUE"]
```

Replace `YOUR_PROMETHEUS_ENDPOINT` with the appropriate value for your monitoring stack (e.g., `gmp-frontend.monitoring.svc` for GKE GMP, or `prometheus-server.monitoring.svc` for a standard Prometheus deployment).

Recommended dashboard panels:
- GPU Utilization (`DCGM_FI_DEV_GPU_UTIL`)
- Memory Utilization (`DCGM_FI_DEV_MEM_COPY_UTIL`)
- GPU Temperature (`DCGM_FI_DEV_GPU_TEMP`)
- Power Usage (`DCGM_FI_DEV_POWER_USAGE`)
- Framebuffer Used (`DCGM_FI_DEV_FB_USED`)
- SM Clock (`DCGM_FI_DEV_SM_CLOCK`)
- XID Errors (`DCGM_FI_DEV_XID_ERRORS`)
- Total Energy Consumption (`DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION`)

## Step 4: Enable Scraping for Syncer Metrics

The SUNK syncer exposes Slurm cluster metrics (node states, job counts, scheduler stats) on port 8080. The Helm chart's built-in `PodMonitor` targets Prometheus Operator, which may not be available on all providers. Create the appropriate scrape configuration for your monitoring stack.

The syncer runs in the Slurm namespace (`tenant-slurm`), not `monitoring`, so the scrape configuration must target that namespace.

### Google Managed Prometheus (GKE)

```yaml
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: sunk-syncer
  namespace: tenant-slurm
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: sunk-syncer
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      timeout: 20s
```

### Prometheus Operator

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sunk-syncer
  namespace: tenant-slurm
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: sunk-syncer
  podMetricsEndpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

## Step 5: Verify DCGM Metrics

```bash
# Check all monitoring pods are running
kubectl get pods -n monitoring

# Test DCGM exporter metrics endpoint
kubectl run curl-test -n monitoring --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s http://dcgm-exporter.monitoring.svc:9400/metrics | head -20

# Should show lines like:
# DCGM_FI_DEV_GPU_UTIL{gpu="0",...} 45
# DCGM_FI_DEV_GPU_TEMP{gpu="0",...} 62
```

## Step 6: Verify Syncer Metrics

### Direct endpoint check

Port-forward to the syncer and confirm metrics are flowing:

```bash
kubectl port-forward -n tenant-slurm deploy/slurm-syncer 8080:8080
```

In another terminal:

```bash
# Verify node state metrics
curl -s http://localhost:8080/metrics | grep slurm_node_state

# Should show lines like:
# slurm_node_state{node="slurm-gpu-workers-000-000",partition="gpu",state="idle"} 1
```

### Generate job activity and verify job metrics

Submit a quick job to produce scheduler counters:

```bash
kubectl exec -n tenant-slurm deploy/slurm-login -- srun --mem=100 hostname
```

Then check job metrics:

```bash
curl -s http://localhost:8080/metrics | grep slurm_scheduler_jobs_submitted

# Should show a non-zero value:
# slurm_scheduler_jobs_submitted 1
```

### Key PromQL queries for dashboards

These queries work in any Prometheus-compatible backend once scraping is active:

| Query | What it shows |
|-------|---------------|
| `up{job="sunk-syncer"}` | Syncer scrape target is up |
| `slurm_nodes_idle` | Number of idle Slurm nodes |
| `slurm_jobs_running` | Number of running Slurm jobs |
| `rate(slurm_scheduler_jobs_submitted[5m])` | Job submission rate |
| `slurm_scheduler_cycle_last_seconds` | Last scheduler cycle duration |
| `slurm_node_gpu_alloc` | GPUs allocated per node |
| `slurm_node_gpu_idle` | GPUs idle per node |
| `slurm_queue_pending` | Jobs waiting in the scheduler queue |

## Available DCGM Metrics

| Metric | Description |
|--------|-------------|
| `DCGM_FI_DEV_GPU_UTIL` | GPU utilization (%) |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | Memory utilization (%) |
| `DCGM_FI_DEV_GPU_TEMP` | GPU temperature (C) |
| `DCGM_FI_DEV_POWER_USAGE` | Power draw (W) |
| `DCGM_FI_DEV_FB_USED` | Framebuffer memory used (MiB) |
| `DCGM_FI_DEV_FB_FREE` | Framebuffer memory free (MiB) |
| `DCGM_FI_DEV_SM_CLOCK` | SM clock frequency (MHz) |
| `DCGM_FI_DEV_XID_ERRORS` | Last XID error encountered |
| `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` | Total energy since boot (mJ) |

## Available Syncer Metrics (Key Subset)

The syncer exposes many metrics. These are the most useful for monitoring and dashboards:

| Metric | Description |
|--------|-------------|
| `slurm_node_state` | Current state of each Slurm node (labels: node, partition, state) |
| `slurm_nodes_idle` | Number of idle nodes |
| `slurm_nodes_alloc` | Number of allocated nodes |
| `slurm_nodes_down` | Number of down nodes |
| `slurm_nodes_drain` | Number of drained nodes |
| `slurm_jobs_running` | Running jobs (labels: partition, account, user) |
| `slurm_jobs_pending` | Pending jobs (labels: partition, account, user) |
| `slurm_node_gpu_alloc` | GPUs allocated per node |
| `slurm_node_gpu_idle` | GPUs idle per node |
| `slurm_node_gpu_total` | Total GPUs per node |
| `slurm_scheduler_jobs_submitted` | Total jobs submitted since Slurm start |
| `slurm_scheduler_cycle_last_seconds` | Duration of the last scheduler cycle |
| `slurm_scheduler_dbd_queue` | Items in the accounting database agent queue |
| `slurm_queue_pending` | Jobs pending in the scheduler queue |
| `slurm_queue_running` | Jobs running in the cluster |

For the full list, see the [SUNK syncer documentation](https://docs.coreweave.com/products/sunk/discover_sunk/syncer#metrics).

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| DCGM Helm install fails with "insufficient quota for system-node-critical" | Helm chart hardcodes `priorityClassName: system-node-critical` | Deploy manually as a DaemonSet without the priorityClassName (Step 1) |
| DCGM exporter pod stuck in Pending | Missing tolerations for GPU node taints | Ensure tolerations for both `nvidia.com/gpu` (NoSchedule) and `sunk.coreweave.com/lock` (NoExecute) |
| DCGM pod running but no metrics (empty /metrics) | NVIDIA driver libraries not found in container | Verify host path mount matches your provider's NVIDIA driver location |
| DCGM pod CrashLoopBackOff with "DCGM initialization error" | Driver version mismatch or driver not installed on node | Confirm GPU nodes have the NVIDIA driver installed (`kubectl describe node` should show `nvidia.com/gpu` capacity) |
| Scrape config created but no metrics appear | Label mismatch between scrape selector and DCGM pods | Verify `matchLabels` in your scrape config matches the DaemonSet pod labels exactly |
| Grafana shows "No data" for GPU queries | Prometheus endpoint not reachable or misconfigured | Verify the datasource URL and test the query endpoint directly with curl |
| Syncer metrics endpoint returns empty or connection refused | Syncer pod not running or port mismatch | Verify `kubectl get pods -n tenant-slurm -l app.kubernetes.io/name=sunk-syncer` shows Running, and the container exposes port 8080 |
| `slurm_scheduler_jobs_submitted` stays at zero | No jobs have been submitted since Slurm started | Submit a test job: `kubectl exec -n tenant-slurm deploy/slurm-login -- srun --mem=100 hostname` |
