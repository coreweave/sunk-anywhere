# Bare-Metal / Generic Kubernetes Deployment Guide

**Validation in progress on bare-metal and self-managed Kubernetes.**

End-to-end guide for deploying SUNK (Slurm on Kubernetes) on any Kubernetes cluster without its own track here: bare-metal, self-managed, or another managed cloud. For architecture details, see [../universal/architecture.md](../universal/architecture.md). For provider-specific adaptations, see [generic-adaptations.md](generic-adaptations.md).

---

## Prerequisites

### Tools

- **kubectl**
- **Helm 3**
- A running Kubernetes cluster (kubeadm, Rancher, or your preferred installer), version 1.28+

The SUNK and Slurm charts are licensed. Reach out to CoreWeave at
<sunk@coreweave.com> for access instructions, then substitute the repository
URL you receive for `<COREWEAVE_HELM_REPO_URL>` below.

```bash
helm repo add coreweave <COREWEAVE_HELM_REPO_URL>
helm repo add jetstack https://charts.jetstack.io
helm repo add moco https://cybozu-go.github.io/moco/
helm repo update
```

### Cluster Requirements

- All nodes running the same Kubernetes version (1.28+)
- NVIDIA GPU drivers installed on GPU nodes
- NVIDIA container toolkit configured
- A StorageClass available for PVCs (Ceph, NFS-provisioner, local-path, etc.)

---

## Step 1: Install the NVIDIA Device Plugin

On bare-metal, you manage the NVIDIA device plugin yourself.

Install the standard NVIDIA device plugin:

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm install nvidia-device-plugin nvdp/nvidia-device-plugin --namespace kube-system
```

Or enable it via the SUNK chart:

```yaml
nvidia-device-plugin:
  enabled: true
```

---

## Step 2: Create Namespaces and Install Dependencies

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
```

### MOCO MySQL Operator

```bash
helm install moco moco/moco --namespace moco-system
```

---

## Step 3: Deploy Shared Storage

Slurm requires a shared `/home` filesystem. Options for bare-metal:

**Dev/test:** In-cluster NFS server (see `infrastructure/nfs-server.yaml`).

**Production:** External NFS server, Weka, or Lustre.

For the in-cluster NFS server:

```bash
kubectl apply -f infrastructure/nfs-server.yaml
kubectl wait --for=condition=available deployment/nfs-server \
  -n tenant-slurm --timeout=120s
```

---

## Step 4: Deploy the SUNK Operator

Configure `helm-values/sunk-values.yaml`:

- Enable or disable the NVIDIA device plugin based on your setup
- Adjust resource requests for your node sizes
- Disable monitoring CRDs if not running Prometheus Operator
- Disable MOCO (installed separately)

```bash
helm upgrade --install sunk coreweave/sunk \
  -f helm-values/sunk-values.yaml -n sunk
```

---

## Step 5: Deploy the Slurm Chart

Configure `helm-values/slurm-values.yaml`. Key settings:

- `global.cks: false`
- `controller.stateVolume.storageClassName: <your-storage-class>`
- Node selectors using your cluster's node labels
- Lock taint tolerations on all components
- `compute.securityContext.privileged: true`

```bash
helm upgrade --install slurm coreweave/slurm \
  -f helm-values/slurm-values.yaml \
  -n tenant-slurm
```

---

## Step 6: Patch System DaemonSets

On bare-metal you control all DaemonSets. Audit every DaemonSet running on compute nodes and add the lock taint toleration:

```bash
# List all DaemonSets that could land on GPU/compute nodes
kubectl get ds --all-namespaces -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name

# Patch each one that runs on compute nodes
kubectl -n <namespace> patch daemonset <name> --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/tolerations/-",
   "value": {"key": "sunk.coreweave.com/lock", "operator": "Exists", "effect": "NoExecute"}}
]'
```

---

## Step 7: Verify the Deployment

```bash
kubectl get pods -n tenant-slurm
kubectl get pods -n sunk
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname
```

---

## See Also

- [Generic Adaptations](generic-adaptations.md)
- [Architecture](../universal/architecture.md)
- [Helm Values Reference](../universal/helm-values-reference.md)
- [General Troubleshooting](../universal/troubleshooting.md)
