# GKE Troubleshooting

GKE-specific troubleshooting entries. For general Slurm troubleshooting (DefMemPerCPU, GRES, NFS, user auth, SkyPilot), see [../universal/troubleshooting.md](../universal/troubleshooting.md).

---

## Lock Taint and GKE System Pod Eviction

The SUNK operator hardcodes `sunk.coreweave.com/lock=true:NoExecute` on every node running compute pods. GKE system pods do not tolerate this taint and get evicted.

### kubectl exec fails with "No agent available"

**Symptom:** `kubectl exec` returns "No agent available" or times out.

**Cause:** The konnectivity-agent was evicted from compute nodes because it lacks the lock taint toleration.

**Fix:** Run the toleration patch script:

```bash
bash infrastructure/patch-gke-tolerations.sh
```

Verify recovery:

```bash
kubectl get pods -n kube-system -l k8s-app=konnectivity-agent -o wide
```

### DNS resolution fails inside pods

**Symptom:** Pods on compute nodes can't resolve DNS names. `nslookup kubernetes.default` fails.

**Cause:** kube-dns was evicted from compute nodes.

**Fix:** Run `bash infrastructure/patch-gke-tolerations.sh`. Then test:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- nslookup kubernetes.default
```

### Certificate errors from MOCO or webhooks

**Symptom:** MOCO MySQL unhealthy, webhook calls fail, TLS certificate errors in logs.

**Cause:** cert-manager was evicted, so certificates expired or failed to renew.

**Fix:**

```bash
bash infrastructure/patch-gke-tolerations.sh
kubectl rollout restart -n cert-manager deployment/cert-manager
# Wait 2 minutes for cert renewal
```

### Patches revert after GKE upgrades

**Symptom:** System pods get evicted again hours or days after patching.

**Cause:** GKE control plane reconciliation periodically reverts managed Deployment specs, stripping the toleration.

**Fix:** Re-run `bash infrastructure/patch-gke-tolerations.sh` after any GKE cluster or control plane upgrade. Consider monitoring for evicted system pods or scheduling the script to run periodically.

### What breaks without the lock taint toleration (GKE)

| Component | Namespace | Kind | Impact |
|-----------|-----------|------|--------|
| konnectivity-agent | kube-system | Deployment / DaemonSet | kubectl exec, kubectl logs, webhook calls all fail |
| kube-dns | kube-system | Deployment | DNS resolution stops on affected nodes |
| cert-manager | cert-manager | Deployment | Certificate renewal stops; breaks MOCO and TLS |
| moco-controller | moco-system | Deployment | MySQL operator can't manage databases |
| metrics-server | kube-system | Deployment | HPA scaling and `kubectl top` break |
| gmp-operator | gmp-system | Deployment | Cloud Monitoring metrics collection stops |
| kube-state-metrics | gke-managed-cim | StatefulSet | GMP-managed kube-state metrics drop, breaking dashboards |
| dcgm-exporter | monitoring | DaemonSet | GPU metrics collection stops |

### Patch reports success but toleration is still missing

**Symptom:** `patch-gke-tolerations.sh` printed `patched` for a workload, but
`kubectl get <kind> <name> -o jsonpath='{.spec.template.spec.tolerations}'`
shows no `sunk.coreweave.com/lock` entry, and pods on tainted compute nodes
still get evicted.

**Cause:** Some GKE-managed workloads accept a strategic merge patch on
tolerations without retaining it (observed on `kube-state-metrics` and a few
kube-system Deployments).

**Fix:** The current `infrastructure/gke/patch-gke-tolerations.sh` already
verifies after each strategic merge and falls back to an explicit JSON
patch when the toleration is absent. If you are running an older copy of
the script, pull the latest. After running the script, wait for rollouts
before trusting `kubectl exec`:

```bash
kubectl rollout status deploy/konnectivity-agent -n kube-system --timeout=180s
kubectl rollout status deploy/kube-dns -n kube-system --timeout=180s
kubectl rollout status sts/kube-state-metrics -n gke-managed-cim --timeout=180s
```

---

## GKE Autopilot Not Supported

**Symptom:** Various failures: privileged container denied, hostNetwork blocked, custom taints rejected.

**Cause:** SUNK requires GKE Standard. Autopilot blocks privileged containers, custom taints, and hostNetwork, all of which SUNK needs.

**Fix:** Create a GKE Standard cluster. There is no workaround for Autopilot.

---

## GPU Monitoring on GKE

### DCGM exporter CrashLoopBackOff

**Symptom:** dcgm-exporter pods crash with "Cannot find libcudart.so" or GPU initialization errors.

**Cause:** GKE mounts NVIDIA drivers at `/home/kubernetes/bin/nvidia`, not the standard `/usr/local/nvidia`.

**Fix:** Verify the DaemonSet environment variables:

```yaml
env:
  - name: LD_LIBRARY_PATH
    value: "/home/kubernetes/bin/nvidia/lib64"
  - name: PATH
    value: "/home/kubernetes/bin/nvidia/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
securityContext:
  privileged: true  # Required to access GPU device files
```

### DCGM exporter pod stuck Pending

**Cause:** DaemonSet scheduling on non-GPU nodes that lack the NVIDIA driver directory.

**Fix:** Restrict to GPU nodes only:

```yaml
nodeSelector:
  cloud.google.com/gke-nodepool: gpu
```

### Metrics not appearing in Cloud Monitoring

Check in order:

1. DCGM exporter pods running: `kubectl get pods -n monitoring -l app=dcgm-exporter`
2. PodMonitoring CRD exists: `kubectl get podmonitoring -n monitoring`
3. Pod labels match PodMonitoring selector
4. GMP operator healthy: `kubectl get pods -n gmp-system`

---

## GPU Quota on GKE

### GPU quota exceeded — preflight both global and regional

**Symptom:** Node pool creation or update fails with one of:

```
Quota 'GPUS_ALL_REGIONS' exceeded. Limit: N globally.
Quota 'NVIDIA_L4_GPUS' exceeded. Limit: N in region us-central1.
```

The first form is the project-wide accelerator quota; the second form is
the regional per-accelerator quota. GCP enforces them independently — only
checking one is the most common reason a resize "works" briefly and then
the backing MIG spins on quota errors.

**Cause:** Default GKE GPU quotas on a fresh project are typically `1`
globally and `1` per region for L4/A100/H100. GKE can also try to create a
surge node during updates, doubling the temporary requirement.

**Fix:**

```bash
# 1. Project-global accelerator quota
gcloud compute project-info describe --project "$PROJECT_ID" \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  | grep GPUS_ALL_REGIONS

# 2. Regional accelerator quota (use the metric that matches your GPU type)
gcloud compute regions describe "$REGION" --project "$PROJECT_ID" \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  | grep -E 'NVIDIA_(L4|A100|H100)_GPUS'

# Prevent surge nodes during updates so a single-GPU quota does not need to
# briefly cover two GPUs during a rolling update.
gcloud container node-pools update gpu \
  --cluster="$CLUSTER_NAME" --zone="$ZONE" \
  --max-surge-upgrade=0 --max-unavailable-upgrade=1
```

If either `limit - usage` is short, request an increase via GCP console
(IAM & Admin → Quotas) before retrying. Both names must match exactly:
the global quota is always `GPUS_ALL_REGIONS`, the regional quota is
`NVIDIA_<TYPE>_GPUS`.

### Recovering from a GPU resize stuck on quota errors

**Symptom:** `gcloud container clusters resize ... --num-nodes=2` returned
success, but the GPU node pool is stuck. `gcloud compute instance-groups
managed list-errors <gpu-mig-name>` shows repeated quota errors and the
target size never drops back.

**Fix:** Scale the node pool back to the size your quota actually supports.
Always try the GKE-level resize first — it owns the MIG target size:

```bash
gcloud container clusters resize "$CLUSTER_NAME" \
  --node-pool gpu \
  --num-nodes=1 \
  --zone "$ZONE" \
  --project "$PROJECT_ID" \
  --quiet
```

If GKE refuses with `Operation in progress`, inspect the underlying MIG and
only then resize it directly as a recovery path:

```bash
gcloud compute instance-groups managed list-errors <gpu-mig-name> \
  --zone "$ZONE" --project "$PROJECT_ID"

gcloud compute instance-groups managed resize <gpu-mig-name> \
  --size=1 \
  --zone "$ZONE" \
  --project "$PROJECT_ID" \
  --quiet
```

Resizing the MIG out from under GKE is not the happy path — GKE may
reconcile your MIG resize back. Use it only when the GKE resize is
genuinely blocked.

---

## GKE NFS Compatibility

### NFS server image issues

Only `itsthenetwork/nfs-server-alpine:12` works on GKE's Container-Optimized OS nodes. Other images fail:

| Image | Works on GKE? | Why it fails |
|-------|---------------|-------------|
| `itsthenetwork/nfs-server-alpine:12` | Yes | Userspace NFS, no kernel module needed |
| `registry.k8s.io/volume-nfs:0.8` | No | Docker manifest v1 rejected by containerd v2.1 |
| `erichough/nfs-server:2.2.1` | No | Requires kernel NFS module not loaded on COS |

---

## GKE Upgrade Issues

### kubectl exec fails after GKE upgrade

**Cause:** GKE reconciliation stripped the lock taint toleration during the upgrade.

**Fix:** `bash infrastructure/patch-gke-tolerations.sh`

### MOCO MySQL unhealthy after GKE upgrade

**Cause:** cert-manager was evicted during the upgrade, so certificates expired.

**Fix:**

```bash
bash infrastructure/patch-gke-tolerations.sh
kubectl rollout restart -n cert-manager deployment/cert-manager
# Wait 5 minutes for cert renewal
```

---

## GKE-Specific Home Directory Path

**GKE:** `/home/USERNAME`
**CoreWeave:** `/mnt/home/USERNAME`

Always verify: `getent passwd USERNAME | cut -d: -f6`

Place SSH keys at the correct path. This is a common source of "Permission denied" errors when moving between platforms.

---

## GKE StorageClass Issues

### PVCs stuck in Pending

GKE provides `premium-rwo` (SSD) and `standard-rwo` (balanced) StorageClasses. If you specified a StorageClass that does not exist, PVCs will stay Pending.

**Fix:** Verify available storage classes:

```bash
kubectl get storageclass
```

Update your Helm values to use an existing class:

```yaml
controller:
  stateVolume:
    storageClassName: premium-rwo
```

### Using Google Filestore instead of in-cluster NFS

For production, replace the userspace NFS with a managed Filestore instance:

1. Create a Filestore instance in the same VPC/region as your GKE cluster.
2. Update `global.volumes` and `global.volumeMounts` in slurm-values.yaml:

```yaml
global:
  volumes:
    - name: shared-home
      nfs:
        server: <FILESTORE_IP>       # e.g., 10.0.0.2
        path: /vol1                   # Filestore share name
  volumeMounts:
    - name: shared-home
      mountPath: /home
```

3. Skip deploying `infrastructure/nfs-server.yaml`.
