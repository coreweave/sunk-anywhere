# Helm Values Reference

> **Note:** Provider-specific values (storage classes, node labels, node affinity, GPU driver paths) are documented in each provider's deployment guide and adaptations doc. This reference covers the universal settings.

This document annotates every setting in the three values files under `helm-values/` and explains why each differs from the chart defaults. Customization recipes at the end cover the most common changes.

## Files Overview

| File | Chart | Namespace | Purpose |
|------|-------|-----------|---------|
| `sunk-values.yaml` | `coreweave/sunk` | `sunk` | SUNK operator, syncer, pod scheduler |
| `slurm-values.yaml` | `coreweave/slurm` | `tenant-slurm` | Slurm controller, accounting, login, compute, REST API, nsscache |
| `gcm-values.yaml` | `coreweave/gcm` | `tenant-slurm` | GPU health checks via GCM (GPU Cluster Monitoring) |

Install order matters: `sunk` first, then `slurm`, then `gcm`. The SUNK operator must be running before the Slurm chart installs compute pods.

---

## sunk-values.yaml (SUNK Operator)

### nvidia-device-plugin

```yaml
nvidia-device-plugin:
  enabled: false
```

Most managed Kubernetes providers auto-install their own NVIDIA device plugin on GPU node pools. The chart-bundled plugin conflicts with it (duplicate `nvidia.com/gpu` resources). On bare-metal, you may want to enable this or install the plugin separately.

### operator

```yaml
operator:
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      memory: 1Gi
```

Chart defaults (8 CPU / 32 Gi) are sized for CoreWeave production nodes. Adjust these to fit your node sizes.

```yaml
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
```

The lock taint. Without this, the operator pod gets evicted when compute pods join a shared node. See [architecture.md](architecture.md#the-lock-taint) for the full explanation.

```yaml
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: <provider-node-pool-label>
                operator: In
                values:
                  - <cpu-pool-name>
```

Pins the operator to the CPU node pool. Update the label key and value to match your provider's node pool labeling convention.

```yaml
  podMonitor:
    enabled: false
  vmPodScrape:
    enabled: false
```

Disable these if your cluster does not have Prometheus Operator or VictoriaMetrics Operator CRDs installed. Leaving them enabled produces `CRD not found` errors during install.

### syncer

```yaml
syncer:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 512Mi
  podMonitor:
    enabled: false
  vmPodScrape:
    enabled: false
```

Same reasoning as operator: reduced resources for smaller nodes, monitoring CRDs disabled if not available.

### scheduler

```yaml
scheduler:
  podMonitor:
    enabled: false
  vmPodScrape:
    enabled: false
```

Monitoring CRDs disabled. The scheduler's other settings are configured in the Slurm chart.

### moco

```yaml
moco:
  enabled: false
```

MOCO is installed as a standalone chart before SUNK. Disabling it here avoids duplicate MOCO installations with potential version conflicts.

---

## slurm-values.yaml (Slurm Chart)

This is the largest values file. It configures every Slurm daemon, compute nodes, networking, storage, and user provisioning.

### global

```yaml
global:
  cks: false
```

**Required for non-CoreWeave deployments.** Controls which container registry images are pulled from. When `false`, all images use their `repository` field (public GHCR). When `true`, images are pulled from CoreWeave's internal registry.

```yaml
  volumes:
    - name: shared-home
      nfs:
        server: nfs-server.tenant-slurm.svc.cluster.local
        path: /
  volumeMounts:
    - name: shared-home
      mountPath: /home
```

Mounts the in-cluster NFS server as `/home` on every Slurm pod (controller, login, compute). All user data, job scripts, and output land here.

### clusterName

```yaml
clusterName: "my-sunk-cluster"
```

Identifies this Slurm cluster in accounting records and metrics labels. Change this to something meaningful for your environment.

### controller

```yaml
controller:
  image:
    repository: ghcr.io/coreweave/slurm-containers/controller
    tag: v25.05.3-coreweave.5-ubuntu22.04
```

The Slurm controller daemon (`slurmctld`). Runs as a StatefulSet with one replica.

```yaml
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      memory: 2Gi
```

The controller is the most resource-intensive control plane component. For clusters with more than a few hundred jobs in flight, increase the memory limit.

```yaml
  stateVolume:
    storageClassName: <provider-storage-class>
    size: 5Gi
```

Persistent volume for Slurm state (job queue, node state). Set `storageClassName` to a valid StorageClass for your provider. Without an explicit StorageClass, the PVC may stay Pending.

```yaml
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: <provider-node-pool-label>
                operator: In
                values:
                  - <cpu-pool-name>
```

Lock taint toleration and node pool affinity. This pattern repeats for every control plane component. The following all carry the same lock taint toleration and CPU node pool affinity (omitted from code blocks below for brevity): `rest`, `accounting`, `login`, `scheduler`, `syncer`, `secretJob`, `cleanupCompleting`, `nsscache`, and `moco`.

### rest

```yaml
rest:
  image:
    repository: ghcr.io/coreweave/slurm-containers/controller
    tag: v25.05.3-coreweave.5-ubuntu22.04
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi
```

The Slurm REST API (`slurmrestd`). Uses the same image as the controller. Lower resource requirements because it proxies requests to `slurmctld`. Also carries lock taint toleration (see controller section above).

### accounting

```yaml
accounting:
  image:
    repository: ghcr.io/coreweave/slurm-containers/controller
    tag: v25.05.3-coreweave.5-ubuntu22.04
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi
```

The Slurm accounting daemon (`slurmdbd`). Connects to the MOCO MySQL instance. Same image as controller. Carries lock taint toleration and CPU node pool affinity.

### login

```yaml
login:
  image:
    repository: ghcr.io/coreweave/slurm-containers/controller-extras
    tag: v25.05.3-coreweave.5-ubuntu22.04
  replicas: 1
```

The login node. Uses the `controller-extras` image, which bundles SSH, Slurm client tools, and user-facing utilities. Resources are set to 250m CPU / 512Mi-1Gi memory. Carries lock taint toleration and CPU node pool affinity like all control plane components.

```yaml
  service:
    type: ClusterIP
    externalTrafficPolicy: ""
```

The chart default sets `externalTrafficPolicy: "Local"`, which is invalid for `ClusterIP` services and causes a Kubernetes API validation error. Setting it to empty string clears the field.

To expose login externally, change `type` to `LoadBalancer` and set `externalTrafficPolicy: "Local"`. See your provider's adaptations doc for load balancer annotations.

```yaml
  sshKeyVolume:
    storageClassName: <provider-storage-class>
    size: 1Gi
    accessModes:
      - ReadWriteOnce
```

Persists SSH host keys so the login node keeps the same fingerprint across restarts.

```yaml
  loginController:
    podMonitor:
      enabled: false
    vmPodScrape:
      enabled: false
  directoryCache:
    podMonitor:
      enabled: false
    vmPodScrape:
      enabled: false
```

Monitoring CRDs disabled (enable if you have Prometheus/VictoriaMetrics operator installed).

### compute

The compute section configures Slurm worker nodes. Each entry under `compute.nodes` becomes a Slurm partition (NodeSet).

#### Top-level compute settings

```yaml
compute:
  reservedMemory: "0"
```

Memory reserved from Slurm's perspective. Chart default is `"4Gi"`. On small nodes, subtracting 4 Gi makes `DefMemPerCPU` go negative, causing every job to be rejected with "Requested node configuration is not available."

```yaml
  cacheDropper:
    enabled: false
```

The cache-dropper sidecar periodically drops OS page caches to improve job isolation. Not needed for development environments.

```yaml
  pyxis:
    enabled: false
```

Pyxis/Enroot enables running containers inside Slurm jobs. Requires a seccomp profile (`profiles/enroot`) that may not exist on managed Kubernetes nodes.

```yaml
  securityContext:
    privileged: true
```

Required for cgroup management on most managed Kubernetes providers. Without this, `slurmd` fails with "cgroup mountpoint does not align with cgroup root" because the cgroup hierarchy differs from what the container expects.

#### GPU driver workaround (s6 oneshot)

```yaml
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

Some providers mount NVIDIA drivers after container startup, leaving the `ldconfig` cache stale. Without this script, `slurmd` fails with `libnvidia-ml.so.1: cannot open shared object file` and GPU jobs fail because `nvidia-smi` is not on `PATH`. Adjust the path (`/usr/local/nvidia`) if your provider mounts drivers elsewhere.

The script runs once at container boot via the s6 init system, before `slurmd` starts.

#### Node groups

```yaml
  nodes:
    cpu-workers:
      enabled: true
      image:
        repository: ghcr.io/coreweave/slurm-containers/controller-extras
        tag: v25.05.3-coreweave.5-ubuntu22.04
      replicas: 2
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
        limits:
          memory: 512Mi
      nodeSelector:
        <provider-node-pool-label>: <cpu-pool-name>
      tolerations: []
```

CPU compute nodes. `tolerations: []` is intentional: it clears the chart's default tolerations (CoreWeave-specific) that do not exist on non-CoreWeave clusters. Both `nodeSelector` and a matching `nodeAffinity` pin pods to the CPU pool (the affinity block is omitted here for brevity but present in the values file).

Each replica becomes a Slurm node (e.g., `slurm-cpu-workers-0`, `slurm-cpu-workers-1`). The node's resources are constrained by the container limits, not the underlying VM.

```yaml
    gpu-workers:
      enabled: true
      replicas: 1
      gresGpu: "l4:1"
      env:
        - name: LD_LIBRARY_PATH
          value: "/usr/local/nvidia/lib64"
        - name: PATH
          value: "/usr/local/nvidia/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
          nvidia.com/gpu: "1"
        limits:
          memory: 512Mi
          nvidia.com/gpu: "1"
      nodeSelector:
        <provider-node-pool-label>: <gpu-pool-name>
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
```

GPU compute nodes. Uses the same `controller-extras` image as CPU workers (omitted for brevity). Key differences from CPU nodes:

- `gresGpu: "l4:1"` registers one L4 GPU as a Slurm GRES resource. Change the type and count to match your hardware (e.g., `h100:8`).
- `nvidia.com/gpu: "1"` in resource requests/limits ensures the Kubernetes scheduler places the pod on a GPU node and assigns it one GPU.
- `LD_LIBRARY_PATH` and `PATH` env vars supplement the s6 oneshot script by making NVIDIA tools available to user jobs. Adjust the path if your provider mounts drivers elsewhere.
- The `nvidia.com/gpu` toleration allows scheduling onto GPU nodes that carry this taint by default.
- `nodeSelector` and `nodeAffinity` (omitted for brevity) pin pods to the GPU pool.

### moco (in Slurm chart)

```yaml
moco:
  enabled: true
  mysqlCluster:
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        memory: 1Gi
    persistence:
      storageClassName: <provider-storage-class>
      size: 5Gi
```

MOCO MySQL instance for Slurm accounting. Uses the same StorageClass as the controller state volume. Resource requests are reduced for smaller node sizes. Carries CPU node pool affinity to keep the database on CPU nodes.

### mysql (legacy)

```yaml
mysql:
  enabled: false
```

Disables the legacy Bitnami MySQL sub-chart. MOCO replaces it.

### Disabled CoreWeave features

```yaml
autoPartition:
  enabled: false

cacheDropper:
  enabled: false

sunkDevicePlugin:
  enabled: false

sunkScheduler:
  enabled: false
```

| Feature | Why disabled |
|---------|-------------|
| `autoPartition` | Auto-creates Slurm partitions from node labels. Depends on CoreWeave infrastructure |
| `cacheDropper` | Top-level toggle. Same as `compute.cacheDropper` |
| `sunkDevicePlugin` | CoreWeave's fork of the NVIDIA device plugin. Conflicts with most provider-installed plugins |
| `sunkScheduler` | Depends on the SUNK device plugin |

### scheduler (pod scheduler)

```yaml
scheduler:
  enabled: true
  priorityClassName: ""
  scope:
    type: namespace
    namespaces: []
  config:
    slurm:
      poolSize: 5
      usePersistentConnection: true
      protocolVersion: "24_11"
    scheduler:
      gpuTypes:
        NVIDIA_L4: l4
      pollInterval: 10s
      terminationOffset: 5s
```

The SUNK pod scheduler lets native Kubernetes pods be scheduled through Slurm (set `schedulerName: sunk-scheduler` on the pod spec). Resources are 100m CPU / 256Mi-512Mi memory. Carries lock taint toleration and CPU pool affinity.

- `scope.type: namespace` limits it to pods in specific namespaces. Empty `namespaces` list means the scheduler watches the release namespace only.
- `config.slurm.protocolVersion: "24_11"` must match the Slurm version. For Slurm 25.05.x, use `"24_11"`.
- `config.scheduler.gpuTypes` maps Kubernetes GPU resource names to Slurm GRES types. Add entries for each GPU type in your cluster.

### syncer

```yaml
syncer:
  enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi
```

Bidirectional state sync between Slurm and Kubernetes. Reports Slurm node/job state as Kubernetes CRD status fields.

**Must be `enabled: true` for metrics export.** The syncer is the only component that exposes Prometheus metrics (port 8080) for Slurm cluster state. If disabled, no Slurm metrics flow to your monitoring stack, and dashboards will be empty. Keep this enabled unless you have a specific reason to disable it.

### secretJob / cleanupCompleting

```yaml
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
```

One-shot Kubernetes Jobs that run during install and job cleanup. Both need the lock taint toleration to run on shared nodes.

### nsscache

```yaml
nsscache:
  enabled: true
  existingSecret: nsscache-ldap-credentials
  cronJobSchedule: "* * * * *"
  sudoGroups:
    - slurm-admins
```

LDAP-backed user provisioning. Runs as a CronJob every minute, pulling POSIX users/groups from OpenLDAP and writing them to `/etc/nsscache` inside every Slurm pod. Resources are 50m CPU / 64Mi-256Mi memory. Carries lock taint toleration.

- `existingSecret` references a pre-created Kubernetes Secret with the LDAP bind password.
- `sudoGroups` lists LDAP groups whose members get password-less `sudo` on all Slurm pods.

```yaml
  nsscacheConfig:
    default:
      source: ldap
      cache: files
      maps:
        - passwd
        - shadow
        - group
      timestamp_dir: /var/lib/nsscache
      ldap_uri: "ldap://openldap.tenant-slurm.svc.cluster.local:389"
      ldap_base: "dc=sunk,dc=local"
      ldap_bind_dn: "cn=readonly,dc=sunk,dc=local"
      ldap_rfc2307bis: 0
      ldap_default_shell: "/bin/bash"
      ldap_scope: sub
      files_dir: /etc/nsscache
      files_cache_filename_suffix: cache
    passwd:
      ldap_filter: "(objectClass=posixAccount)"
    group:
      ldap_filter: "(objectClass=posixGroup)"
    shadow:
      ldap_filter: "(objectClass=shadowAccount)"
  nsswitchConfig:
    passwd:
      - files
      - cache
    group:
      - files
      - cache
    shadow: []
```

Points at the in-cluster OpenLDAP instance deployed via `infrastructure/openldap.yaml`. Key settings:

- `cache: files` and `files_dir: /etc/nsscache` write cached passwd/group/shadow data to flat files, which nsswitch reads via the `cache` source.
- `maps` controls which POSIX databases are synced. `passwd`, `group`, and `shadow` cover user accounts, groups, and password aging.
- `ldap_rfc2307bis: 0` uses classic RFC 2307 schema (not bis). Set to `1` if your LDAP uses `groupOfUniqueNames` instead of `posixGroup` with `memberUid`.
- `ldap_scope: sub` searches the entire subtree under `ldap_base`.
- Per-map `ldap_filter` sections narrow the LDAP query for each database.
- `nsswitchConfig` controls `/etc/nsswitch.conf` inside pods. `files` is checked first (local accounts), then `cache` (LDAP-sourced data). `shadow: []` means shadow lookups fall back to system defaults.

If using a different identity provider, update the `ldap_*` fields.

### munge

```yaml
munge:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi
```

Munge runs as a sidecar in every Slurm pod, providing shared-secret authentication between daemons. Reduced resources for smaller nodes.

### slurmConfig

```yaml
slurmConfig:
  DefMemPerCPU: 100
```

Overrides the chart default of 4096 MB. On small nodes, the math may not work out. See your provider's deployment guide for the DefMemPerCPU formula and recommended values by machine type.

---

## gcm-values.yaml (GPU Cluster Monitoring)

GCM provides GPU health checks that validate GPU functionality beyond what `nvidia-smi` reports.

```yaml
healthChecks:
  enabled: true
  cluster: my-sunk-cluster
  gpuCount: 1
```

- `cluster` must match `clusterName` in slurm-values.yaml. Labels health check metrics with this cluster name.
- `gpuCount` is the number of GPUs per node in the GPU pool. Set to match the GPU count in your `gresGpu` value.

```yaml
  prometheus:
    port: 20357
```

Some providers run their own Node Problem Detector on default ports. This shifts the GCM port to avoid collisions.

```yaml
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
    - key: sunk.coreweave.com/lock
      operator: Equal
      value: "true"
      effect: NoExecute
```

Two tolerations: one for GPU node taints, one for the SUNK lock taint. Both are needed because GCM runs as a DaemonSet on GPU nodes.

```yaml
monitoring:
  enabled: false
```

Disables the k8s exporter sidecar (which uses `--port=0`) to avoid port conflicts with provider Node Problem Detectors.

### Post-install patch

Some providers require a post-install patch to mount NVIDIA libraries at non-standard paths. See your provider's adaptations doc for details.

---

## Customization Recipes

### Change the cluster name

Update in two places:

```yaml
# slurm-values.yaml
clusterName: "production-slurm"

# gcm-values.yaml
healthChecks:
  cluster: production-slurm
```

### Scale compute nodes

Change `replicas` under the node group. Each replica is one Slurm node.

```yaml
# slurm-values.yaml
compute:
  nodes:
    cpu-workers:
      replicas: 10    # was 2
    gpu-workers:
      replicas: 4     # was 1
```

When scaling GPU workers, ensure your cluster has enough GPU nodes and your cloud account has sufficient GPU quota.

### Use a different GPU type

Three changes needed:

```yaml
# slurm-values.yaml
compute:
  nodes:
    gpu-workers:
      gresGpu: "h100:8"              # was "l4:1"
      resources:
        requests:
          nvidia.com/gpu: "8"        # was "1"
        limits:
          nvidia.com/gpu: "8"        # was "1"
      nodeSelector:
        <provider-node-pool-label>: <gpu-pool-name>

# Also update the pod scheduler GPU type map:
scheduler:
  config:
    scheduler:
      gpuTypes:
        NVIDIA_H100: h100            # was NVIDIA_L4: l4

# gcm-values.yaml
healthChecks:
  gpuCount: 8                        # was 1
```

### Use a managed NFS service

For production, replace the in-cluster NFS with a managed service.

1. Create the managed NFS instance in the same VPC/region as your Kubernetes cluster.
2. Update `global.volumes` and `global.volumeMounts` in slurm-values.yaml:

```yaml
global:
  volumes:
    - name: shared-home
      nfs:
        server: <NFS_IP_OR_HOSTNAME>
        path: <SHARE_PATH>
  volumeMounts:
    - name: shared-home
      mountPath: /home
```

3. Skip deploying `infrastructure/nfs-server.yaml`.

### Expose login via LoadBalancer

```yaml
# slurm-values.yaml
login:
  service:
    type: LoadBalancer
    externalTrafficPolicy: "Local"
```

Add provider-specific load balancer annotations as needed. See your provider's adaptations doc.

After install, get the external IP:

```bash
kubectl get svc -n tenant-slurm slurm-login -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Then SSH in:

```bash
ssh -p 22 <username>@<EXTERNAL_IP>
```

### Increase login replicas

```yaml
# slurm-values.yaml
login:
  replicas: 3    # was 1
```

When using multiple replicas, the login service load-balances SSH connections across all replicas. All share the same `/home` via NFS.

### Set production-appropriate DefMemPerCPU

Calculate based on your node type:

```
DefMemPerCPU = (allocatable_memory_MB - reservedMemory_MB) / cpus
```

Example for a node with 128 Gi allocatable memory and 32 vCPUs:

```yaml
# slurm-values.yaml
compute:
  reservedMemory: "4Gi"        # restore chart default for production
slurmConfig:
  DefMemPerCPU: 3800           # (128000 - 4096) / 32 = 3872, round down
```

### Add a new node group (partition)

Add a new entry under `compute.nodes`:

```yaml
# slurm-values.yaml
compute:
  nodes:
    cpu-workers:
      # ... existing ...
    gpu-workers:
      # ... existing ...
    highmem-workers:
      enabled: true
      image:
        repository: ghcr.io/coreweave/slurm-containers/controller-extras
        tag: v25.05.3-coreweave.5-ubuntu22.04
      replicas: 2
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
        limits:
          memory: 1Gi
      nodeSelector:
        <provider-node-pool-label>: <highmem-pool-name>
      tolerations: []
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: <provider-node-pool-label>
                    operator: In
                    values:
                      - <highmem-pool-name>
```

Then create the matching node pool in your provider.

### Disable user provisioning (nsscache/LDAP)

If managing users manually or via a different mechanism:

```yaml
# slurm-values.yaml
nsscache:
  enabled: false
```

You will need to add users manually inside the login and compute pods, or mount an alternative identity source.

### Use an external MySQL database

Replace MOCO with an external MySQL (e.g., managed cloud MySQL):

```yaml
# slurm-values.yaml
moco:
  enabled: false
mysql:
  enabled: false

# sunk-values.yaml
moco:
  enabled: false
```

Then configure the accounting database connection in `slurmConfig` or via Slurm's `slurmdbd.conf` override. Refer to the Slurm chart documentation for the exact fields.

### Enable monitoring with Prometheus Operator

If you install Prometheus Operator or VictoriaMetrics on your cluster, re-enable the monitoring CRDs:

```yaml
# sunk-values.yaml
operator:
  podMonitor:
    enabled: true
  vmPodScrape:
    enabled: true
syncer:
  podMonitor:
    enabled: true

# slurm-values.yaml
login:
  loginController:
    podMonitor:
      enabled: true
  directoryCache:
    podMonitor:
      enabled: true
```
