# SUNK Anywhere

Deploy [SUNK](https://docs.coreweave.com/products/sunk) (Slurm on Kubernetes) on any Kubernetes cluster: GKE, EKS, or bare-metal.

## Quick Start

```bash
git clone https://github.com/coreweave/sunk-anywhere.git
cd sunk-anywhere
```

Launch your AI coding agent (Claude Code, Gemini, Cursor, etc.) and say:

> "Deploy SUNK on GKE"

or EKS, Kubernetes. The agent reads the repo context, picks the right provider skill, and walks you through the entire setup. It will prompt you for your cloud project/account ID and handle the rest.

## What Gets Deployed

The "Deploy SUNK on \<provider\>" flow is **opt-out by default**: every
component below ships unless you explicitly skip it. Skip flags are listed in
each provider's deploy skill (e.g. `--skip-monitoring`, `--skip-gpu-monitoring`,
`--skip-user-provisioning`).

### Default (deployed unless you opt out)

| Component                  | Skip flag                  | What it gives you                                                       |
|----------------------------|----------------------------|-------------------------------------------------------------------------|
| SUNK operator + Slurm      | n/a (always required)      | controller, accounting, login, syncer, pod scheduler                    |
| cert-manager + MOCO MySQL  | n/a (required dependency)  | TLS for webhooks, slurmdbd backing store                                |
| In-cluster NFS             | n/a (required dependency)  | shared `/home` across login + compute pods                              |
| GKE-system tolerations     | n/a (required on GKE)      | keeps konnectivity-agent, kube-dns, etc. alive under the SUNK lock taint |
| Cloud Monitoring dashboards | `--skip-monitoring`       | "SUNK: Cluster Overview" + "SUNK: Job Metrics" in your cloud console    |
| DCGM exporter + scrapes    | `--skip-gpu-monitoring`    | GPU util, temp, power, FB used, XID errors flowing into the dashboards  |
| Slurm syncer scrape config | `--skip-gpu-monitoring`    | `slurm_node_state`, `slurm_jobs_running`, scheduler counters            |
| Default local user + key   | `--skip-user-provisioning` | one POSIX user on the login pod with your SSH key + Slurm association   |

### Optional (opt-in)

| Component                  | How to enable                                     | What it gives you                                |
|----------------------------|---------------------------------------------------|--------------------------------------------------|
| GPU node pool              | `skills/<provider>/add-gpu-nodes-to-<provider>`   | accelerated partition + `gres=gpu:*` scheduling  |
| Multi-user auth (LDAP)     | `skills/universal/configure-sunk-authentik-sssd`  | authentik as IdP, SSSD on compute pods           |
| SkyPilot integration       | `skills/universal/connect-skypilot-to-sunk`       | k8s-native job submission via SkyPilot           |
| GPU health checks          | `examples/06-validate-gpu-health.sh`              | DCGM diagnostic sweep                            |

## Supported Providers

| Provider | Status | Notes |
|----------|--------|-------|
| GKE (Standard) | Validated | Full deployment and monitoring tested end-to-end |
| EKS | Validated | Deployment verified end-to-end on a live EKS cluster |
| Generic / Bare-metal | Validation in progress | For any other Kubernetes: on-prem, self-managed, or another managed cloud; validation in progress |

Autopilot (GKE) and Fargate (EKS) are not supported. SUNK requires privileged pods, hostNetwork, and custom DaemonSets.

## Prerequisites

- An AI coding agent that reads project context files, or willingness to follow docs manually
- A Kubernetes cluster (or cloud CLI access to create one)
- `kubectl` and `helm` installed
- Provider CLI: `gcloud` (GKE), `aws`/`eksctl` (EKS)
- CPU quota for node pools (8+ vCPUs recommended)
- GPU quota if deploying GPU nodes
- **Access to the CoreWeave SUNK Helm charts** (see below)

### Helm chart access

The SUNK and Slurm Helm charts are CoreWeave proprietary software and require a
separate license. Reach out to CoreWeave at
<sunk@coreweave.com> to obtain access instructions for the chart repository.
You will receive the repository URL to use wherever these docs show the
`<COREWEAVE_HELM_REPO_URL>` placeholder.

### What "a Kubernetes cluster" means here

`sunk-anywhere` targets **managed Kubernetes distributions**: EKS, GKE,
and CoreWeave Cloud. It assumes the cluster already provides:

- `kube-proxy` and a CNI plugin (EKS: VPC CNI; GKE: GKE Dataplane)
- A default StorageClass supporting `ReadWriteOnce` (gp3, standard-rwo)
- Cloud integration: LoadBalancer controller, IAM/Workload Identity, NVIDIA drivers on GPU AMIs/images, NVIDIA device plugin
- Node-level features: privileged containers, hostPath, hostNetwork allowed by any admission controllers

Any Kubernetes without its own track here (kubeadm, k3s, Rancher, bare-metal,
or another managed cloud) is covered by the `generic` track, which assumes you
provide the prerequisites above. That track is in validation.

### Getting a user onto the cluster

Once SUNK is deployed, you still need a Linux user + SSH key on the login
pod before you can `ssh` or `sbatch`. Three paths are available; the
default is the simple single-user helper. See
[`docs/universal/ssh-access.md`](docs/universal/ssh-access.md) ("Pick your
path") for the decision table.

## Documentation

| Guide | Description |
|-------|-------------|
| [Architecture](docs/universal/architecture.md) | SUNK concepts, component map, provider adaptations |
| [Helm Values Reference](docs/universal/helm-values-reference.md) | Annotated reference for all values files |
| [Troubleshooting](docs/universal/troubleshooting.md) | Common issues and fixes across all providers |
| [GKE Deployment Guide](docs/gke/) | GKE-specific deployment and adaptations |
| [EKS Deployment Guide](docs/eks/) | EKS-specific deployment and adaptations |
| [Generic Deployment Guide](docs/generic/) | Bare-metal and on-prem deployment |
| [SSH Access & User Provisioning Paths](docs/universal/ssh-access.md) | Decision table: simple default, authentik+sssd opt-in, CW-IAM note |
| [User Provisioning (nsscache/LDAP reference)](docs/universal/user-provisioning.md) | Legacy reference — nsscache pipeline for CW IAM SCIM integration |
| [Upgrading](docs/universal/upgrading.md) | Upgrade procedures and post-upgrade checklist |
| [Monitoring Guide](docs/universal/monitoring-guide.md) | GPU metrics, Slurm metrics, dashboards, health checks |

## Examples

Validation scripts in `examples/`:

| Script | What it validates |
|--------|-------------------|
| `01-basic-srun.sh` | Single and multi-node srun |
| `02-sbatch-cpu-job.sh` | Batch job submission |
| `03-gpu-stress-test.sh` | GPU compute via CUDA driver API |
| `04-validate-pod-scheduler.yaml` | SUNK pod scheduler (K8s pods via Slurm) |
| `05-validate-metrics.sh` | Metrics flowing to monitoring backend |
| `06-validate-gpu-health.sh` | GPU health checks |

## Validation roadmap

GKE and EKS are validated. Generic provider support is in validation. Work in progress:

- Validating bare-metal deployments end-to-end
- Filling in provider-specific skills with verified procedures
- Adding provider-specific infrastructure patches
- Expanding documentation for non-GKE providers

## License

This repository & contents therein are licensed under the [Apache License 2.0](LICENSE).

See [OSS_NOTICE.md](OSS_NOTICE.md) for a non-binding summary of license
breakdowns between relevant parts of the SUNK ecosystem.
