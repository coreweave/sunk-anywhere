# SUNK on EKS — Documentation Index

Deploy SUNK (Slurm on Kubernetes) on Amazon EKS with a sub-$50/day budget profile. All docs here share a single naming contract; start there and use the others as needed.

| Doc | What it covers |
|-----|----------------|
| [conventions.md](conventions.md) | Naming contract: node labels, nodegroup names, StorageClasses, namespaces, lock taint, AWS tags, budget constants, version pins |
| [deployment-guide.md](deployment-guide.md) | Full 11-step walkthrough: quotas, cluster, IRSA, controllers, storage, SUNK + Slurm, GPU, observability, tolerations, verification, cost check, teardown |
| [eks-adaptations.md](eks-adaptations.md) | Diff table: what changes vs the GKE reference deployment and why |
| [../universal/security-model.md](../universal/security-model.md) | Universal SUNK security model: per-cloud posture matrix (EKS privileged-default; GKE/generic capabilities-only target), threat model, the four caps on EKS, AppArmor/seccomp/cgroup rationale, hardening knobs, customer-DIY (Ubuntu 24.04 / k3s) section. Required reading before compliance review |
| [cost-table.md](cost-table.md) | Per-component spend, budget vs production profiles, spot vs on-demand, `cost-estimate.py` usage, optional AWS Budget alerts |
| [troubleshooting.md](troubleshooting.md) | EKS-specific symptom/cause/fix table and diagnostic command cheat sheet |

**Status:** Validated. End-to-end deployment verified on a live EKS cluster.

## Related

- [../universal/architecture.md](../universal/architecture.md) — SUNK component model
- [../universal/helm-values-reference.md](../universal/helm-values-reference.md) — annotated values
- [../universal/troubleshooting.md](../universal/troubleshooting.md) — cloud-agnostic Slurm issues
- `skills/eks/deploy-sunk-on-eks/` — agent orchestration of this flow
- `skills/eks/add-gpu-nodes-to-eks/` — opt-in GPU expansion
- `skills/eks/patch-eks-system-tolerations/` — lock-taint fixup
