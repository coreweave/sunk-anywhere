# SUNK-on-EKS Destroy Scripts

Symmetric teardown for the `infrastructure/eks/*` bootstrap. Each script
undoes one bootstrap step; `destroy-all.sh` runs them in reverse order.

## Usage

```bash
# Preview (no changes):
./destroy-all.sh --cluster sunk-eks --region us-east-1 --profile your-aws-profile --dry-run

# Interactive (prompts once):
./destroy-all.sh --cluster sunk-eks --region us-east-1 --profile your-aws-profile

# Non-interactive (CI):
./destroy-all.sh --cluster sunk-eks --region us-east-1 --profile your-aws-profile --yes
```

## Order (reverse of bootstrap)

1. `delete-slurm.sh` — `helm uninstall slurm`, `helm uninstall sunk`, drain PVCs, delete namespace
2. `delete-observability.sh` — `kube-prometheus-stack`, DCGM exporter, syncer PodMonitor, `monitoring` ns
3. `delete-storage.sh` — slurm-home PV/PVCs, NFS-server pod, EFS filesystem + mount targets, EFS security group
4. `delete-controllers.sh` — MOCO, cert-manager, ALB controller, EFS CSI, `aws-ebs-csi-driver` add-on
5. `delete-irsa.sh` — 3 IRSA service accounts + 2 customer-managed IAM policies
6. `delete-cluster.sh` — `eksctl delete cluster --force` (control plane, nodegroups, VPC, NAT gateway)

Each script is idempotent: missing resources are not errors. Run any one
individually if a partial teardown is needed.

## Blast-radius filter

AWS resources are selected by the tag `ManagedBy=sunk-anywhere` (see
`docs/eks/conventions.md`). After all steps run, `destroy-all.sh` calls
`resourcegroupstaggingapi get-resources` and prints a warning if any
tagged resources remain.

## What this does NOT delete

- **S3 buckets** — never created by bootstrap; state is on EBS + EFS.
- **CloudWatch log groups** — retained for post-mortem after cluster delete.
- **NAT Gateway** — owned by the cluster VPC, torn down by `eksctl delete cluster`.
- **Non-tagged resources** — anything lacking `ManagedBy=sunk-anywhere` is ignored.

## Verification

```bash
shellcheck infrastructure/eks/destroy/*.sh
./destroy-all.sh --dry-run    # plan without executing
```
