# Upgrading SUNK

Two things break on every Helm upgrade and require post-upgrade fixes.

## What Breaks

1. **gres.conf is overwritten.** The chart hardcodes `AutoDetect=nvml` which fails silently in SUNK containers. Manual GPU configuration is destroyed.
2. **Provider system tolerations may be reverted.** Provider control plane reconciliation may strip the lock taint toleration from system pods.

The post-upgrade script (`infrastructure/sunk-post-upgrade.sh`) automates the required fixups.

## Pre-Upgrade Checklist

```bash
# Verify health
kubectl get pods -n tenant-slurm
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname

# Backup
kubectl get configmap slurm-slurm-conf -n tenant-slurm -o yaml > gres-backup.yaml
helm get values sunk -n sunk > sunk-values-backup.yaml
helm get values slurm -n tenant-slurm > slurm-values-backup.yaml

# Drain jobs
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- scontrol update PartitionName=ALL State=DRAIN
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- squeue  # wait for empty
```

## Upgrade

```bash
helm repo update coreweave

# Operator
helm upgrade sunk coreweave/sunk -n sunk -f helm-values/sunk-values.yaml --timeout=5m

# Slurm chart (adjust --set-json as needed for your provider)
helm upgrade slurm coreweave/slurm -n tenant-slurm \
  -f helm-values/slurm-values.yaml \
  --timeout=5m

# Post-upgrade fixes (gres.conf, tolerations, pod restarts)
bash infrastructure/sunk-post-upgrade.sh

# Re-enable partitions
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- scontrol update PartitionName=ALL State=UP
```

## Post-Upgrade Verification

```bash
kubectl get pods -n tenant-slurm                                          # all Running
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo              # nodes idle
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname  # job works
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --gres=gpu:1 --mem=100 nvidia-smi  # GPU works
```

## Immutable Job Resources

If `helm upgrade` fails with an immutable Job error:

```bash
kubectl delete job slurm-secret-job -n tenant-slurm --ignore-not-found
# Then re-run helm upgrade
```

## Version Reference

```bash
helm search repo coreweave/sunk --versions | head -5
helm search repo coreweave/slurm --versions | head -5
```
