# EKS Conventions

Naming contract every EKS script, skill, and values file in this repo references. Lock this first to prevent drift between values, skills, and scripts.

## Node label keys

Use the EKS-native key `eks.amazonaws.com/nodegroup` as the primary selector. It is applied automatically by EKS when nodes join, so no manual labeling is required.

| Nodegroup | Value | Purpose |
|-----------|-------|---------|
| `cpu-control` | `cpu-control` | Slurm controller, MOCO, login, syncer, scheduler, operator, MySQL |
| `cpu-workers` | `cpu-workers` | CPU Slurm compute nodes (scale-to-zero) |
| `gpu-workers` | `gpu-workers` | GPU Slurm compute nodes (scale-to-zero) |

Secondary label on GPU nodes: EKS AMI taint `nvidia.com/gpu=present:NoSchedule` (auto-applied by GPU AMI). Do not manually add.

## Nodegroup sizing (budget profile)

Default cluster fits under $50/day and supports scale-to-zero for compute.

| Nodegroup | Instance | Min | Desired | Max | Spot? |
|-----------|----------|-----|---------|-----|-------|
| `cpu-control` | `m5.large` (2 vCPU / 8 GiB) | 2 | 2 | 2 | no |
| `cpu-workers` | `m5.large` | 0 | 0 | 2 | yes |
| `gpu-workers` | `g5.xlarge` (A10G, $1.006/hr) | 0 | 0 | 1 | yes |

Fallback GPU: `g6.xlarge` (L4, $0.805/hr) if `g5` quota is unavailable.
Prod GPU (opt-in, blows budget): `p4de.24xlarge` (8x A100), `p5.48xlarge` (8x H100). Document clearly; never default.

## StorageClasses

| Name | Backing | Mode | Purpose |
|------|---------|------|---------|
| `gp3` | EBS gp3 | ReadWriteOnce | Default for all PVCs (MySQL state, controller state, login SSH keys) |
| `efs-sc` | EFS | ReadWriteMany | Shared `/home` when using managed EFS |
| `cheap-nfs` | NFS-server-pod on gp3 | ReadWriteMany | Budget-profile shared `/home` |

EKS default StorageClass is `gp2`. The cluster bootstrap (`create-cluster.sh`) patches `gp3` to `storageclass.kubernetes.io/is-default-class: "true"` and marks `gp2` non-default.

## Namespace layout

| Namespace | Contents |
|-----------|----------|
| `sunk` | SUNK operator (coreweave/sunk chart) |
| `tenant-slurm` | Slurm chart (controller, MOCO MySQL cluster, login, compute, syncer, scheduler, NFS server pod). Name is load-bearing: `helm-values/base/slurm-values.yaml` hardcodes `nfs-server.tenant-slurm.svc.cluster.local`. |
| `monitoring` | kube-prometheus-stack (Prometheus, Grafana, Alertmanager), PodMonitors, DCGM ServiceMonitor |
| `cert-manager` | cert-manager (CRDs, webhook, cainjector) |
| `moco-system` | MOCO operator |
| `kube-system` | AWS-managed (CNI, kube-proxy, EBS/EFS CSI nodes), AWS Load Balancer Controller |

## Lock taint

`sunk.coreweave.com/lock=true:NoExecute` is applied to compute nodes by the SUNK syncer during a Slurm job. Every pod that can land on a compute node must tolerate it. See `skills/eks/patch-eks-system-tolerations/`.

## AWS tags (all resources)

Apply to every AWS resource the bootstrap creates:

```yaml
tags:
  Environment: dev        # or prod
  Service: sunk
  ManagedBy: sunk-anywhere
  Owner: auto-cleanup     # signals destroy-all.sh may remove this
```

Destroy scripts use `ManagedBy=sunk-anywhere` as the blast-radius filter.

## Budget constants (sub-$50/day profile)

| Component | $/day | Notes |
|-----------|-------|-------|
| 2x m5.large control plane | $4.61 | on-demand |
| EBS gp3 (3x 20 GiB controller + 3x 50 GiB MySQL) | $0.50 | $0.08/GB-mo |
| 1x NLB (login service) | $0.54 | $0.0225/hr + LCU |
| NAT Gateway (1 AZ) | $1.08 | fixed + data |
| 0-1x g5.xlarge (scale-to-zero) | $0 to $24 | spot preferred, $0.30-0.35/hr spot vs $1.006 on-demand |
| Total (idle) | ~$6.70 | |
| Total (1 GPU, 24h on-demand) | ~$30 | |
| Total (1 GPU, 24h spot) | ~$14 | |

Cost estimator (`infrastructure/eks/cost-estimate.py`) enforces: daily total < $50 with current nodegroup config.

## Region

Default region: `us-east-1` (cheapest, broadest instance availability). Bootstrap accepts `--region` override. AZs enumerated dynamically at cluster-create time (script picks 3 from available).

## Versions

| Component | Version |
|-----------|---------|
| Kubernetes / EKS | 1.30 |
| EKS AMI (CPU) | AmazonLinux2-EKS-1.30 |
| EKS AMI (GPU) | AmazonLinux2-EKS-1.30-GPU |
| SUNK chart | 7.3.0 |
| Slurm image | `v25.05.3-coreweave.5-ubuntu22.04` |
| cert-manager | v1.15+ |
| MOCO | 0.22+ |
| aws-load-balancer-controller | 2.8+ |
| kube-prometheus-stack | 65+ |

## Referencing this doc

Every downstream EKS doc, skill, script, or values file must cite this file at the top of its first section. If a change needs a convention not listed here, propose the addition as a PR against this doc first (separate commit), then use it.
