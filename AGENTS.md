# SUNK Anywhere

SUNK (Slurm on Kubernetes) is a CoreWeave product that runs a full Slurm workload manager on top of Kubernetes. This repository is a multi-cloud deployment kit: skills, Helm values, infrastructure manifests, and documentation for deploying SUNK on GKE, EKS, or generic/bare-metal Kubernetes clusters.

## Start Here

Before doing anything, ask the user:

1. **Which cloud provider?** GKE, EKS, or generic Kubernetes?
2. **Do you already have a cluster?** If yes, skip cluster creation and start from namespace/dependency setup.
3. **What is your cloud project or account ID?** Needed for provider CLI commands.
4. **Do you need GPU nodes?** Determines whether to run GPU node pool and monitoring skills.

Do NOT create clusters, install Helm charts, or provision infrastructure without the user's explicit confirmation. These actions create billable cloud resources. Always present the plan and wait for approval before executing.

## Select Your Provider

| Provider | Deploy Skill | Docs | Helm Values |
|----------|-------------|------|-------------|
| GKE | `skills/gke/deploy-sunk-on-gke` | `docs/gke/` | `helm-values/gke/` |
| EKS | `skills/eks/deploy-sunk-on-eks` | `docs/eks/` | `helm-values/eks/` |
| Generic / Bare-metal | `skills/generic/deploy-sunk-on-kubernetes` | `docs/generic/` | `helm-values/generic/` |

GKE and EKS are validated. Generic is in validation and may require provider-specific adaptation.

## Universal Skills

These skills work on any provider after SUNK is deployed.

| Skill | Purpose |
|-------|---------|
| `skills/universal/upgrade-sunk` | Upgrade SUNK via Helm with pre/post checks |
| `skills/universal/configure-sunk-user-auth` | Multi-user access via OpenLDAP |
| `skills/universal/setup-sunk-gpu-monitoring` | DCGM exporter, dashboards, GPU health checks |
| `skills/universal/connect-skypilot-to-sunk` | SkyPilot workload submission |
| `skills/universal/sunk-core-dump` | Diagnostic snapshot of all SUNK/Slurm cluster state for troubleshooting |

## Cloud-Specific Skills

| Provider | Skill | Purpose |
|----------|-------|---------|
| GKE | `skills/gke/add-gpu-nodes-to-gke` | Add GPU node pools to a GKE cluster |
| GKE | `skills/gke/patch-gke-system-tolerations` | Fix system pods evicted by SUNK lock taint |
| EKS | `skills/eks/add-gpu-nodes-to-eks` | Add a GPU managed nodegroup (A10G/L4 budget, A100/H100 opt-in) |
| EKS | `skills/eks/patch-eks-system-tolerations` | Fix system pods evicted by SUNK lock taint |

## Deployment Flow

Run skills in this order. Only step 1 is required; the rest are optional. Confirm with the user before each step.

1. **Deploy SUNK** (required) - Use the provider-specific deploy skill from the table above.
2. **Add GPU nodes** - Use the provider-specific GPU node skill (GKE: `add-gpu-nodes-to-gke`).
3. **Set up GPU monitoring** - `skills/universal/setup-sunk-gpu-monitoring`
4. **Configure user auth** - `skills/universal/configure-sunk-user-auth`
5. **Connect SkyPilot** - `skills/universal/connect-skypilot-to-sunk`

If the user already has a cluster, start at step 1 but skip the cluster creation section within the deploy skill.

After any Helm upgrade, run `skills/universal/upgrade-sunk` to fix gres.conf and system tolerations.

If `kubectl exec` or DNS stops working, run the provider-specific `patch-*-system-tolerations` skill (the lock taint evicted system pods).

## Directory Layout

| Directory | Contents |
|-----------|----------|
| `skills/` | AI agent skills organized by provider (`gke/`, `eks/`, `generic/`, `universal/`) |
| `docs/` | Human-readable documentation organized by provider, plus `universal/` for cross-cutting guides |
| `helm-values/` | Helm values files: `base/` for universal defaults, provider directories for overrides |
| `infrastructure/` | Kubernetes manifests, shell scripts, and observability configs by provider |
| `examples/` | Validation scripts for verifying a SUNK deployment |

## Key Concepts

- **Lock taint**: SUNK applies `sunk.coreweave.com/lock=true:NoExecute` to compute nodes. Every pod on shared nodes must tolerate it. See the provider-specific `patch-*-system-tolerations` skill.
- **`global.cks: false`**: Required Helm value for non-CoreWeave deployments. Pulls images from public GHCR instead of CoreWeave's private registry.
- **`global.nodeSelector.affinity=null`**: Clears CoreWeave-specific node affinity from all Slurm pods.
- **Cluster type restrictions**: GKE Standard only (not Autopilot), EKS standard (not Fargate). SUNK needs privileged pods, hostNetwork, and custom DaemonSets.

## When Things Go Wrong

Consult `docs/universal/troubleshooting.md` for common issues that apply to all providers. Provider-specific troubleshooting is in `docs/<provider>/`.

The most frequent problems:
- Pods stuck Pending: check node affinity and lock taint tolerations
- `kubectl exec` fails: run the provider-specific `patch-*-system-tolerations` skill
- DefMemPerCPU errors: see the sizing formula in `docs/universal/helm-values-reference.md`
- Syncer/scheduler show CreateContainerConfigError: normal for 2-3 minutes after install (JWT generation)

For comprehensive diagnostics, run `skills/universal/sunk-core-dump` to capture a full cluster state snapshot.

## Validation

After deployment, run the scripts in `examples/` to verify:
- Basic Slurm operations (srun, sbatch, multi-node)
- GPU workloads (CUDA stress test)
- Pod scheduler (Kubernetes pods scheduled via Slurm)
- Metrics pipeline
- GPU health checks
