---
name: add-gpu-nodes-to-gke
description: >
  Add GPU compute nodes to an existing SUNK (Slurm on Kubernetes) deployment
  running on GKE. Covers GKE node pool creation with driver installation,
  NVIDIA driver path setup via s6, Slurm GRES configuration, verification
  with GPU jobs, and smoke tests including single-GPU CUDA validation and
  multi-node NCCL all-reduce templates. Use when asked to "add GPUs to SUNK on GKE",
  "set up GPU workers on GKE", "configure L4/A100/H100 nodes on GKE SUNK",
  "run GPU jobs on SUNK", or "test NCCL on SUNK".
  Requires the base SUNK deployment from deploy-sunk-on-gke to be healthy.
---

# Add GPU Compute Nodes to SUNK on GKE

Add GPU worker nodes to an existing SUNK deployment on GKE. This involves creating a GKE GPU node pool, configuring NVIDIA driver paths, defining Slurm GPU workers, patching GRES configuration, and verifying GPU job execution.

## Prerequisites

- Base SUNK on GKE deployed and healthy (see `skills/gke/deploy-sunk-on-gke`)
- GPU node pool type selected (see GPU Type Reference Table below)
- Environment variables set from base deployment: `$CLUSTER_NAME`, `$ZONE`,
  `$PROJECT_ID`, and the target `$REGION` (e.g. `us-central1`)
- **Sufficient GPU quota in two places** — check both before any
  `gcloud container clusters create`, `node-pools create`, or
  `clusters resize`. GCP enforces global and regional accelerator quotas
  separately, and only checking one of them is the most common cause of
  resize loops with `Quota '... GPUS' exceeded` errors:

  ```bash
  # 1. Project-global accelerator quota.
  gcloud compute project-info describe \
    --project "$PROJECT_ID" \
    --format="table(quotas.metric,quotas.limit,quotas.usage)" \
    | grep GPUS_ALL_REGIONS

  # 2. Regional accelerator quota (use NVIDIA_L4_GPUS for L4, NVIDIA_A100_GPUS for A100,
  #    NVIDIA_H100_GPUS for H100 — match your $GPU_TYPE).
  gcloud compute regions describe "$REGION" \
    --project "$PROJECT_ID" \
    --format="table(quotas.metric,quotas.limit,quotas.usage)" \
    | grep -E 'NVIDIA_(L4|A100|H100)_GPUS'
  ```

  Both `limit - usage` must be `>=` the GPU count you are about to add. If
  either is short, request an increase via the GCP console (IAM & Admin →
  Quotas) before continuing — the cluster resize can succeed initially but
  the backing managed instance group will fail repeatedly with
  `Quota '...' exceeded` until quota is raised, leaving the node pool
  stuck.

## Step 1: Create GPU Node Pool

```bash
export GPU_POOL="gpu"
export GPU_MACHINE="g2-standard-4"    # 1x L4
export GPU_TYPE="nvidia-l4"
export GPU_COUNT=1

gcloud container node-pools create $GPU_POOL \
  --cluster=$CLUSTER_NAME --zone=$ZONE \
  --machine-type=$GPU_MACHINE \
  --accelerator type=$GPU_TYPE,count=$GPU_COUNT,gpu-driver-version=default \
  --num-nodes=1 \
  --max-surge-upgrade=0 --max-unavailable-upgrade=1
```

**CRITICAL**: `gpu-driver-version=default` is REQUIRED. Without it, GKE creates GPU nodes but does NOT install NVIDIA drivers. The `/usr/local/nvidia` directory will be empty, and `nvidia-smi` will not exist. This is the single most common source of "GPU not working" issues.

**Quota tip**: `--max-surge-upgrade=0 --max-unavailable-upgrade=1` prevents GKE from creating a second GPU node during rolling updates, which fails if you are at your quota limit.

If the pool already exists without drivers installed:

```bash
gcloud container node-pools update $GPU_POOL \
  --cluster=$CLUSTER_NAME --zone=$ZONE \
  --accelerator type=$GPU_TYPE,count=$GPU_COUNT,gpu-driver-version=default \
  --max-surge-upgrade=0 --max-unavailable-upgrade=1
```

## Step 2: NVIDIA Driver Path Setup

GKE mounts NVIDIA drivers at `/usr/local/nvidia` AFTER the container starts. The slurmd process needs these libraries in ldconfig and the binaries in PATH. Add an s6 oneshot at the `compute` level in `helm-values/gke/slurm-values.yaml`:

```yaml
compute:
  s6:
    nvidia-setup:
      type: oneshot
      script: |
        #!/usr/bin/env bash
        if [ -d /usr/local/nvidia/lib64 ]; then
          echo /usr/local/nvidia/lib64 > /etc/ld.so.conf.d/nvidia.conf
          ldconfig
          ln -sf /usr/local/nvidia/bin/nvidia-smi /usr/local/bin/nvidia-smi 2>/dev/null || true
        fi
```

**Important details:**

- This MUST go at `compute.s6`, NOT at `compute.nodes.<name>.s6`. Per-node s6 config does not exist in the chart.
- The `if [ -d ... ]` conditional makes this a safe no-op on CPU-only nodes.
- Without this step, `nvidia-smi` will not be found and GPU libraries will not be linked.

## Step 3: GPU Worker Node Configuration

Add the GPU worker definition to `helm-values/gke/slurm-values.yaml` under `compute.nodes`:

```yaml
compute:
  nodes:
    gpu-workers:
      enabled: true
      image:
        repository: ghcr.io/coreweave/slurm-containers/controller-extras
        tag: v25.05.3-coreweave.5-ubuntu22.04
      replicas: 1                # Match your GPU node count
      gresGpu: "l4:1"           # Format: "type:count" -- must match gres.conf
      env:
        - name: LD_LIBRARY_PATH
          value: "/usr/local/nvidia/lib64"
        - name: PATH
          value: "/usr/local/nvidia/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
          nvidia.com/gpu: "1"    # Request GPU from kubelet
        limits:
          memory: 512Mi
          nvidia.com/gpu: "1"
      nodeSelector:
        cloud.google.com/gke-nodepool: gpu
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: cloud.google.com/gke-nodepool
                    operator: In
                    values: ["gpu"]
```

Key points:

- `gresGpu` format is `"type:count"` and must match what you put in `gres.conf` (Step 4).
- `nvidia.com/gpu` in both requests and limits is required for the kubelet to assign the GPU device to the pod.
- The `nodeSelector` and `affinity` together ensure GPU workers land on GPU nodes only.
- The `toleration` handles the automatic `nvidia.com/gpu:NoSchedule` taint GKE applies to GPU nodes.

## Step 4: Patch gres.conf (Required After EVERY Helm Upgrade)

The SUNK Helm chart hardcodes `gres.conf: AutoDetect=nvml` with NO override mechanism. The SUNK container images lack compile-time NVML support, so autodetection fails silently. You must manually patch the ConfigMap after every `helm install` or `helm upgrade`:

```bash
# Get the GPU pod name
GPU_POD=$(kubectl get pods -n tenant-slurm --no-headers | grep gpu-workers | awk '{print $1}' | head -1)

# Patch with node-specific GRES entry
kubectl patch configmap slurm-slurm-conf -n tenant-slurm --type=merge \
  -p "{\"data\":{\"gres.conf\":\"AutoDetect=nvml\nNodeName=${GPU_POD} Name=gpu Type=l4 File=/dev/nvidia0\n\"}}"

# Restart the GPU worker to pick up the new config
kubectl delete pod -n tenant-slurm $GPU_POD

# Wait for slurmd to re-read gres.conf and report the new Gres line BEFORE
# resuming, otherwise the node re-drains with
# "gres/gpu count reported lower than configured (0 < 1)".
for i in $(seq 1 24); do
  GRES=$(kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
    scontrol show node $GPU_POD 2>/dev/null | grep -oE 'Gres=gpu:[^ ]+' | head -1)
  case "$GRES" in
    Gres=gpu:0|Gres=gpu:\(null\)|"") sleep 5 ;;
    *) echo "$GPU_POD reports $GRES"; break ;;
  esac
done

kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  scontrol update NodeName=$GPU_POD State=RESUME
```

`infrastructure/gke/sunk-post-upgrade.sh` automates this wait-then-resume
loop with a 120s per-pod timeout — prefer it over the manual sequence above
when running after every `helm upgrade`.

**The `NodeName` qualifier is CRITICAL.** Without it, the `File=/dev/nvidia0` line applies to ALL nodes, including CPU workers. CPU nodes will crash trying to stat `/dev/nvidia0` which does not exist on them.

For multiple GPUs per node, use device range syntax: `File=/dev/nvidia[0-7]`

**This patch is destroyed on every `helm upgrade`.** Always script it as a post-upgrade step. See `skills/universal/upgrade-sunk` for the automated post-upgrade workflow.

## Step 5: Label GPU Nodes (For Pod Scheduler)

If using the SUNK pod scheduler, GPU nodes need a class label:

```bash
GPU_NODE=$(kubectl get nodes -l cloud.google.com/gke-nodepool=gpu -o name | head -1)
kubectl label $GPU_NODE gpu.nvidia.com/class=NVIDIA_L4
```

This maps to the `scheduler.config.scheduler.gpuTypes.NVIDIA_L4: l4` entry in the scheduler config.

## Step 6: Verify

```bash
# Check node status -- should show "idle", NOT "INVALID_REG" or "DOWN"
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo

# Run nvidia-smi through Slurm to confirm end-to-end GPU access
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  srun --partition=gpu-workers --gres=gpu:1 --mem=100 nvidia-smi
```

Expected output: NVIDIA GPU information showing driver version, CUDA version, temperature, and memory usage.

## Step 7: GPU Smoke Tests

### Single-GPU Sanity Test (works with 1 L4)

After Step 6 succeeds, run a CUDA compute test to verify the GPU is usable beyond just `nvidia-smi`:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  srun --partition=gpu-workers --gres=gpu:1 --mem=4000 \
  bash -c 'python3 -c "import torch; t=torch.ones(1000,device=\"cuda\"); print(f\"CUDA OK: {t.sum()}\")"'
```

Expected output: `CUDA OK: 1000.0`. This confirms the CUDA runtime, driver, and PyTorch can all allocate and compute on the GPU.

If `python3` or `torch` is not available in the container image, the `nvidia-smi` test from Step 6 is sufficient to confirm GPU access. The PyTorch test is a stronger signal when the image supports it.

### Multi-Node NCCL All-Reduce Template (requires 2+ GPU nodes)

This template tests GPU-to-GPU communication across nodes using NCCL all-reduce. It requires at least 2 GPU nodes in the node pool and `all_reduce_perf` from the [nccl-tests](https://github.com/NVIDIA/nccl-tests) suite installed in the container image.

**Run when GPU quota allows.** The default GKE `GPUS_ALL_REGIONS` quota is typically 1, which limits you to a single GPU node. Request a quota increase before attempting multi-node tests.

Save as `nccl-test.sbatch` on the login node (or pipe via `kubectl exec`):

```bash
#!/bin/bash
#SBATCH --job-name=nccl-test
#SBATCH --partition=gpu-workers
#SBATCH --nodes=2
#SBATCH --gpus-per-node=1
#SBATCH --ntasks-per-node=1
#SBATCH --output=nccl_%j.out

/usr/bin/all_reduce_perf -b 8 -e 256M -f 2 -g 1
```

**Prerequisites for multi-node NCCL on GKE (full checklist):**

- `GPUS_ALL_REGIONS >= 2` and the regional accelerator quota
  (`NVIDIA_L4_GPUS`, `NVIDIA_A100_GPUS`, etc.) `>= 2` in `$REGION`. Both
  must be true. See the Prerequisites section above for the preflight
  commands. Quota stockouts here are the dominant cause of NCCL failing
  at `13-nccl-test.sh` time, not at run time.
- 2+ GPU nodes in the pool (`--num-nodes=2` in Step 1) **or** one node
  with at least 2 GPUs (e.g. `g2-standard-24` for 2x L4).
- Slurm `compute.nodes.gpu-workers.replicas: 2` (in
  `helm-values/gke/slurm-values.yaml`) when scaling out across two
  1-GPU nodes — the chart needs one Slurm worker pod per GPU node.
- `infrastructure/gke/sunk-post-upgrade.sh` rerun after scaling so
  `gres.conf` has one
  `NodeName=<gpu-pod> Name=gpu Type=<type> File=/dev/nvidia0` line per GPU
  worker pod. Without this, scontrol shows the new worker but Slurm
  cannot route a GPU to it.
- `hostNetwork: true` on compute pods (required for NCCL socket transport
  on GKE, no InfiniBand).
- `all_reduce_perf` binary available in the container image (build from
  [nccl-tests](https://github.com/NVIDIA/nccl-tests) or use an image that
  includes it). If the binary is missing, `13-nccl-test.sh` fails with a
  payload error, not a scheduler error — distinguishing the two avoids
  chasing the wrong bug.

If any item above is missing, `examples/13-nccl-test.sh` should report
`SKIPPED` rather than `FAIL`. A `FAIL` here always indicates a real
problem; do not paper over it by lowering the GPU requirement in the
test.

If `all_reduce_perf` is not in the image, a minimal PyTorch distributed test achieves the same validation:

```bash
#!/bin/bash
#SBATCH --job-name=nccl-torch-test
#SBATCH --partition=gpu-workers
#SBATCH --nodes=2
#SBATCH --gpus-per-node=1
#SBATCH --ntasks-per-node=1
#SBATCH --output=nccl_torch_%j.out

srun python3 -c "
import torch
import torch.distributed as dist
import os

dist.init_process_group('nccl')
rank = dist.get_rank()
t = torch.ones(1000, device='cuda') * rank
dist.all_reduce(t)
print(f'Rank {rank}: all_reduce sum = {t[0].item()} (expected {sum(range(dist.get_world_size()))})')
dist.destroy_process_group()
"
```

## GPU Type Reference Table

| GKE Machine Type | GPU | Slurm GRES Type | gresGpu Value |
|------------------|-----|------------------|---------------|
| g2-standard-4 | 1x L4 | l4 | "l4:1" |
| g2-standard-24 | 2x L4 | l4 | "l4:2" |
| a2-highgpu-1g | 1x A100 40GB | a100 | "a100:1" |
| a2-highgpu-8g | 8x A100 40GB | a100 | "a100:8" |
| a3-highgpu-8g | 8x H100 80GB | h100 | "h100:8" |

When changing GPU types, update ALL of the following consistently:

1. `$GPU_TYPE` and `$GPU_MACHINE` in the node pool creation (Step 1)
2. `gresGpu` in the compute node config (Step 3)
3. `Type=` and `File=` in the gres.conf patch (Step 4)
4. The `gpu.nvidia.com/class` label value (Step 5)

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `nvidia-smi: command not found` | s6 nvidia-setup script missing or `/usr/local/nvidia` not mounted | Verify `gpu-driver-version=default` on node pool. Check s6 config is at `compute.s6`, not per-node. Exec into pod and check if `/usr/local/nvidia/lib64` exists. |
| GPU node stuck in `INVALID_REG` | gres.conf mismatch between what Slurm expects and what the node reports | Patch gres.conf (Step 4), delete the GPU pod, then `scontrol update State=RESUME`. |
| `error: can't stat /dev/nvidia0` on CPU nodes | gres.conf `File=` line missing `NodeName` qualifier | Add `NodeName=$GPU_POD` prefix to the gres.conf entry so it only applies to GPU pods. |
| NVML autodetect silently fails | SUNK container images lack compile-time NVML | Expected behavior. Always use explicit `NodeName ... File=/dev/nvidia0` entries. |
| GPU quota exceeded during node pool update | GKE tries to create a surge node | Use `--max-surge-upgrade=0 --max-unavailable-upgrade=1` on node pool create/update. |
| GPU driver not installed on node | Node pool created without `gpu-driver-version=default` | Update the node pool with `gcloud container node-pools update` adding the accelerator flag with `gpu-driver-version=default`. |
| Pod stuck `Pending` with `Insufficient nvidia.com/gpu` | No GPU capacity or nodeSelector mismatch | Check `kubectl describe node` for allocatable GPUs. Verify `nodeSelector` matches pool label. |
| GPU jobs hang or produce CUDA errors | `LD_LIBRARY_PATH` not set | Verify env vars in compute node config (Step 3) include `/usr/local/nvidia/lib64`. |
| gres.conf reset after helm upgrade | Chart overwrites the ConfigMap | Re-run the gres.conf patch (Step 4) after every `helm upgrade`. Script it. |
| Node shows `DOWN` after pod restart | Slurm controller hasn't resumed the node | Run `scontrol update NodeName=$GPU_POD State=RESUME` from the login node. |
