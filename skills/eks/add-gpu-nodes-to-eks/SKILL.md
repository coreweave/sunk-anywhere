---
name: add-gpu-nodes-to-eks
description: >
  Add a GPU managed nodegroup to an existing SUNK (Slurm on Kubernetes)
  deployment running on EKS. Covers AWS G/VT quota checks, budget-friendly
  A10G/L4 profiles and opt-in production A100/H100 profiles, nodegroup
  creation via eksctl, NVIDIA device-plugin verification (EKS GPU AMI
  auto-installs it), enabling the pre-defined gpu-workers nodeset in Slurm
  values, system-toleration patching, and end-to-end Slurm GPU smoke tests.
  Use when asked to "add GPUs to SUNK on EKS", "set up GPU workers on EKS",
  "configure A10G/L4/A100/H100 nodes on EKS SUNK", or "run GPU jobs on SUNK-EKS".
  Requires the base SUNK deployment from deploy-sunk-on-eks to be healthy.
---

# Add GPU Compute Nodes to SUNK on EKS

Add a GPU worker nodegroup to an existing SUNK-on-EKS deployment. Unlike GKE, EKS relies on the AWS-provided GPU AMI (`AmazonLinux2-EKS-1.30-GPU`) which pre-installs NVIDIA drivers, the container-toolkit, and the nvidia-device-plugin daemonset. The work on the Slurm side is therefore smaller: add the nodegroup, flip `gpu-workers.enabled: true`, patch system tolerations, and verify.

Conventions contract: `docs/eks/conventions.md`. Labels, nodegroup names, and tags in this skill come from there.

## Prerequisites

- Base SUNK on EKS deployed and healthy (see `skills/eks/deploy-sunk-on-eks`)
- AWS CLI and `eksctl` installed and authenticated against the target account
- G/VT vCPU quota available in-region (Step 1 checks this)
- Environment variables from the base deployment: `$CLUSTER_NAME`, `$AWS_REGION`, `$AWS_PROFILE`

## Step 1: Check GPU quota

AWS separates on-demand and spot quotas for the G/VT instance family (g5, g6). A default account has 0 or 8 vCPU in each - enough for a single `g5.xlarge` (4 vCPU) but not much more. Request increases 1-24h in advance because approval is not instant.

```bash
# On-demand G/VT vCPU limit
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-DB2E81BA \
  --region $AWS_REGION --profile $AWS_PROFILE

# Spot G/VT vCPU limit
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-3819A6DF \
  --region $AWS_REGION --profile $AWS_PROFILE
```

If `Value < 4`, request an increase before continuing:

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-DB2E81BA \
  --desired-value 8 \
  --region $AWS_REGION --profile $AWS_PROFILE
```

Wait until the request status is `CASE_CLOSED` with `APPROVED` before proceeding. AWS typically takes 1-24h for small increases. For production profiles (p4de/p5) you will also need `L-7212CCBC` (P instance on-demand) raised; defaults there are often 0.

## Step 2: Choose a GPU profile

The budget profile keeps the cluster under the $50/day ceiling defined in conventions. Production profiles are opt-in and will blow that budget by 10-50x.

### Budget profile (default, recommended)

| Instance | GPU | vCPU | RAM | On-demand $/hr | Spot $/hr | gresGpu |
|----------|-----|------|-----|----------------|-----------|---------|
| `g5.xlarge` | 1x A10G 24GB | 4 | 16 GiB | $1.006 | ~$0.35 | `a10g:1` |
| `g6.xlarge` | 1x L4 24GB | 4 | 16 GiB | $0.805 | ~$0.32 | `l4:1` |

Default is `g5.xlarge` (A10G). Use `g6.xlarge` (L4) as the fallback if your G/VT quota is tied up on g5 or if `g5.xlarge` is unavailable in your target AZ.

### Production profile (opt-in, blows budget)

| Instance | GPU | vCPU | RAM | On-demand $/hr | $/day | gresGpu |
|----------|-----|------|-----|----------------|-------|---------|
| `g5.2xlarge` | 1x A10G 24GB | 8 | 32 GiB | $1.212 | ~$29 | `a10g:1` |
| `p4de.24xlarge` | 8x A100 80GB | 96 | 1152 GiB | $32.77 | **~$786** | `a100:8` |
| `p5.48xlarge` | 8x H100 80GB | 192 | 2048 GiB | $98.32 | **~$2360** | `h100:8` |

Only select a production instance if the user has explicitly opted in and acknowledged the spend. `g5.2xlarge` is the soft upgrade for more CPU/RAM per A10G; p4de/p5 are real multi-GPU nodes for distributed training.

## Step 3: Add the GPU nodegroup via eksctl

Write the nodegroup spec to a temp file rather than editing `infrastructure/eks/cluster-config.yaml` in place. `eksctl create nodegroup --config-file` only reads `managedNodeGroups`, so a standalone file is both cleaner and reversible.

Create `/tmp/gpu-nodegroup.yaml`:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}

managedNodeGroups:
  - name: gpu-workers
    instanceType: g5.xlarge        # or g6.xlarge, g5.2xlarge, p4de.24xlarge, p5.48xlarge
    amiFamily: AmazonLinux2023      # REQUIRED. AL2 uses cgroup v1 hybrid and slurmd fails with
                                    # "The cgroup mountpoint /sys/fs/cgroup is not mounted" in
                                    # the SUNK container. AL2023 ships cgroup v2 unified.
                                    # EKS auto-picks the *-GPU AMI for g5/g6/p4/p5 families.
    desiredCapacity: 1
    minSize: 0
    maxSize: 1
    spot: true                      # comment out if spot G/VT quota blocked; falls back to on-demand
    volumeSize: 200                 # GPU AMI + container images + Enroot scratch need headroom
    volumeType: gp3
    labels:
      eks.amazonaws.com/nodegroup: gpu-workers
    tags:
      Environment: dev
      Service: sunk
      ManagedBy: sunk-anywhere
      Owner: auto-cleanup
      Nodegroup: gpu-workers
```

Apply:

```bash
envsubst < /tmp/gpu-nodegroup.yaml | eksctl create nodegroup \
  --config-file - --profile $AWS_PROFILE
```

Wait for nodes to register and become `Ready`:

```bash
kubectl wait --for=condition=Ready nodes \
  -l eks.amazonaws.com/nodegroup=gpu-workers --timeout=15m
```

**Do not manually taint GPU nodes.** The EKS GPU AMI automatically applies `nvidia.com/gpu=present:NoSchedule`. The `gpu-workers` nodeset in `slurm-values.yaml` already tolerates it (see conventions doc).

## Step 4: Verify the NVIDIA device plugin found the GPUs

The EKS GPU-optimized AMI pre-installs `nvidia-device-plugin-daemonset` into `kube-system`. You do not need to helm-install it yourself (this is the biggest divergence from GKE, where the driver install is an explicit flag). Verify allocatable GPU capacity on the new node:

```bash
kubectl get nodes -l eks.amazonaws.com/nodegroup=gpu-workers \
  -o json | jq '.items[].status.capacity["nvidia.com/gpu"]'
# Expected: "1" for g5.xlarge / g6.xlarge / g5.2xlarge
#           "8" for p4de.24xlarge / p5.48xlarge
```

If the value is `0`, `null`, or missing:

1. Wait 60-90s - the device plugin daemonset can take a moment to land on a freshly joined node.
2. Check the plugin is running: `kubectl get ds nvidia-device-plugin-daemonset -n kube-system` - `DESIRED == READY` and covers the GPU node.
3. If the plugin pod is `Pending` on the GPU node due to the lock taint, proceed to Step 6 (patch tolerations) first, then recheck.

## Step 5: Enable the gpu-workers nodeset in Slurm values

The `gpu-workers` nodeset is already defined (but disabled) in `helm-values/eks/slurm-values.yaml`. Flip it on and align `gresGpu` with your chosen instance.

Edit `helm-values/eks/slurm-values.yaml` under `compute.nodes.gpu-workers`:

```yaml
compute:
  nodes:
    gpu-workers:
      enabled: true                 # was false
      replicas: 1                   # match maxSize of the nodegroup
      gresGpu: "a10g:1"            # g5.xlarge A10G; use "l4:1" for g6, "a100:8" for p4de, "h100:8" for p5
      resources:
        requests:
          cpu: "2"
          memory: 12Gi
          nvidia.com/gpu: "1"       # bump to "8" for p4de/p5
        limits:
          memory: 14Gi
          nvidia.com/gpu: "1"       # bump to "8" for p4de/p5
```

Keep the existing `nodeSelector`, `tolerations`, and image - they are already correct per conventions.

Also update the scheduler GPU-type map at the bottom of `slurm-values.yaml`:

```yaml
scheduler:
  config:
    scheduler:
      gpuTypes:
        NVIDIA_A10G: a10g            # or NVIDIA_L4: l4 / NVIDIA_A100: a100 / NVIDIA_H100: h100
```

If you switched to a much bigger instance (p4de/p5), revisit `slurmConfig.DefMemPerCPU` and `compute.reservedMemory`. The default `3000 MiB` and `2048 MiB` are sized for the `m5.large` floor and will under-utilize a big GPU node, but they will not break it. Leave them for now and tune later.

Upgrade:

```bash
helm upgrade slurm coreweave/slurm -n slurm \
  -f helm-values/base/slurm-values.yaml \
  -f helm-values/eks/slurm-values.yaml
```

## Step 6: Patch system daemonsets for the lock taint

SUNK's syncer applies `sunk.coreweave.com/lock=true:NoExecute` to compute nodes while a Slurm job is running. Any pod that lacks this toleration is evicted mid-job, including `kube-proxy`, `aws-node`, `ebs-csi-node`, `efs-csi-node`, and `nvidia-device-plugin-daemonset`. Losing the device plugin mid-job kills GPU visibility for pods that start after eviction.

Run the toleration patcher to add `sunk.coreweave.com/lock:NoExecute` as a tolerated taint on all five daemonsets:

```bash
# See skills/eks/patch-eks-system-tolerations/SKILL.md for the full script.
bash infrastructure/eks/patch-eks-tolerations.sh
```

Re-run this after every EKS cluster upgrade or addon reinstall - AWS rewrites the system daemonsets and your patches are lost.

## Step 7: Verify the GPU is visible to Slurm

Confirm Slurm sees the GPU and can allocate it:

```bash
kubectl exec -n slurm slurm-login-0 -c sshd -- \
  sinfo --Format=nodehost,partition,gres
# Expected: the gpu-workers partition lists a node with gpu:a10g:1 (or l4:1 / a100:8 / h100:8).

kubectl exec -n slurm slurm-login-0 -c sshd -- \
  srun --partition=gpu-workers --gres=gpu:a10g:1 --mem=100 nvidia-smi
# Expected: nvidia-smi output showing the A10G (or L4/A100/H100) - driver, CUDA, memory.
```

If `sinfo` shows the node `INVALID_REG` or `DOWN`:

1. Check the compute pod is running: `kubectl get pods -n slurm -l app.kubernetes.io/name=slurm,sunk.coreweave.com/nodeset=gpu-workers`.
2. If the pod is `Pending` with `Insufficient nvidia.com/gpu`, the device plugin did not claim the GPU - revisit Step 4.
3. If the pod is `Running` but Slurm says `INVALID_REG`, gres autodetection mismatched. Unlike GKE, EKS's AL2-GPU AMI has a working NVML, so `AutoDetect=nvml` should succeed. If it fails, fall back to the explicit `gres.conf` patch pattern from `skills/gke/add-gpu-nodes-to-gke` (Step 4 there).

## Step 8: GPU smoke tests

### Single-GPU CUDA sanity check

```bash
kubectl exec -n slurm slurm-login-0 -c sshd -- \
  srun --partition=gpu-workers --gres=gpu:a10g:1 --mem=4000 \
  bash -c 'python3 -c "import torch; t=torch.ones(1000, device=\"cuda\"); print(f\"CUDA OK: {t.sum().item()}\")"'
# Expected: CUDA OK: 1000.0
```

### Multi-node NCCL (requires 2+ GPU nodes, opt-in)

Out of scope for the budget profile (`maxSize: 1`). To run it, bump the nodegroup's `maxSize`/`desiredCapacity` to 2+, rerun `helm upgrade` with `gpu-workers.replicas` raised to match, and use the sbatch template from `skills/gke/add-gpu-nodes-to-gke` Step 7. Note that EKS without EFA uses plain TCP for NCCL (no RDMA), so bandwidth will be ~1/10th of an IB-backed cluster; this is fine for correctness testing but not perf benchmarks.

## Cleanup

Scaling the nodegroup to zero is free of instance cost but still pays for the nodegroup's NAT egress and any EBS volumes that stayed attached. For clean teardown:

```bash
eksctl delete nodegroup \
  --cluster $CLUSTER_NAME --name gpu-workers \
  --region $AWS_REGION --profile $AWS_PROFILE
```

Then flip `compute.nodes.gpu-workers.enabled: false` in `slurm-values.yaml` and `helm upgrade` so Slurm stops expecting a GPU partition.

## Spend warning

Before enabling a GPU profile, run the cost estimator:

```bash
python3 infrastructure/eks/cost-estimate.py \
  --cluster-config infrastructure/eks/cluster-config.yaml \
  --slurm-values helm-values/eks/slurm-values.yaml \
  --on-demand
```

The budget profile (1x `g5.xlarge` on-demand, 24h) lands around $30/day combined with the control plane. Spot drops that near $14/day. The production profile (`p4de.24xlarge`) will print a bright-red warning and exit non-zero because it blows the $50/day ceiling by ~16x. Do not override the budget flag without explicit user opt-in.

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Node joins but `nvidia.com/gpu` capacity is 0 | Device plugin evicted by lock taint before it could register | Run Step 6 (patch tolerations), then delete the device-plugin pod on the GPU node so it restarts. |
| `eksctl create nodegroup` fails with `InstanceLimitExceeded` | G/VT quota not yet raised | Re-check Step 1; an approved-but-cached quota can take up to 30 min to reflect in the API. |
| Spot request stuck `pending-fulfillment` | No spot capacity in the chosen AZ | Remove `spot: true` for on-demand, or add more AZs to the nodegroup with `availabilityZones:`. |
| Node goes `NotReady` mid-job | `kube-proxy` / `aws-node` evicted by lock taint | Step 6 patches these; re-run and confirm daemonsets list `sunk.coreweave.com/lock` in their tolerations. |
| `p4de.24xlarge` stuck `pending` | P-instance quota (`L-7212CCBC`) is 0 | Separate quota from G/VT - request increase the same way as Step 1 but with the P quota code. |
| Slurm node `INVALID_REG` with NVML autodetect | Container NVML path mismatch (rare on EKS AL2-GPU) | Use the explicit `gres.conf` patch from the GKE skill Step 4 as a fallback. |
| Cost estimator exits 1 after enabling GPU | Chosen profile exceeds `$50/day` budget | Expected for production profiles; override only with `--budget` raise and explicit user opt-in. |
| Enroot scratch fills `/` on GPU node | Enroot default tmpdir is on the root EBS | Uncomment the `/opt/dlami/nvme` hostPath mount in `slurm-values.yaml` (already templated). Confirm the path exists on your instance family first. |
