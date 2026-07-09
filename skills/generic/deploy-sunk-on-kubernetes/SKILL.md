---
name: deploy-sunk-on-kubernetes
description: >
  Deploy SUNK (Slurm on Kubernetes) on bare-metal, on-premises, or unmanaged
  Kubernetes clusters. Covers kubeadm/manual cluster setup considerations,
  manual NVIDIA device plugin installation, custom storage backends, and
  the universal SUNK deployment steps. Use when asked to "deploy SUNK on
  bare metal", "set up Slurm on Kubernetes", "install SUNK on-prem",
  "deploy SUNK on kubeadm", "deploy SUNK on Rancher", or "install Slurm
  on a self-managed Kubernetes cluster".
---

**Validation in progress on bare-metal and self-managed Kubernetes.**

# Deploy SUNK on Kubernetes (Generic / Bare-Metal / On-Prem)

Deploy SUNK (Slurm on Kubernetes) on any Kubernetes cluster that does not have its own track here: bare-metal, kubeadm, Rancher, or a managed cloud beyond GKE and EKS.

This skill is adapted from the validated GKE deployment guide. The core SUNK configuration is the same across environments; the key differences are: you manage the cluster lifecycle yourself, you must install the NVIDIA device plugin manually, you choose your own storage backend, and you control all DaemonSets directly.

## Optional features — confirm each with the user before any cluster work

**Instruction to the agent (any harness — Claude Code, Codex, Cursor, plain
chat agent):** Read this list to the user and capture a yes/no per item
**before** running any deployment commands. Ask in chat if your harness has
no structured-input tool. **This skill is in validation.** Flag any
environment-specific assumptions and capture user acknowledgement.

1. **NVIDIA device plugin** — required if any GPU nodes. Pick install path: SUNK chart, NVIDIA's official manifest, or Operator. Default: install via SUNK chart.
2. **Storage backends** — pick BOTH: a RWO StorageClass (Ceph RBD, local-path, etc.) AND a RWX backend for `/home` (NFS, CephFS, Lustre, Weka).
3. **Default local user + SSH key** — caller's SSH key, slurmdbd association so `sbatch` works immediately. Default: ON. Opt out: "skip user provisioning".
4. **DCGM exporter + Slurm syncer scrape** — GPU + Slurm metrics into your existing Prometheus stack. Default: ON when GPU present. Opt out: "skip gpu monitoring".
5. **In-cluster Grafana** — kube-prometheus-stack + SUNK dashboards. Default: ON if you don't already have a Prometheus/Grafana. Opt out: "skip monitoring".
6. **Layer-on later (opt-in only)** — LDAP multi-user via `configure-sunk-user-auth` (OpenLDAP) or `configure-sunk-authentik-sssd`; SkyPilot via `connect-skypilot-to-sunk`; GCM GPU health checks.

## Prerequisites

### Cluster Requirements

- Kubernetes 1.28+ cluster (kubeadm, Rancher, k3s, or equivalent)
- All nodes running the same Kubernetes version
- `kubectl` access with cluster-admin privileges
- **Helm 3** with the CoreWeave chart repo. The SUNK and Slurm charts are
  licensed; contact CoreWeave at sunk@coreweave.com for access instructions and
  substitute the repository URL you receive for `<COREWEAVE_HELM_REPO_URL>`:
  ```bash
  helm repo add coreweave <COREWEAVE_HELM_REPO_URL>
  helm repo update
  ```
- **cert-manager Helm repo** (needed for MOCO):
  ```bash
  helm repo add jetstack https://charts.jetstack.io
  ```
- **MOCO Helm repo**:
  ```bash
  helm repo add moco https://cybozu-go.github.io/moco/
  ```

### GPU Nodes

- NVIDIA drivers installed on GPU nodes (535+ recommended)
- `nvidia-smi` working on GPU nodes
- NVIDIA Container Toolkit installed (for GPU passthrough to containers)

### Storage

- A StorageClass that provides ReadWriteOnce block storage (Ceph RBD, local-path, NFS-provisioner, etc.)
- A ReadWriteMany solution for shared `/home` (NFS server, CephFS, Lustre, Weka, etc.)

## Step 1: Verify Cluster Health

```bash
# All nodes Ready
kubectl get nodes

# Verify GPU nodes have NVIDIA drivers
kubectl describe node <gpu-node> | grep nvidia.com/gpu

# Verify your StorageClass exists
kubectl get storageclass
```

## Step 2: Install NVIDIA Device Plugin (if needed)

On bare-metal, the NVIDIA device plugin is not pre-installed. You have two options:

### Option A: Install via SUNK chart

```yaml
# In sunk-values.yaml
nvidia-device-plugin:
  enabled: true
```

### Option B: Install separately (more control)

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --set compatWithCPUManager=true
```

If installing separately, disable it in the SUNK chart:

```yaml
nvidia-device-plugin:
  enabled: false
```

Verify GPUs are visible:

```bash
kubectl describe node <gpu-node> | grep "nvidia.com/gpu"
# Should show: nvidia.com/gpu: N (where N is the GPU count)
```

## Step 3: Create Namespaces and Install Dependencies

```bash
kubectl create namespace sunk
kubectl create namespace tenant-slurm
kubectl create namespace moco-system
kubectl create namespace cert-manager
kubectl create namespace monitoring
```

### cert-manager

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true

# Wait for cert-manager CRDs + webhook before installing MOCO. MOCO's
# chart templates Issuer objects that require cert-manager to be
# fully up, otherwise MOCO install fails with
# `no matches for kind Issuer in version cert-manager.io/v1`.
kubectl -n cert-manager wait --for=condition=Available deploy \
  -l app.kubernetes.io/instance=cert-manager --timeout=2m
```

### MOCO MySQL operator

```bash
helm install moco moco/moco --namespace moco-system
```

## Step 4: Deploy Shared Filesystem

SUNK requires shared `/home` across all pods (controller, login, compute).

### In-Cluster NFS (simplest)

Deploy an NFS server pod backed by a PVC from your StorageClass. Replace `YOUR_STORAGE_CLASS` with your actual StorageClass name.

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-backing-pvc
  namespace: tenant-slurm
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: YOUR_STORAGE_CLASS
  resources:
    requests:
      storage: 100Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: tenant-slurm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-server
  template:
    metadata:
      labels:
        app: nfs-server
    spec:
      tolerations:
        - key: sunk.coreweave.com/lock
          operator: Exists
          effect: NoExecute
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""  # Or target your CPU/infra nodes
      containers:
        - name: nfs-server
          image: itsthenetwork/nfs-server-alpine:12
          ports:
            - {name: nfs, containerPort: 2049}
          env:
            - {name: SHARED_DIRECTORY, value: "/exports"}
          securityContext:
            privileged: true
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {memory: 256Mi}
          volumeMounts:
            - {name: nfs-storage, mountPath: /exports}
      volumes:
        - name: nfs-storage
          persistentVolumeClaim:
            claimName: nfs-backing-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: tenant-slurm
spec:
  ports:
    - {name: nfs, port: 2049}
    - {name: mountd, port: 20048}
    - {name: rpcbind, port: 111}
  selector:
    app: nfs-server
  clusterIP: None
```

### External NFS Server

If you have an existing NFS server, skip the in-cluster NFS deployment and reference it directly in your Slurm Helm values:

```yaml
global:
  volumes:
    - name: shared-home
      nfs:
        server: nfs.example.com
        path: /exports/sunk-home
  volumeMounts:
    - name: shared-home
      mountPath: /home
```

### Other Shared Filesystems

- **CephFS**: Use the Ceph CSI driver with a ReadWriteMany PVC
- **Lustre**: Mount via s6 bootstrap scripts (see `docs/multi-cloud-notes.md`)
- **Weka**: Mount via s6 bootstrap scripts or Weka CSI driver

## Step 5: Understand the Lock Taint (CRITICAL)

The SUNK operator hardcodes a non-configurable `NoExecute` taint on every Kubernetes node running compute (NodeSet) pods:

```
sunk.coreweave.com/lock=true:NoExecute
```

On bare-metal with shared nodes, this taint evicts every pod that does not tolerate it. Since you control all DaemonSets, you must audit every DaemonSet that runs on compute nodes and add the toleration.

```bash
# List all DaemonSets that could land on compute nodes
kubectl get ds --all-namespaces -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name

# Patch each one
kubectl -n <namespace> patch daemonset <name> --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/tolerations/-",
   "value": {"key": "sunk.coreweave.com/lock", "operator": "Exists", "effect": "NoExecute"}}
]'
```

Common DaemonSets to patch:
- **kube-proxy** (if deployed as DaemonSet)
- **Calico/Cilium/Flannel** (CNI plugin)
- **nvidia-device-plugin** (if deployed separately)
- **node-exporter** (if Prometheus is deployed)
- **Any CSI node drivers**

## Step 6: Deploy SUNK Operator

Create `helm-values/generic/sunk-values.yaml`:

```yaml
nvidia-device-plugin:
  enabled: false  # Set to true if you want the SUNK chart to manage the device plugin

operator:
  resources:
    requests: {cpu: 250m, memory: 256Mi}
    limits: {memory: 1Gi}
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  podMonitor:
    enabled: false  # Set to true if you have Prometheus Operator installed
  vmPodScrape:
    enabled: false

syncer:
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {memory: 512Mi}
  podMonitor:
    enabled: false
  vmPodScrape:
    enabled: false

scheduler:
  podMonitor:
    enabled: false
  vmPodScrape:
    enabled: false

moco:
  enabled: false
```

Deploy:

```bash
helm upgrade --install sunk coreweave/sunk \
  -f helm-values/base/sunk-values.yaml \
  -f helm-values/generic/sunk-values.yaml -n sunk
```

## Step 7: Deploy Slurm Chart

Create `helm-values/generic/slurm-values.yaml`. Adapt node selectors and storage classes to match your cluster.

```yaml
global:
  cks: false
  volumes:
    - name: shared-home
      nfs:
        server: nfs-server.tenant-slurm.svc.cluster.local
        path: /
  volumeMounts:
    - name: shared-home
      mountPath: /home

clusterName: "sunk"

controller:
  resources:
    requests: {cpu: 500m, memory: 1Gi}
    limits: {memory: 2Gi}
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  stateVolume:
    storageClassName: YOUR_STORAGE_CLASS
    size: 5Gi

rest:
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 512Mi}
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute

accounting:
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 512Mi}
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute

login:
  replicas: 1
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  resources:
    requests: {cpu: 250m, memory: 512Mi}
    limits: {memory: 1Gi}
  service:
    type: ClusterIP  # Or LoadBalancer if you have a load balancer controller
    externalTrafficPolicy: ""
  sshKeyVolume:
    storageClassName: YOUR_STORAGE_CLASS
    size: 1Gi
    accessModes: [ReadWriteOnce]
  loginController:
    podMonitor: {enabled: false}
    vmPodScrape: {enabled: false}
  directoryCache:
    podMonitor: {enabled: false}
    vmPodScrape: {enabled: false}

compute:
  reservedMemory: "4Gi"  # Adjust based on your node size
  cacheDropper:
    enabled: false
  pyxis:
    enabled: false  # Set to true if you have enroot and the seccomp profile installed
  securityContext:
    privileged: true
  nodes:
    cpu-workers:
      enabled: true
      replicas: 2
      resources:
        requests: {cpu: 250m, memory: 256Mi}
        limits: {memory: 512Mi}
      tolerations: []
    gpu-workers:
      enabled: true    # Set to false if no GPU nodes
      replicas: 1
      gresGpu: "a100:1"  # Adjust for your GPU type and count
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
          nvidia.com/gpu: "1"
        limits:
          memory: 512Mi
          nvidia.com/gpu: "1"
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule

syncer:
  enabled: true
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {memory: 256Mi}

moco:
  enabled: true
  mysqlCluster:
    resources:
      requests: {cpu: 250m, memory: 512Mi}
      limits: {memory: 1Gi}
    persistence:
      storageClassName: YOUR_STORAGE_CLASS
      size: 5Gi
mysql:
  enabled: false

secretJob:
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
cleanupCompleting:
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute

autoPartition:
  enabled: false
cacheDropper:
  enabled: false
sunkDevicePlugin:
  enabled: false
sunkScheduler:
  enabled: false
nsscache:
  enabled: false

munge:
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {memory: 256Mi}

slurmConfig:
  DefMemPerCPU: 4096  # Adjust for your node size (see GKE skill for sizing formula)
```

Replace `YOUR_STORAGE_CLASS` with your actual StorageClass name throughout.

Deploy:

```bash
# Preflight posture printout — make the security choice visible before install.
echo "About to install SUNK with security posture: capabilities-only (generic K8s, target)."
echo "  Confirm your kubelet runs pods with cgroup-namespace=pod (k3s default;"
echo "  stock EKS AL2023 does NOT — fall back to the EKS skill there)."
echo "  Ubuntu 24.04 required for the NVIDIA enroot AppArmor profile."
echo "  See docs/universal/security-model.md for the per-cloud posture matrix"
echo "  and the customer-DIY section."

helm upgrade --install slurm coreweave/slurm \
  -f helm-values/base/slurm-values.yaml \
  -f helm-values/generic/slurm-values.yaml \
  --set-json 'global.nodeSelector.affinity=null' \
  -n tenant-slurm
```

> **Image-pull timing (normal):** First-time pulls of
> `ghcr.io/coreweave/slurm-containers/*` images (~1 GiB each) take
> ~1 minute per pod. With 5-7 pods per node that compounds to 3-5
> minutes of `Init:ContainerCreating` on the first deploy; subsequent
> deploys reuse the cached layers and start in under a minute. Do not
> retry or delete pods during this window.

## Step 8: Patch System DaemonSets

Audit and patch every DaemonSet that runs on compute nodes:

```bash
# List all DaemonSets
kubectl get ds --all-namespaces

# Patch each one that needs to run on compute nodes
for ns_ds in "kube-system kube-proxy" "kube-system your-cni-daemonset" "kube-system nvidia-device-plugin"; do
  ns=$(echo $ns_ds | cut -d' ' -f1)
  ds=$(echo $ns_ds | cut -d' ' -f2)
  kubectl -n $ns patch daemonset $ds --type=json -p='[
    {"op": "add", "path": "/spec/template/spec/tolerations/-",
     "value": {"key": "sunk.coreweave.com/lock", "operator": "Exists", "effect": "NoExecute"}}
  ]' 2>/dev/null && echo "Patched $ns/$ds" || echo "Skipped $ns/$ds"
done
```

Also patch cert-manager and moco-controller as shown in the provider-specific skills.

## Bare-Metal Specific Features

### InfiniBand

If your nodes have InfiniBand, configure IB resources in compute values:

```yaml
compute:
  nodes:
    gpu-workers:
      resources:
        requests:
          rdma/rdma_shared_device_a: "1"
        limits:
          rdma/rdma_shared_device_a: "1"
```

Adjust IB device names and resource names to match your RDMA device plugin configuration.

### Topology Configuration

Build a `topology.conf` reflecting your actual network fabric:

```yaml
slurmConfig:
  TopologyPlugin: topology/tree
  TopologyParam: SwitchMaxLinks=256
```

Provide the topology.conf via ConfigMap or the chart's topology values.

### Enroot/Pyxis

If you have enroot installed and the seccomp profile available, enable Pyxis for container support:

```yaml
compute:
  pyxis:
    enabled: true
```

## Verification

Follow the same verification steps as managed provider deployments:

1. **All pods healthy**: `kubectl get pods -n tenant-slurm` and `kubectl get pods -n sunk`
2. **Slurm nodes idle**: `kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo`
3. **Job execution works**: `kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname`
4. **GPU jobs work** (if GPU nodes): `kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --gres=gpu:1 --mem=100 nvidia-smi`
5. **Shared filesystem works**: Write from login, read from compute via `srun`

## Next Steps

| Capability | Skill |
|------------|-------|
| **Helm upgrades** | `skills/universal/upgrade-sunk` |
| **User authentication** | `skills/universal/configure-sunk-user-auth` |
| **GPU monitoring** | `skills/universal/setup-sunk-gpu-monitoring` |
| **SkyPilot integration** | `skills/universal/connect-skypilot-to-sunk` |
