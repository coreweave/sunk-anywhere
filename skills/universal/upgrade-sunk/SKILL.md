---
name: upgrade-sunk
description: >
  Upgrade SUNK (Slurm on Kubernetes) via Helm on any provider. Covers pre-upgrade
  backup, helm upgrade execution, and the required post-upgrade steps: gres.conf
  re-patch, system toleration re-patch, GPU pod restart, and Slurm node resume.
  Use when asked to "upgrade SUNK", "helm upgrade slurm", "update SUNK chart version",
  "upgrade Slurm", or "run post-upgrade steps after helm upgrade".
  The post-upgrade script automates steps 3-6 into a single command.
---

# Upgrade SUNK

Upgrade a running SUNK deployment via Helm. This skill covers the full upgrade lifecycle: pre-upgrade checks, the helm upgrade itself, and the post-upgrade fixups required because the Helm chart overwrites critical ConfigMaps.

## Why This Skill Exists

Two things break on every Helm upgrade of the Slurm chart:

1. **gres.conf is overwritten.** The chart hardcodes `gres.conf: AutoDetect=nvml` with no override mechanism. SUNK container images lack compile-time NVML support, so autodetection fails silently. Any manual GPU configuration is destroyed.

2. **System tolerations may be reverted.** Cloud providers periodically reconcile managed Deployment specs. A cluster upgrade or control plane update can strip the `sunk.coreweave.com/lock` toleration from system pods, causing critical components to be evicted. See your provider's toleration patching skill for details.

## Pre-Upgrade Checklist

Run these checks before upgrading. Upgrading a broken cluster makes diagnosis harder.

### 1. Verify current cluster health

```bash
# All pods healthy
kubectl get pods -n tenant-slurm
kubectl get pods -n sunk

# Slurm nodes idle
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo

# Quick job test
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname
```

If any nodes are in `down` or `drain` state, fix them before upgrading. Upgrading will not fix node registration issues.

### 2. Backup current gres.conf

```bash
kubectl get configmap slurm-slurm-conf -n tenant-slurm -o yaml > gres-backup.yaml
```

This backup lets you restore the exact gres.conf if the post-upgrade script's auto-detection picks wrong values.

### 3. Backup current Helm values

```bash
helm get values slurm -n tenant-slurm > slurm-values-backup.yaml
```

### 4. Check what will change

```bash
# Diff the new chart version against current
helm diff upgrade slurm coreweave/slurm \
  -f helm-values/<provider>/slurm-values.yaml \
  --set-json 'global.nodeSelector.affinity=null' \
  -n tenant-slurm
```

If `helm diff` is not installed: `helm plugin install https://github.com/databus23/helm-diff`

Review the diff for unexpected changes, especially to ConfigMaps and resource limits. Replace `<provider>` with your provider directory (e.g., `gke`, `eks`).

### 5. Drain running jobs (if applicable)

```bash
# Set all partitions to drain (finish running jobs, reject new ones)
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  scontrol update PartitionName=ALL State=DRAIN Reason="helm upgrade"

# Wait for running jobs to complete
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- squeue
```

For dev/test clusters with no running jobs, skip this step.

## Upgrade Procedure

### Step 1: Update Helm repos

```bash
helm repo update coreweave
```

### Step 2: Run helm upgrade

For the SUNK operator chart (if upgrading the operator):

```bash
helm upgrade sunk coreweave/sunk \
  -f helm-values/<provider>/sunk-values.yaml \
  -n sunk
```

For the Slurm chart:

```bash
helm upgrade slurm coreweave/slurm \
  -f helm-values/<provider>/slurm-values.yaml \
  --set-json 'global.nodeSelector.affinity=null' \
  -n tenant-slurm
```

The `--set-json 'global.nodeSelector.affinity=null'` is required to clear CoreWeave-specific node affinity baked into the chart defaults. Replace `<provider>` with your provider directory.

### Step 3: Run the post-upgrade script

Run the post-upgrade script from your provider's infrastructure directory:

```bash
bash infrastructure/<provider>/sunk-post-upgrade.sh
```

This single script handles:
- Re-patching gres.conf with per-node GPU entries
- Re-patching system pod tolerations (provider-specific)
- Rolling-restarting GPU worker pods
- Resuming GPU nodes in Slurm
- Running verification checks

For CPU-only clusters (no GPU workers):

```bash
bash infrastructure/<provider>/sunk-post-upgrade.sh --skip-gres
```

To skip toleration patching (e.g., if you just ran it separately):

```bash
bash infrastructure/<provider>/sunk-post-upgrade.sh --skip-tolerations
```

### Step 4: Restore partitions

If you drained partitions in pre-upgrade step 5:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  scontrol update PartitionName=ALL State=UP
```

## Post-Upgrade Verification

The post-upgrade script runs basic checks automatically. For thorough verification:

```bash
# 1. All pods healthy (no CrashLoopBackOff, Pending, or Error)
kubectl get pods -n tenant-slurm
kubectl get pods -n sunk

# 2. All Slurm nodes idle (not down, drain, or INVALID_REG)
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo

# 3. CPU job works
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname

# 4. GPU job works (if GPU workers are configured)
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  srun --partition=gpu-workers --gres=gpu:1 --mem=100 nvidia-smi

# 5. Shared filesystem works
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  bash -c 'echo upgrade-test > /home/v.txt && srun --mem=100 cat /home/v.txt && rm /home/v.txt'

# 6. kubectl exec works (system agents healthy)
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- echo "exec works"

# 7. DNS works inside pods
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- nslookup kubernetes.default
```

## SUNK 6.x to 7.x Migration

Major version upgrades require additional steps. The 6.x to 7.x upgrade involves a MySQL to MOCO migration.

### Migration flags

Set these three flags together during migration:

```yaml
moco:
  enabled: true
  migration:
    enabled: true
mysql:
  enabled: true    # Keep true during migration
```

After migration completes (verify MOCO MySQL is healthy and data is migrated):

```yaml
moco:
  enabled: true
  migration:
    enabled: false
mysql:
  enabled: false
```

Then sync with Prune to clean up the old MySQL resources.

### Version to chart version mapping

| SUNK Version | Chart Version |
|-------------|--------------|
| 6.6.0 / 6.9.1 | 1.1155.0 |
| 7.0.1 / 7.1.0 | 1.1888.0 |
| 7.2.0 | 2.11.0 |

## What the Post-Upgrade Script Does

For reference, here is what the post-upgrade script automates.

### Step A: Re-patch gres.conf

Discovers GPU worker pods, determines their GPU type and count, and patches the `slurm-slurm-conf` ConfigMap with per-node GRES entries. The `NodeName` qualifier is critical because without it, the `File=/dev/nvidia0` line applies to ALL nodes, crashing CPU workers.

### Step B: Re-patch system tolerations

Delegates to your provider's toleration patching script (e.g., `infrastructure/gke/patch-gke-tolerations.sh`), which adds the `sunk.coreweave.com/lock` NoExecute toleration to provider-managed system pods.

### Step C: Restart GPU worker pods

Deletes GPU worker pods so they restart with the updated gres.conf. The SUNK operator recreates them automatically.

### Step D: Resume nodes in Slurm

After pods restart, their Slurm nodes may be in `down` state. For each GPU
worker, the script polls `scontrol show node <pod>` until slurmd reports
`Gres=gpu:<type>:<N>` with a non-zero count, then runs
`scontrol update NodeName=<pod> State=RESUME`. This avoids the
"gres/gpu count reported lower than configured" race where the node
re-drains because we resumed before slurmd finished re-reading gres.conf.
If slurmd does not report GRES within the per-pod timeout (120s on the GKE
script), the resume is skipped and a warning is printed so the operator can
investigate.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| GPU nodes stuck in `INVALID_REG` after upgrade | gres.conf not re-patched, or patch has wrong GPU type | Re-run the post-upgrade script. Check gres-backup.yaml for correct values. |
| `kubectl exec` fails with "No agent available" | System agent evicted after provider reconciliation | Re-run your provider's toleration patch script from `infrastructure/<provider>/` |
| GPU pod stuck `Pending` after restart | GPU node pool scaled down or quota hit | Check your provider's node pool or node group status |
| `scontrol update State=RESUME` fails | Node not yet registered after pod restart | Wait 30s and retry. Check slurmd logs: `kubectl logs -n tenant-slurm <gpu-pod> -c slurmd` |
| Helm upgrade fails with CRD errors | Monitoring CRDs removed or changed | Verify `podMonitor.enabled: false` and `vmPodScrape.enabled: false` on all components |
| Post-upgrade script detects wrong GPU type | Label `sunk.coreweave.com/gres-gpu` missing, fallback heuristic wrong | Set `compute.nodes.<group>.gresGpu` (e.g. `"l4:1"`) in your provider values so the chart adds the correct label, or edit gres.conf manually using values from gres-backup.yaml and restart GPU pods |
| GPU node re-drains immediately after resume with `gres/gpu count reported lower than configured` | Resumed before slurmd finished re-reading gres.conf | The current GKE post-upgrade script waits for `Gres=gpu:<type>:N` before resuming. If you resumed manually, wait until `scontrol show node <pod>` shows the expected non-zero Gres line, then re-run `scontrol update NodeName=<pod> State=RESUME` |
| Syncer/scheduler `CreateContainerConfigError` | JWT secrets being regenerated (normal, 2-3 min) | Wait for `slurm-secret-job` to complete |
| NFS mount broken after upgrade | NFS server pod was evicted and restarted on a different node | Verify NFS server is Running: `kubectl get pods -n tenant-slurm -l app=nfs-server` |
| MOCO MySQL unhealthy after upgrade | cert-manager evicted, certs expired | Run your provider's toleration patch script, then restart cert-manager |
| Partitions still in DRAIN after upgrade | Forgot to restore partitions | `scontrol update PartitionName=ALL State=UP` |

## Quick Reference

```bash
# Full upgrade workflow (copy-paste, replace <provider>)
kubectl get configmap slurm-slurm-conf -n tenant-slurm -o yaml > gres-backup.yaml
helm repo update coreweave
helm upgrade slurm coreweave/slurm \
  -f helm-values/<provider>/slurm-values.yaml \
  --set-json 'global.nodeSelector.affinity=null' \
  -n tenant-slurm
bash infrastructure/<provider>/sunk-post-upgrade.sh

# CPU-only cluster
helm upgrade slurm coreweave/slurm \
  -f helm-values/<provider>/slurm-values.yaml \
  --set-json 'global.nodeSelector.affinity=null' \
  -n tenant-slurm
bash infrastructure/<provider>/sunk-post-upgrade.sh --skip-gres
```
