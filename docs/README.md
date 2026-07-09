# SUNK Documentation

SUNK (Slurm on Kubernetes) runs each Slurm "node" as a Kubernetes pod, turning a Kubernetes cluster into a Slurm cluster. This repo supports multiple cloud providers and bare-metal deployments.

> **Prerequisite — Helm chart access.** The SUNK and Slurm Helm charts are
> licensed. Before following any deployment guide, reach out to CoreWeave at
> <sunk@coreweave.com> for access instructions. You will receive the repository
> URL to use wherever these docs show the `<COREWEAVE_HELM_REPO_URL>` placeholder.

## Pick Your Provider

| Provider | Deployment Guide | Adaptations | Troubleshooting |
|----------|-----------------|-------------|-----------------|
| **GKE** (validated) | [gke/deployment-guide.md](gke/deployment-guide.md) | [gke/gke-adaptations.md](gke/gke-adaptations.md) | [gke/gke-troubleshooting.md](gke/gke-troubleshooting.md) |
| **EKS** (validated) | [eks/deployment-guide.md](eks/deployment-guide.md) | [eks/eks-adaptations.md](eks/eks-adaptations.md) | [eks/troubleshooting.md](eks/troubleshooting.md) |
| **Generic / Bare-Metal** (validation in progress) | [generic/deployment-guide.md](generic/deployment-guide.md) | [generic/generic-adaptations.md](generic/generic-adaptations.md) | -- |

## Universal Docs

These apply to all providers:

| Document | Description |
|----------|-------------|
| [universal/architecture.md](universal/architecture.md) | SUNK component map, lock taint concept, data flow, namespace layout, storage |
| [universal/helm-values-reference.md](universal/helm-values-reference.md) | Annotated Helm values for all three charts |
| [universal/troubleshooting.md](universal/troubleshooting.md) | Generic Slurm-level troubleshooting (not cloud-specific) |
| [universal/monitoring-guide.md](universal/monitoring-guide.md) | DCGM, syncer metrics, dashboard concepts |
| [universal/ssh-access.md](universal/ssh-access.md) | SSH access & user-provisioning path decision table (simple, authentik+sssd, CW IAM note) |
| [universal/user-provisioning.md](universal/user-provisioning.md) | Legacy reference: nsscache/LDAP pipeline (for CW IAM SCIM) |
| [universal/upgrading.md](universal/upgrading.md) | Upgrade procedure |
