# Deployment Guide

End-to-end guide for deploying SUNK (Slurm on Kubernetes) on Google Kubernetes Engine. This walks through every step from a bare GCP project to a working Slurm cluster with copy-pasteable commands.

For architecture details and component descriptions, see [../universal/architecture.md](../universal/architecture.md). For GKE-specific adaptations, see [gke-adaptations.md](gke-adaptations.md). For post-deployment issues, see [gke-troubleshooting.md](gke-troubleshooting.md) and [../universal/troubleshooting.md](../universal/troubleshooting.md).

---

## Prerequisites

### Tools

Install the following before starting:

- **gcloud CLI** with the GKE auth plugin
- **kubectl**
- **Helm 3**

The SUNK and Slurm charts are licensed. Reach out to CoreWeave at
<sunk@coreweave.com> for access instructions, then substitute the repository
URL you receive for `<COREWEAVE_HELM_REPO_URL>` below.

```bash
# Install the GKE auth plugin (if not already present)
gcloud components install gke-gcloud-auth-plugin

# Add all required Helm repos.
helm repo add coreweave <COREWEAVE_HELM_REPO_URL> --force-update
helm repo add jetstack https://charts.jetstack.io
helm repo add moco https://cybozu-go.github.io/moco/
helm repo update

# Preflight: confirm the chart repo is reachable before you start installing.
helm show chart coreweave/sunk
helm show chart coreweave/slurm
```

### GCP Project

You need a GCP project with:

- **Owner** or **Editor** role on the project
- The **Kubernetes Engine API** and **Compute Engine API** enabled
- Sufficient CPU quota for your node pools (8+ vCPUs recommended)
- GPU quota if you plan to add GPU nodes later

Verify your setup:

```bash
# Check active GCP account (use your corporate account, not personal)
gcloud auth list

# Set the target project
gcloud config set project YOUR_PROJECT_ID

# Enable required APIs (idempotent, safe to re-run)
gcloud services enable container.googleapis.com compute.googleapis.com

# Check CPU and GPU quota in your target region
export REGION="us-central1"
gcloud compute regions describe $REGION \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  --filter="quotas.metric:CPUS OR quotas.metric:GPU"

# GPUs are also gated by a project-wide quota, not just regional.
# Check both before creating or resizing a GPU node pool.
gcloud compute project-info describe \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  | grep GPUS_ALL_REGIONS
```

For each accelerator family you plan to use (L4, A100, H100), confirm the
matching regional metric (`NVIDIA_L4_GPUS`, `NVIDIA_A100_GPUS`,
`NVIDIA_H100_GPUS`) has `limit - usage >=` the count you intend to launch.
A node-pool create can succeed while the backing managed instance group
loops on `Quota '... GPUS' exceeded`, leaving the pool stuck — only
checking the regional metric prevents this.

---

## Step 1: Create the GKE Cluster

SUNK requires **GKE Standard** mode. Autopilot is not supported because SUNK needs privileged pods, hostNetwork access, custom DaemonSets, and fine-grained node pool control.

Set these variables for your environment, then create the cluster:

```bash
export PROJECT_ID="your-project-id"
export CLUSTER_NAME="sunk"
export ZONE="us-central1-a"
export CPU_POOL="cpu-4"
export CPU_MACHINE="e2-standard-4"  # 4 vCPU, 16 GiB
export CPU_NODE_COUNT=2             # Minimum 2 for headroom

gcloud container clusters create $CLUSTER_NAME \
  --project=$PROJECT_ID --zone=$ZONE \
  --num-nodes=$CPU_NODE_COUNT \
  --machine-type=$CPU_MACHINE \
  --node-labels=cloud.google.com/gke-nodepool=$CPU_POOL \
  --release-channel=regular \
  --enable-ip-alias \
  --workload-pool=${PROJECT_ID}.svc.id.goog
```

The `--node-labels` flag sets the `cloud.google.com/gke-nodepool=cpu-4` label that all Helm values reference for pod scheduling. The `--enable-ip-alias` flag enables VPC-native networking, and `--workload-pool` enables Workload Identity Federation.

**Minimum sizing:** 2x e2-standard-4 provides ~7.8 allocatable CPU and ~26 GiB RAM. The SUNK control plane needs ~2.7 CPU and ~8.8 GiB total. See the [Resource Requirements](#resource-requirements) section for a full breakdown.

After creation, get credentials:

```bash
gcloud container clusters get-credentials $CLUSTER_NAME \
  --zone=$ZONE --project=$PROJECT_ID
```

---

## Step 2: Create Namespaces and Install Dependencies

### Namespaces

Create all namespaces upfront:

```bash
kubectl create namespace sunk
kubectl create namespace tenant-slurm
kubectl create namespace moco-system
kubectl create namespace cert-manager
kubectl create namespace monitoring
```

### cert-manager

MOCO (the MySQL operator) requires cert-manager for certificate issuance:

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true
```

### MOCO MySQL Operator

MOCO manages the MySQL instance used by Slurm for job accounting. It is installed as a standalone chart rather than through the SUNK chart to avoid version and configuration conflicts:

```bash
helm install moco moco/moco --namespace moco-system
```

---

## Step 3: Deploy the NFS Server

Slurm requires a shared `/home` filesystem accessible from the controller, login, and all compute pods. GCE Persistent Disks only support ReadWriteOnce, so an in-cluster NFS server bridges the gap.

### NFS Image Compatibility

Only `itsthenetwork/nfs-server-alpine:12` works on GKE's Container-Optimized OS nodes. It uses userspace NFS and does not require kernel modules. Other commonly suggested images fail:

| Image | Works on GKE? | Why it fails |
|-------|---------------|-------------|
| `itsthenetwork/nfs-server-alpine:12` | Yes | Userspace NFS, no kernel module needed |
| `registry.k8s.io/volume-nfs:0.8` | No | Docker manifest v1 rejected by containerd v2.1 |
| `erichough/nfs-server:2.2.1` | No | Requires kernel NFS module not loaded on COS |

### Deploy

The NFS server manifest is provided in the repo:

```bash
kubectl apply -f infrastructure/nfs-server.yaml
```

Wait for it to become available before proceeding:

```bash
kubectl wait --for=condition=available deployment/nfs-server \
  -n tenant-slurm --timeout=120s
```

The NFS server must include the lock taint toleration and CPU pool affinity. Without the toleration, it gets evicted when SUNK taints nodes. Without the affinity, it could land on a GPU node and waste expensive resources. The provided manifest already includes both.

---

## Step 4: Understand the Lock Taint

This is the single most important GKE-specific concept in the deployment. Read this section before touching any Helm values.

### What Happens

The SUNK operator applies a non-configurable `NoExecute` taint to every Kubernetes node running compute pods:

```
sunk.coreweave.com/lock=true:NoExecute
```

On CoreWeave infrastructure, compute nodes are dedicated, so this is harmless. On GKE with shared node pools, this taint evicts every pod that does not tolerate it, including:

- **konnectivity-agent**: Breaks `kubectl exec`, `kubectl logs`, and webhook calls. This is the most disruptive failure because it makes the cluster nearly unmanageable.
- **kube-dns**: Breaks all in-cluster DNS resolution.
- **cert-manager** and **moco-controller**: Breaks certificate issuance and MySQL management.
- **metrics-server**, **gmp-operator**, and other system components.

### The Fix

Every SUNK and Slurm pod must include this toleration in its Helm values:

```yaml
tolerations:
  - key: sunk.coreweave.com/lock
    operator: Exists
    effect: NoExecute
```

The values files in `helm-values/` already include this on every component. GKE system pods need a separate patch applied after compute nodes join (Step 7).

---

## Step 5: Deploy the SUNK Operator

The SUNK operator chart manages the compute pod lifecycle, the syncer (bidirectional Slurm/K8s state sync), and the pod scheduler. The values file at `helm-values/sunk-values.yaml` is pre-configured for GKE with these adaptations:

- **NVIDIA device plugin disabled**: GKE provides its own. The SUNK device plugin is a CoreWeave fork with custom resource naming that conflicts.
- **Resource requests reduced**: The defaults (8 CPU / 32 GiB) are sized for CoreWeave production nodes and will not fit on e2-standard-4.
- **Monitoring CRDs disabled**: GKE does not ship Prometheus Operator or VictoriaMetrics. Leaving `podMonitor` or `vmPodScrape` enabled causes CRD-not-found errors.
- **MOCO disabled**: Already installed in Step 2.

Deploy:

```bash
helm upgrade --install sunk coreweave/sunk \
  -f helm-values/sunk-values.yaml -n sunk
```

---

## Step 6: Deploy the Slurm Chart

This is the most complex step. The Slurm chart deploys the controller, accounting database, REST API, login node, compute nodes, and supporting components.

The values file at `helm-values/slurm-values.yaml` contains all the GKE-specific adaptations. Before deploying, review and customize:

- **`clusterName`**: Set to your cluster's name.
- **Node pool names**: The default values reference `cpu-4` and `gpu`. Update these if your node pools have different names.
- **`storageClassName`**: Uses `premium-rwo` (SSD-backed). Change to `standard-rwo` for cost savings in non-production environments.

### Why These Overrides Exist

The Slurm chart is designed for CoreWeave infrastructure. Several defaults must be overridden for GKE. See [gke-adaptations.md](gke-adaptations.md) for the full table of overrides and their rationale.

### Deploy

```bash
helm upgrade --install slurm coreweave/slurm \
  -f helm-values/base/slurm-values.yaml \
  -f helm-values/gke/slurm-values.yaml \
  -n tenant-slurm
```

The base values file (`helm-values/base/slurm-values.yaml`) sets `global.nodeSelector.affinity: null`, which clears the chart's default CoreWeave-specific node affinity. If you skip the base values file for any reason, append `--set-json 'global.nodeSelector.affinity=null'` to the helm command.

### Expected Temporary Errors

After `helm install`, the `slurm-syncer` and `slurm-scheduler` pods will show `CreateContainerConfigError` for 2-3 minutes. This is normal. The `slurm-secret-job` pod must generate JWT tokens first, which requires the controller to be fully running. Wait for the secret-job to reach `Completed` status. Do not delete or restart pods during this window.

---

## Step 7: Patch GKE System Pods

After the SUNK operator taints compute nodes, GKE system pods on those nodes get evicted. A patch script adds the lock taint toleration to all affected system deployments:

```bash
bash infrastructure/patch-gke-tolerations.sh
```

This patches deployments in `kube-system` (konnectivity-agent, kube-dns, metrics-server, etc.), `cert-manager`, `moco-system`, and `gmp-system`.

> **GKE may revert these patches during cluster upgrades.** If `kubectl exec` or DNS suddenly stops working after a GKE upgrade, re-run this script.

---

## Step 8: Verify the Deployment

Run each check below in order. Do not proceed past a failed check; fix it first using the [troubleshooting guide](gke-troubleshooting.md).

### Check 1: All Pods Healthy

```bash
kubectl get pods -n tenant-slurm
kubectl get pods -n sunk
```

All pods should show `Running` or `Completed`. The syncer and scheduler may show `CreateContainerConfigError` for up to 3 minutes after initial install, which is normal.

### Check 2: Slurm Nodes Registered

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo
```

All nodes should show `idle` state. If `kubectl exec` returns "No agent available", re-run `bash infrastructure/patch-gke-tolerations.sh`.

### Check 3: Job Execution Works

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname
```

This should return the hostname of a compute pod. If `srun` hangs or returns a resource allocation error, check that `slurmConfig.DefMemPerCPU` is not too high for your node size.

### Check 4: Shared Filesystem Works

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  bash -c 'echo verification-test > /home/v.txt && srun --mem=100 cat /home/v.txt && rm /home/v.txt'
```

This should print `verification-test`, confirming that NFS is mounted and accessible from both login and compute nodes.

### Optional: GCM (facebookresearch/gcm) GPU health checks

GCM is **not** part of the default monitoring contract. It surfaces
per-GPU health as Kubernetes Node conditions on top of the DCGM /
GMP / dashboards stack already deployed. Install it only when on-node
health probing is explicitly required:

```bash
helm upgrade --install gcm oci://ghcr.io/facebookresearch/charts/gcm \
  -f helm-values/gke/gcm-values.yaml \
  --set healthChecks.cluster="$CLUSTER_NAME" \
  -n kube-system --wait --timeout=5m

bash infrastructure/gke/patch-gcm-for-gke.sh
```

Verify pods are Running and the GPU node reports `Gcm*` Node conditions:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=gcm
kubectl get node "$GPU_NODE" -o json | jq '.status.conditions[] | select(.type | test("Gcm"))'
```

### Additional Validation

After Checks 1–4 pass, run the full example suite from the host. It
exercises features the minimal smoke does not — raw pod scheduling under
the lock taint, host-side `--context` propagation, NCCL skip behavior,
pyxis containers, and others — and is the same matrix used during release
validation:

```bash
./examples/run-all.sh \
  --ns=tenant-slurm \
  --login-pod=slurm-login-0 \
  --context="$KUBE_CONTEXT"   # e.g. gke_<project>_<zone>_<cluster>
```

Expected on a 1-GPU GKE cluster:

- All default tests `PASS` except `13-nccl-test.sh`, which skips with
  `SKIPPED: NCCL needs >=2 GPUs` (see `examples/README.md` for the full
  NCCL prerequisite list).
- `19-vscode-tunnel.sh` is opt-in only; it will not run unless invoked
  with `--only=19-vscode-tunnel.sh`.
- `FAIL=0`.

If you only want to spot-check individual scripts, the directory contains:

| Script | What it validates |
|--------|-------------------|
| `01-basic-srun.sh` | Single and multi-node srun |
| `02-sbatch-cpu-job.sh` | Batch job submission |
| `03-gpu-stress-test.sh` | GPU compute (requires GPU nodes) |
| `04-validate-pod-scheduler.yaml` | SUNK pod scheduler |
| `05-validate-metrics.sh` | Metrics flowing to Cloud Monitoring |
| `06-validate-gcm-health.sh` | GCM GPU health checks |
| `13-nccl-test.sh` | Multi-GPU NCCL all-reduce |
| `16-pod-and-slurm-concurrent.sh` | Raw pod + Slurm job in parallel |

After the suite finishes, confirm nothing is leaked:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- squeue -a
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo -Nel
kubectl get pods -A --no-headers | grep -vE 'Running|Completed' || true
```

---

## Resource Requirements

### CPU Nodes (Control Plane)

At least **2x e2-standard-4** (4 vCPU, 16 GiB each). This provides ~7.8 allocatable CPU and ~26 GiB total.

| Pod | CPU request | Memory limit |
|-----|-------------|--------------|
| slurmctld | 500m | 2Gi |
| slurmdbd | 100m | 512Mi |
| slurmrestd | 100m | 512Mi |
| slurm-login | 250m | 1Gi |
| syncer | 100m | 256Mi |
| SUNK operator | 250m | 1Gi |
| NFS server | 100m | 256Mi |
| MOCO MySQL | 250m | 1Gi |
| 2x CPU compute pods | 500m | 1Gi |
| GKE system pods | ~500m | ~1Gi |
| **Total** | **~2.7 CPU** | **~8.8 GiB** |

### Storage

| PVC | Size | StorageClass |
|-----|------|--------------|
| Controller state | 5Gi | premium-rwo |
| MySQL data | 5Gi | premium-rwo |
| SSH keys | 1Gi | premium-rwo |
| NFS backing store | 10Gi+ | premium-rwo |

### DefMemPerCPU Sizing

`DefMemPerCPU` controls how much memory Slurm allocates per CPU by default. The chart default of 4096 MB works for large nodes but exceeds the available memory on small GKE nodes, causing jobs to be rejected with "Unable to allocate resources."

The formula is:

```
DefMemPerCPU = (node_allocatable_memory_MB - reservedMemory_MB) / cpus_available_to_slurm
```

Reference values by node size:

| Machine type | Allocatable RAM | vCPUs | Recommended DefMemPerCPU |
|-------------|----------------|-------|--------------------------|
| e2-standard-4 | ~15,000 MB | 4 | 100 (conservative) |
| e2-standard-8 | ~30,000 MB | 8 | 3000-3800 |
| e2-standard-16 | ~62,000 MB | 16 | 3800-4000 |
| n2-standard-32 | ~125,000 MB | 32 | 4000 (chart default is fine) |

---

## Next Steps

After the base deployment is verified:

| Capability | Skill | Description |
|------------|-------|-------------|
| GPU workers | `add-gpu-nodes-to-sunk` | Add GPU node pools and configure Slurm gres |
| GPU monitoring | `setup-sunk-gpu-monitoring` | DCGM Exporter, Cloud Monitoring dashboards, GCM health checks |
| User authentication | `configure-sunk-user-auth` | OpenLDAP, nsscache, SSH public key injection |
| System pod patching | `patch-gke-system-tolerations` | Automated fix for system pods evicted by the lock taint |
| Helm upgrades | `upgrade-sunk-on-gke` | Full upgrade checklist with pre/post checks |
| SkyPilot integration | `connect-skypilot-to-sunk` | Kubernetes-native job submission via SkyPilot |

See also:

- [Architecture](../universal/architecture.md) for component details and data flow
- [GKE Adaptations](gke-adaptations.md) for GKE-specific settings
- [Helm Values Reference](../universal/helm-values-reference.md) for every configurable parameter
- [GKE Troubleshooting](gke-troubleshooting.md) for GKE-specific issues
- [General Troubleshooting](../universal/troubleshooting.md) for common Slurm issues
