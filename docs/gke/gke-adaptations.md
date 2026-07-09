# GKE Adaptations

These are the settings that differ from a CoreWeave deployment when running SUNK on GKE. Each has a reason tied to GKE infrastructure.

## Helm Value Overrides

| Setting | Chart default | GKE override | Why |
|---------|--------------|--------------|-----|
| `global.cks` | `true` | `false` | Pull images from public GHCR instead of CoreWeave's internal registry |
| `nvidia-device-plugin.enabled` | `true` | `false` | GKE auto-installs its own NVIDIA device plugin on GPU node pools |
| `sunkDevicePlugin.enabled` | `true` | `false` | The SUNK device plugin is a CoreWeave fork with custom resource naming that conflicts with GKE's plugin |
| `sunkScheduler.enabled` | `true` | `false` | Depends on the SUNK device plugin |
| `autoPartition.enabled` | `true` | `false` | Depends on CoreWeave infrastructure |
| `compute.reservedMemory` | `"4Gi"` | `"0"` | Subtracting 4 GiB from small GKE nodes makes `DefMemPerCPU` go negative, so jobs get rejected |
| `compute.pyxis.enabled` | `true` | `true` (with overrides) | Kept on. See the "Pyxis on COS" row below for the AppArmor workaround |
| `compute.pyxis.appArmorProfile` | `localhost/enroot` | `unconfined` | COS enforces AppArmor but ships no `enroot` profile; installing one via nsenter DaemonSet is fragile on COS. Customers run with `unconfined` in the field; combined with the already-privileged slurmd this adds no meaningful risk |
| `compute.pyxis.plugstackOptions` | (unset) | `[container_scope=job]` | One enroot container reused across all srun steps in a job. Faster, and matches what customers use in production |
| `compute.pyxis.enrootConfig` | (unset) | per-user paths under `/var/tmp`, `ENROOT_TEMP_PATH=/enroot` | Keeps per-user cache/data from colliding; moves the TEMP path off container rootfs |
| `compute.s6.enroot-dirs` | (unset) | oneshot `mkdir -p` with mode 1777 | Creates the enroot parent dirs on pod start; without it, the first `--container-image` job fails with "No such file or directory" |
| seccomp-installer DaemonSet | (must be applied pre-install) | applied | Universal DS at `infrastructure/universal/seccomp-installer-daemonset.yaml` installs `/var/lib/kubelet/seccomp/profiles/enroot` on every node; COS's `/var/lib/kubelet` is writable so this works unchanged |
| `compute.securityContext.privileged` | `false` | `true` | Required for cgroup management. Without it, `slurmd` fails with "cgroup mountpoint does not align" |
| `compute.nodes.*.enabled` | `false` | `true` | Chart defaults all node groups to disabled |
| `compute.nodes.*.tolerations` | CoreWeave defaults | `[]` | Empty array prevents inheriting CoreWeave-specific tolerations that do not exist on GKE |
| `slurmConfig.DefMemPerCPU` | `4096` | `100` (dev) | Must fit within the node's available memory per CPU. See DefMemPerCPU formula below |
| `login.service.externalTrafficPolicy` | `"Local"` | `""` | `"Local"` is invalid for ClusterIP services and causes a Kubernetes validation error |
| `controller.stateVolume.storageClassName` | (none) | `premium-rwo` | GKE has no default StorageClass matching CoreWeave's expectations. Without this, PVCs stay Pending |
| `moco.enabled` (sunk chart) | `true` | `false` | MOCO is installed separately to avoid version conflicts |
| Monitoring CRDs (`podMonitor`, `vmPodScrape`) | `true` | `false` | GKE does not ship Prometheus Operator or VictoriaMetrics. Leaving these enabled causes CRD-not-found errors |
| Operator/syncer resources | 8 CPU / 32 Gi | 250m / 256Mi | Chart defaults are sized for CoreWeave production nodes. They do not fit on e2-standard-4 |

## Node Label Mapping

| CoreWeave label | GKE equivalent |
|-----------------|----------------|
| `node.coreweave.cloud/class: cpu` | `cloud.google.com/gke-nodepool: <cpu-pool>` |
| `node.coreweave.cloud/class: gpu` | `cloud.google.com/gke-nodepool: <gpu-pool>` |

## GPU Driver Workaround

GKE mounts NVIDIA drivers at `/usr/local/nvidia` after container startup, leaving the `ldconfig` cache stale. Without a fix, `slurmd` fails with `libnvidia-ml.so.1: cannot open shared object file`.

The workaround is an s6 oneshot script in the Slurm values that runs `ldconfig` at boot:

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

## DefMemPerCPU Formula

```
DefMemPerCPU = (node_allocatable_memory_MB - reservedMemory_MB) / cpus_available_to_slurm
```

| Machine type | Allocatable RAM | vCPUs | Recommended DefMemPerCPU |
|-------------|----------------|-------|--------------------------|
| e2-standard-4 | ~15,000 MB | 4 | 100 (conservative, for dev) |
| e2-standard-8 | ~30,000 MB | 8 | 3000-3800 |
| e2-standard-16 | ~62,000 MB | 16 | 3800-4000 |
| n2-standard-32+ | 125,000+ MB | 32+ | 4096 (chart default is fine) |

## GKE-Specific Constraints

**GKE Standard only.** Autopilot is not supported. SUNK requires privileged pods, hostNetwork, custom DaemonSets, and fine-grained node pool control that Autopilot does not allow.

**NFS image compatibility.** Only `itsthenetwork/nfs-server-alpine:12` works on GKE's Container-Optimized OS nodes. Kernel-based NFS servers fail because COS does not load the NFS kernel module. The registry.k8s.io NFS image fails because its Docker manifest v1 format is rejected by containerd v2.1.

**System pod patches are not durable.** GKE can revert toleration patches during cluster upgrades. Monitor for broken `kubectl exec` or DNS after upgrades and re-run `infrastructure/patch-gke-tolerations.sh`.

**Syncer/scheduler startup delay.** After `helm install`, syncer and scheduler pods show `CreateContainerConfigError` for 2-3 minutes. This is normal. The secret job must generate JWT tokens first, which requires the controller to be fully running. Do not delete or restart these pods during this window.

**GKE GPU driver path.** GKE mounts NVIDIA drivers at `/home/kubernetes/bin/nvidia` for DaemonSets like dcgm-exporter, and `/usr/local/nvidia` for compute pods. The ldconfig cache is stale at container startup. The s6 ldconfig workaround is mandatory.

**GCM port collision.** GKE runs its own Node Problem Detector on ports 20256/20257. The GCM health check port must be shifted (default: 20357) to avoid collisions.
