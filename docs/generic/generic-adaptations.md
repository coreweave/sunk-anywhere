# Generic / Bare-Metal Adaptations

**Validation in progress on bare-metal and self-managed Kubernetes.**

These are the settings and considerations specific to bare-metal or self-managed Kubernetes clusters.

## NVIDIA Device Plugin

Install the standard NVIDIA device plugin manually:

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm install nvidia-device-plugin nvdp/nvidia-device-plugin --namespace kube-system
```

Or enable it via the SUNK chart:

```yaml
nvidia-device-plugin:
  enabled: true
```

## StorageClass

Use your cluster's default StorageClass or create one for your storage backend (Ceph, NFS-provisioner, local-path, etc.):

```yaml
controller:
  stateVolume:
    storageClassName: ceph-block

moco:
  mysqlCluster:
    persistence:
      storageClassName: ceph-block

login:
  sshKeyVolume:
    storageClassName: ceph-block
```

## Lock Taint Patching

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

Common DaemonSets that need patching on bare-metal:

| DaemonSet | Typical namespace | Impact if evicted |
|-----------|-------------------|-------------------|
| Calico/Cilium CNI | kube-system | Pod networking breaks |
| kube-proxy | kube-system | Service routing breaks |
| CSI node drivers | kube-system | Volume attach/detach breaks |
| NVIDIA device plugin | kube-system | GPU resource advertising stops |

## InfiniBand

If your bare-metal nodes have InfiniBand, configure IB resources in your compute values:

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

## Topology Configuration

On bare-metal, you can build a `topology.conf` reflecting your actual network fabric:

```yaml
slurmConfig:
  TopologyPlugin: topology/tree
  TopologyParam: SwitchMaxLinks=256
```

Provide the topology.conf via ConfigMap or the chart's topology values.

## Shared Filesystem

**Dev/test:** In-cluster NFS server.

**Production:**
- **External NFS server** for general-purpose shared storage.
- **Weka** for high-performance storage (mount via s6 bootstrap scripts or Weka CSI driver).
- **Lustre** for high-throughput parallel workloads (mount via s6 scripts or Lustre CSI driver).

### Weka

Mount via s6 bootstrap scripts:

```yaml
login:
  s6:
    mount-weka:
      type: oneshot
      script: |
        #!/usr/bin/env bash
        mkdir -p /mnt/weka
        mount -t wekafs <weka-endpoint>/fs /mnt/weka

compute:
  nodes:
    gpu-workers:
      s6:
        mount-weka:
          type: oneshot
          script: |
            #!/usr/bin/env bash
            mkdir -p /mnt/weka
            mount -t wekafs <weka-endpoint>/fs /mnt/weka
```

Alternatively, use the Weka CSI driver with PersistentVolumeClaims.

When running the Weka client on compute nodes, reserve CPU cores so Slurm does not schedule jobs on them:

```yaml
slurmConfig:
  CPUSpecList: "0-3"  # Reserve cores 0-3 for system/Weka
```

### Lustre

**On-premises Lustre:** Mount via s6 scripts similar to the Weka example, using `mount -t lustre`.
