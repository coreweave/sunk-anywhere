# EKS storage — shared `/home` for SUNK

Two paths provide a `ReadWriteMany` `slurm-home` PVC in the `slurm` namespace.
Pick one. Both converge on the same PVC name, so `slurm-values.yaml` stays identical.

Per [docs/eks/conventions.md](../../../docs/eks/conventions.md).

## Path 1 — managed EFS (production)

- Cost: roughly $30/mo for 100 GiB in bursting mode (storage only; throughput is free below the burst credit budget).
- Durable across AZs, maintained by AWS.

```bash
./setup-efs.sh --cluster sunk-eks --region us-east-1 --profile your-aws-profile
# Renders and applies efs-storageclass.yaml.template automatically.
sed "s/__EFS_FS_ID__/$(cat /tmp/sunk-efs-id)/g" efs-pv-home.yaml.template | kubectl apply -f -
```

`setup-efs.sh` is idempotent: re-running reuses the filesystem (via creation-token),
security group (by name+VPC), and mount targets (by subnet).

## Path 2 — NFS-server pod (budget / dev)

- Cost: $0 beyond the backing `gp3` EBS volume (~$8/mo for 100 GiB).
- Single point of failure (one pod on `cpu-control`). Do not use for prod.

```bash
kubectl apply -f nfs-server-pod-eks.yaml
```

This is the default for the sub-$50/day budget profile.

## How helm references it

Both paths expose a PVC named `slurm-home` in the `slurm` namespace. In `slurm-values.yaml`:

```yaml
login:
  home:
    existingClaim: slurm-home
compute:
  home:
    existingClaim: slurm-home
```

## Switching paths

Drain the existing PVC first. The PV is `Retain`, so the data remains on the
backing EBS (Path 2) or EFS (Path 1) until you delete the PV explicitly.
