# Troubleshooting

Quick reference for diagnosing and fixing common SUNK issues. Organized by symptom so you can search for what you see.

For provider-specific troubleshooting (GKE system pod eviction, provider-specific GPU paths, etc.), see your provider's troubleshooting doc.

---

## Quick Diagnosis Checklist

Run these commands first to narrow down the problem:

```bash
# 1. Are all pods healthy?
kubectl get pods -n tenant-slurm
kubectl get pods -n sunk

# 2. Are Slurm nodes registered and idle?
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo

# 3. Can a basic job run?
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname

# 4. Does kubectl exec work? (tests connectivity agent)
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- echo "exec works"

# 5. Does DNS work inside pods?
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- nslookup kubernetes.default

# 6. Is the NFS server healthy?
kubectl get pods -n tenant-slurm -l app=nfs-server

# 7. GPU nodes: is nvidia-smi working?
kubectl exec -n tenant-slurm <gpu-pod> -c slurmd -- nvidia-smi
```

If step 4 fails, the provider's connectivity agent was likely evicted by the lock taint. See your provider's troubleshooting doc. If step 2 shows `INVALID_REG`, go to [GPU nodes stuck in INVALID_REG](#gpu-nodes-stuck-in-invalid_reg). If step 3 fails with a memory error, see [DefMemPerCPU issues](#defmempercpu-formula-and-common-errors).

---

## Deployment Issues

### Pods stuck in Pending with FailedScheduling

**Symptom:** SUNK operator, syncer, or scheduler pods stay `Pending`. Events show affinity/nodeSelector failures.

**Cause:** The Helm chart ships with CoreWeave-specific node affinity rules that don't match your cluster's node labels.

**Fix:** Override affinity in your Helm install/upgrade. Set `affinity: null` on operator, scheduler, and syncer in your values files, or use `--set-json` to clear it.

### Syncer/scheduler show CreateContainerConfigError

**Symptom:** Syncer or scheduler pods show `CreateContainerConfigError` immediately after install.

**Cause:** The `slurm-secret-job` hasn't completed yet. It generates JWT secrets that syncer and scheduler need.

**Fix:** Wait 2-3 minutes. Watch the job:

```bash
kubectl get jobs -n tenant-slurm | grep secret
```

Once the job reaches `Completed`, the pods will start. If they don't recover after 3 minutes, restart the affected pods.

### Service slurm-login is invalid: externalTrafficPolicy

**Symptom:** Helm install fails with a validation error about `externalTrafficPolicy` on the login service.

**Cause:** The chart defaults to `externalTrafficPolicy: Local`, which is invalid for `ClusterIP` service type.

**Fix:** Set in your slurm-values.yaml:

```yaml
login:
  service:
    externalTrafficPolicy: ""
```

### PVCs stuck in Pending

**Symptom:** Controller state volume or MOCO MySQL PVCs stay `Pending`.

**Cause:** No `storageClassName` specified, or the specified class doesn't exist on your cluster.

**Fix:** Add `storageClassName` to your values with a valid StorageClass for your provider:

```yaml
controller:
  stateVolume:
    storageClassName: <your-storage-class>

moco:
  mysqlCluster:
    persistence:
      storageClassName: <your-storage-class>
```

Verify available storage classes: `kubectl get storageclass`.

### Controller pod pending: "slurm-slurmctld-state is being deleted" / "not found"

**Symptom:** `kubectl describe pod slurm-controller-...` shows:

```
Warning  FailedScheduling  ...  persistentvolumeclaim slurm-slurmctld-state is being deleted
Warning  FailedScheduling  ...  persistentvolumeclaim slurm-slurmctld-state not found
```

**Cause:** A prior `helm uninstall` left the PVC stuck in `Terminating`
with a finalizer that never completed (usually because the storage class
or CSI driver is no longer reconciling). The new install then fails
because the name already exists in `Terminating` state.

**Fix:** Patch the finalizers off the stuck PVC, then re-run
`helm install`:

```bash
kubectl get pvc -n tenant-slurm | grep Terminating
# NAME                        STATUS
# slurm-slurmctld-state       Terminating
# nfs-backing-pvc             Terminating    # another common one

for p in $(kubectl get pvc -n tenant-slurm -o name); do
  kubectl patch "$p" -n tenant-slurm -p '{"metadata":{"finalizers":null}}' --type=merge
done
```

If a PV is also stuck `Released` with a stale `claimRef`, re-bind it by
removing the claimRef:

```bash
kubectl patch pv <pv-name> --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
```

The destroy scripts under `infrastructure/<provider>/destroy/` try to
avoid this state, but an interrupted uninstall can still land here.

### Helm install fails with MySQL/MOCO errors

**Symptom:** `helm install` fails referencing MySQL CRDs or cert-manager resources.

**Cause:** MOCO requires cert-manager to be installed first. cert-manager issues the TLS certificates MOCO uses.

**Fix:** Install prerequisites in order:

```bash
# 1. cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# 2. Wait for cert-manager to be ready
kubectl wait --for=condition=Available -n cert-manager deployment/cert-manager --timeout=120s

# 3. MOCO
# (follow MOCO installation docs)

# 4. Then install SUNK
```

### Helm install fails with monitoring CRD errors

**Symptom:** Chart tries to create PodMonitor, VMPodScrape, or other monitoring CRDs that don't exist.

**Cause:** Chart defaults include CoreWeave-specific monitoring resources.

**Fix:** Disable monitoring CRDs in your Helm values:

```yaml
podMonitor:
  enabled: false
vmPodScrape:
  enabled: false
```

---

## DefMemPerCPU Formula and Common Errors

### The formula

`DefMemPerCPU` tells Slurm how much memory each CPU slot can use. The correct value depends on node size:

```
DefMemPerCPU = (node_allocatable_memory_MB - reservedMemory_MB) / cpus_available_to_slurm
```

### Negative DefMemPerCPU (slurmd won't register)

**Symptom:** slurmd fails to start or nodes never register. Logs show a negative DefMemPerCPU value (e.g., `-3072`).

**Cause:** The chart defaults to `reservedMemory: 4Gi` (4096 MB), which is subtracted from allocatable memory. On small nodes, this leaves too little memory and the formula produces a negative value.

**Fix:** Set `reservedMemory` to `"0"` and lower `DefMemPerCPU`:

```yaml
compute:
  reservedMemory: "0"

slurmConfig:
  DefMemPerCPU: 2000
```

### Requested node configuration is not available

**Symptom:** `srun` or `sbatch` fails with "Requested node configuration is not available in this partition."

**Cause:** `DefMemPerCPU` is set higher than the node can provide per CPU.

**Fix:** Lower `DefMemPerCPU` to match your node size, or explicitly request less memory in your jobs: `srun --mem=100 hostname`.

### Requested partition configuration is not available

**Symptom:** `srun --nodes=1 nvidia:smi` (or any job targeting GPUs) hangs
with:

```
srun: Requested partition configuration not available now
srun: job 1 queued and waiting for resources
```

**Causes and fixes:**

1. **No GPU partition exists.** The default deploy enables `cpu-workers`
   only; `gpu-workers` is opt-in. Check:

   ```bash
   sinfo -o '%P %a %N %G'
   # If gpu-workers is missing, enable it in your overlay:
   ```

   ```yaml
   compute:
     nodes:
       gpu-workers:
         enabled: true
         replicas: 1
   ```

   Then `helm upgrade` and wait for the GPU nodepool/nodegroup to
   provision the node (a few minutes on GKE, 3-5 on EKS).

2. **Wrong GRES syntax.** `nvidia:smi` is a common typo, parsed as "1 GRES
   of type nvidia:smi". The right form specifies a real GRES resource:

   ```bash
   srun --gres=gpu:1 nvidia-smi             # any GPU type
   srun --gres=gpu:a10g:1 nvidia-smi        # EKS g5.xlarge (A10G)
   srun --gres=gpu:l4:1   nvidia-smi        # GKE g2-standard-4 (L4)
   ```

   Confirm what the partition exposes:

   ```bash
   sinfo -o '%P %G'
   # gpu-workers  gpu:a10g:1
   ```

3. **Partition exists but node isn't UP yet.** A node can be drained,
   `down*`, or `fail*`. `sinfo -N` shows per-node state. If the node is
   `down*` with reason "Low RealMemory" or similar, see the DefMemPerCPU
   section above.

---

## Lock Taint and System Pod Eviction

The SUNK operator hardcodes `sunk.coreweave.com/lock=true:NoExecute` on every node running compute pods. This taint is not configurable. Any pod without a matching toleration gets evicted from those nodes.

### What breaks without the lock taint toleration

| Component | Typical namespace | Impact |
|-----------|-------------------|--------|
| Connectivity agent | kube-system | kubectl exec, kubectl logs, webhook calls all fail |
| DNS (kube-dns/CoreDNS) | kube-system | DNS resolution stops on affected nodes |
| cert-manager | cert-manager | Certificate renewal stops; breaks MOCO and TLS |
| moco-controller | moco-system | MySQL operator can't manage databases |
| metrics-server | kube-system | HPA scaling and `kubectl top` break |
| dcgm-exporter | monitoring | GPU metrics collection stops |

The specific system components that get evicted depend on your provider. See your provider's troubleshooting doc for the exact patch commands.

### Certificate errors from MOCO or webhooks

**Symptom:** MOCO MySQL unhealthy, webhook calls fail, TLS certificate errors in logs.

**Cause:** cert-manager was evicted, so certificates expired or failed to renew.

**Fix:** Run your provider's toleration patch script, then restart cert-manager:

```bash
kubectl rollout restart -n cert-manager deployment/cert-manager
# Wait 2 minutes for cert renewal
```

---

## GPU Issues

### nvidia-smi: command not found

**Cause 1:** Node pool created without GPU drivers. Verify your node pool has NVIDIA drivers installed.

**Cause 2:** The s6 nvidia-setup script is missing or placed at the wrong path. It must be at `compute.s6`, NOT `compute.nodes.<name>.s6`.

**Cause 3:** `LD_LIBRARY_PATH` doesn't include the NVIDIA library path. Verify the environment variables in your compute node config.

### GPU not detected (libnvidia-ml.so.1: cannot open)

**Symptom:** slurmd fails with `libnvidia-ml.so.1: cannot open shared object file`.

**Cause:** The provider mounts NVIDIA drivers after container startup, so the ldconfig cache is stale.

**Fix:** Add the s6 oneshot script to run ldconfig at boot:

```yaml
compute:
  s6:
    nvidia-setup:
      type: oneshot
      script: |
        #!/usr/bin/env bash
        if [ -d /usr/local/nvidia/lib64 ]; then
          echo /usr/local/nvidia/lib64 > /etc/ld.so.conf.d/nvidia.conf
          ldconfig
          ln -sf /usr/local/nvidia/bin/nvidia-smi /usr/local/bin/nvidia-smi 2>/dev/null || true
        fi
```

Adjust the path (`/usr/local/nvidia`) if your provider mounts drivers elsewhere.

### GPU nodes stuck in INVALID_REG

**Symptom:** `sinfo` shows GPU nodes in `INVALID_REG` state.

**Cause:** GRES mismatch between what Slurm expects (gres.conf) and what the node reports. SUNK container images lack compile-time NVML support, so `AutoDetect=nvml` fails silently.

**Fix:** Patch gres.conf with explicit per-node GPU entries:

```bash
# After initial deploy
bash infrastructure/sunk-post-upgrade.sh

# Or manually patch the ConfigMap with explicit entries:
# NodeName=<gpu-pod> Name=gpu Type=<type> File=/dev/nvidia0
```

The `NodeName=` qualifier is critical. Without it, the `File=/dev/nvidia0` line applies to ALL nodes including CPU workers, which crash trying to stat a device that doesn't exist on them.

After patching, restart the GPU pod and resume the node:

```bash
kubectl delete pod -n tenant-slurm <gpu-pod>
# Wait 30s for pod restart
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  scontrol update NodeName=<gpu-pod> State=RESUME
```

### gres.conf reset after helm upgrade

**Expected behavior.** The chart overwrites the ConfigMap on every `helm install` or `helm upgrade`, replacing your manual gres.conf patch with `AutoDetect=nvml` (which silently fails).

**Fix:** Re-run the gres.conf patch after every Helm upgrade:

```bash
bash infrastructure/sunk-post-upgrade.sh
```

### Pod stuck Pending with "Insufficient nvidia.com/gpu"

**Cause 1:** No GPU capacity. Check `kubectl describe node <gpu-node>` for allocatable GPUs.

**Cause 2:** `nodeSelector` mismatch. Verify it matches your GPU pool label.

**Cause 3:** Missing resource request. Both `requests` and `limits` must include `nvidia.com/gpu: "1"` in the compute node config.

### Changing GPU types

When switching GPU types (e.g., T4 to L4), update ALL of these or you'll get `INVALID_REG`:

1. GPU type and machine type in node pool creation
2. `gresGpu` in compute node config
3. `Type=` and `File=` in gres.conf patch
4. The GPU class label value

### Seccomp profile not available for Pyxis/enroot

**Symptom:** Compute pods stuck in `Init:CreateContainerError`. `kubectl describe pod` shows:

```
Error: failed to create containerd container: cannot load seccomp profile
/var/lib/kubelet/seccomp/profiles/enroot: open
/var/lib/kubelet/seccomp/profiles/enroot: no such file or directory
```

**Cause:** Pyxis requires a seccomp profile file on every node at
`/var/lib/kubelet/seccomp/profiles/enroot`. Managed Kubernetes distros
(EKS, GKE) don't ship it by default.

**Fix (preferred):** Apply the seccomp installer DaemonSet BEFORE
`helm install slurm`. It runs on every node (including nodes that join
later) and copies the profile file into place:

```bash
kubectl apply -f infrastructure/universal/seccomp-installer-daemonset.yaml
kubectl rollout status -n seccomp-installer ds/seccomp-installer --timeout=120s
```

**Fix (fallback):** If you can't run a DaemonSet with hostPath
(restrictive PodSecurityPolicy, OPA/Kyverno rule, etc.), either:

- Disable Pyxis in your overlay: `compute.pyxis.enabled: false`, OR
- Override the profile type to unconfined (less secure, unblocks testing):

  ```yaml
  compute:
    pyxis:
      podSecurityContext:
        seccompProfile:
          type: Unconfined
  ```

To verify the DaemonSet landed the profile on a specific node:

```bash
kubectl debug node/<NODE> -it --image=busybox -- \
  ls -la /host/var/lib/kubelet/seccomp/profiles/enroot
```

---

## NFS and Shared Storage

### NFS server pod stuck in Pending

**Cause:** Wrong image or wrong node placement.

**Fix:** Verify the NFS deployment uses a compatible NFS image and is scheduled on non-SUNK-tainted nodes. The `itsthenetwork/nfs-server-alpine:12` image uses userspace NFS and works on most platforms.

### NFS mount hangs in Slurm pods

**Cause:** NFS server not responding, or NFS compatibility issue.

**Fix:** Verify the NFS pod is Running and test connectivity:

```bash
kubectl logs -n tenant-slurm <nfs-pod>
# From a test pod:
kubectl run -it --rm nfs-test --image=ubuntu -- \
  bash -c "apt update && apt install -y nfs-common && mount.nfs <NFS_IP>:/export /mnt && ls /mnt"
```

### Shared filesystem test fails

**Symptom:** `echo test > /home/test.txt && srun cat /home/test.txt` fails.

**Cause:** NFS mount not ready, permissions issue, or PVC not bound.

**Fix:** Verify NFS server is Running, PVC is Bound, and test from the login node:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  bash -c 'touch /home/test.txt && srun --mem=100 cat /home/test.txt && rm /home/test.txt'
```

---

## Slurm Node Registration and Jobs

### Slurm controller not responding

**Symptom:** `scontrol` commands return "Slurm controller not responding."

**Cause:** Controller pod not Running or init containers still completing.

**Fix:** Check controller status:

```bash
kubectl get pods -n tenant-slurm slurm-controller-0
kubectl describe pod -n tenant-slurm slurm-controller-0
```

MySQL/MOCO initialization can take 2+ minutes. Wait for all init containers to complete.

### Compute nodes show down* in sinfo

**Cause:** GRES mismatch between config and actual GPUs, or slurmd failed to register.

**Fix:**

1. Check controller logs: `kubectl logs -n tenant-slurm slurm-controller-0 -c slurmd`
2. Verify gresGpu matches the actual GPU type
3. Run `scontrol reconfigure` from the login node after fixing config

### Job hangs in CF (Configuring) state

**Cause:** Slurm waiting for node to transition.

**Fix:** Check node state: `scontrol show node <NODENAME>`. If stuck, manually resume:

```bash
scontrol update NodeName=<NAME> State=RESUME
```

### Nodes drained after job completion

**Symptom:** Nodes go to `drain` state after jobs finish instead of returning to `idle`.

**Cause:** The syncer isn't running or lacks RBAC to remove the lock taint from nodes.

**Fix:** Verify syncer is running:

```bash
kubectl get pods -n sunk | grep syncer
kubectl logs -n sunk <syncer-pod>
```

---

## User Authentication (OpenLDAP/nsscache)

### nsscache getent fails with "Source map empty"

**Symptom:** `getent passwd` on login/compute pods returns no LDAP users. nsscache logs show "Source map empty."

**Cause:** LDAP search scope defaults to `ONE_LEVEL`, which only searches direct children of the base DN. Users in nested OUs are missed.

**Fix:** Set `ldap_scope: sub` in nsscache config to search the full subtree.

### LDAP connection refused or timeout

**Fix:** Check in order:

1. OpenLDAP pod is Running: `kubectl get pods -n tenant-slurm -l app=openldap`
2. Service endpoint exists: `kubectl get svc -n tenant-slurm openldap`
3. Test from login pod: `nc -zv openldap.tenant-slurm.svc.cluster.local 389`
4. Check slapd logs: `kubectl logs -n tenant-slurm <openldap-pod> -c slapd`

### SSH authentication fails (Permission denied publickey)

Check these in order:

1. **Key format:** Must be OpenSSH format, not PEM. Convert: `ssh-keygen -i -f key.pub > key.pub.openssh`
2. **File permissions:** `chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh`
3. **Home directory ownership:** `chown $USER:$GROUP ~` (OpenSSH StrictModes rejects root-owned home dirs)
4. **sshd config:** Verify `PubkeyAuthentication yes`

### Munge authentication fails ("Authentication token is invalid")

**Cause:** Munge keys differ between controller and compute pods, or munge daemon isn't running.

**Fix:** All pods must mount the same `slurm-munge-key` secret. Verify:

```bash
kubectl get secret slurm-munge-key -n tenant-slurm
```

### User lookup fails ("User not found" in Slurm)

**Cause:** nsscache not synced.

**Fix:** Force sync on affected pods:

```bash
kubectl exec -n tenant-slurm <pod> -- nsscache sync
kubectl exec -n tenant-slurm <pod> -- nsscache -d dump passwd
```

### Home directory not created for LDAP users

**Cause:** `pam_mkhomedir` missing from PAM config.

**Fix:** Verify `/etc/pam.d/common-session` includes:

```
session optional pam_mkhomedir.so umask=0077
```

---

## SkyPilot Integration

### sky check slurm shows "not enabled"

**Cause:** Missing or malformed `~/.slurm/config`.

**Fix:** Verify the file exists and test manually:

```bash
ssh -F ~/.slurm/config sunk-cluster echo "test"
```

### "Catalog does not contain any instances satisfying the request"

**Cause:** SkyPilot's default memory request (~2 GB) exceeds what small nodes report. This only affects small dev/test clusters.

**Fix:** Explicitly request low memory in your SkyPilot YAML:

```yaml
resources:
  memory: 0.5  # For 512MB nodes
```

Check available instances: `sky gpus list --cloud slurm`

### SSH works but sky launch hangs

**Cause:** SkyPilot SSHes to the login node, then submits Slurm jobs. If Slurm can't schedule, it hangs.

**Fix:** Verify from the login node that jobs can run:

```bash
srun --mem=100 hostname
```

---

## Upgrade Issues

### Full upgrade checklist

Before upgrading:

```bash
# 1. Backup gres.conf
kubectl get configmap slurm-slurm-conf -n tenant-slurm -o yaml > gres-backup.yaml

# 2. Backup Helm values
helm get values slurm -n tenant-slurm > slurm-values-backup.yaml

# 3. Preview changes
helm diff upgrade slurm coreweave/slurm \
  -f helm-values/slurm-values.yaml \
  -n tenant-slurm
```

After upgrading, always run the post-upgrade script:

```bash
bash infrastructure/sunk-post-upgrade.sh
```

This re-patches gres.conf, re-patches system tolerations, restarts GPU pods, and resumes nodes.

### GPU nodes INVALID_REG after upgrade

**Cause:** gres.conf was overwritten by the chart (expected behavior).

**Fix:** `bash infrastructure/sunk-post-upgrade.sh`. If auto-detection picks wrong values, restore from your backup:

```bash
cat gres-backup.yaml | grep -A 5 "gres.conf"
```

### Post-upgrade script detects wrong GPU type

**Cause:** The `sunk.coreweave.com/gres-gpu` label is missing, and the fallback heuristic guessed wrong.

**Fix:** Manually patch gres.conf using your backup values, then restart GPU pods.

### MOCO MySQL unhealthy after upgrade

**Cause:** cert-manager was evicted, so certificates expired.

**Fix:** Run your provider's toleration patch script, then:

```bash
kubectl rollout restart -n cert-manager deployment/cert-manager
# Wait 5 minutes for cert renewal
```

### Partitions still in DRAIN after upgrade

**Cause:** If you drained partitions before upgrading, they don't automatically restore.

**Fix:** `scontrol update PartitionName=ALL State=UP`

---

## Common Patterns

These issues recur across multiple operations. Understanding them saves repeat debugging.

**gres.conf is fragile.** The chart overwrites it on every Helm operation. There is no Helm value to set explicit GPU entries. You must patch the ConfigMap after every install or upgrade. Always back up before upgrading.

**The lock taint is not configurable.** SUNK hardcodes `sunk.coreweave.com/lock=true:NoExecute`. You cannot disable it or change the key. Every pod that needs to run on compute nodes must tolerate it, including provider-managed system pods.

**Provider-managed resources may be reconciled.** Providers periodically revert Deployment specs for system components. Your toleration patches may be stripped. Plan to re-run the patch script after cluster upgrades.

**Chart defaults target CoreWeave.** Node affinity, monitoring CRDs, image registries, and resource sizing all default to CoreWeave infrastructure. Every non-CoreWeave deployment must override these.
