# SUNK Architecture

SUNK (Slurm on Kubernetes) runs each Slurm "node" as a Kubernetes pod, turning a Kubernetes cluster into a Slurm cluster. This document maps every component, explains where things land, and describes the lock taint mechanism.

## Component Map

SUNK is deployed via two Helm charts plus a handful of infrastructure manifests.

### Helm chart: `coreweave/sunk` (SUNK Operator)

| Component | Pod name pattern | Role |
|-----------|-----------------|------|
| SUNK Operator | `sunk-operator-*` | Watches SunkCluster CRDs, manages compute pod lifecycle, applies the lock taint to nodes running compute pods |
| Syncer | `sunk-syncer-*` | Bidirectional state sync between Slurm and Kubernetes. Exposes Prometheus metrics on `:8080/metrics` |
| Pod Scheduler | `sunk-scheduler-*` | Allows native Kubernetes pods to be scheduled through Slurm (set `schedulerName` on the pod spec) |

### Helm chart: `coreweave/slurm` (Slurm)

| Component | Pod name pattern | Role |
|-----------|-----------------|------|
| Controller | `slurm-controller-0` | Runs `slurmctld`. StatefulSet with a PVC for persistent state |
| Accounting | `slurm-accounting-*` | Runs `slurmdbd`. Connects to MySQL for job accounting |
| REST API | `slurm-rest-*` | Runs `slurmrestd`. HTTP API for programmatic job submission |
| Login | `slurm-login-0` | SSH entry point. Runs `sshd` plus Slurm client tools. Users land here |
| Compute (NodeSet) | `slurm-<nodeset>-<N>` | Runs `slurmd`. One pod per Slurm "node". Each is scheduled onto a Kubernetes node |
| Munge | sidecar in each pod | Shared-secret authentication between all Slurm daemons |
| Secret Job | `slurm-secret-job-*` | One-shot Job that generates JWT tokens and munge keys on first install |
| Cleanup Completing | `slurm-cleanup-*` | Job that cleans up after completing Slurm jobs |

### Infrastructure (not Helm-managed)

| Component | Manifest | Role |
|-----------|----------|------|
| NFS Server | `infrastructure/nfs-server.yaml` | In-cluster userspace NFS backed by a persistent volume. Provides shared `/home` across all pods |
| System Pod Toleration Patch | `infrastructure/patch-*-tolerations.sh` | Patches provider-managed system pods to survive the lock taint (see below) |
| OpenLDAP (optional) | `infrastructure/openldap.yaml` | Lightweight LDAP for multi-user identity. Feeds nsscache for UID/GID resolution |

### Dependencies (third-party)

| Component | Namespace | Role |
|-----------|-----------|------|
| cert-manager | `cert-manager` | TLS certificate management. Required by MOCO |
| MOCO | `moco-system` | MySQL operator. Manages the MySQL instance used by Slurm accounting (`slurmdbd`) |
| NVIDIA device plugin | `kube-system` | Exposes `nvidia.com/gpu` resources to the Kubernetes scheduler. Some providers install this automatically on GPU node pools; others require manual installation |

## Namespace Layout

```
kube-system          Provider system pods, NVIDIA device plugin
cert-manager         cert-manager controller, cainjector, webhook
moco-system          MOCO MySQL operator
sunk                 SUNK operator, syncer, pod scheduler
tenant-slurm         Everything Slurm: controller, login, compute, REST,
                     accounting, NFS server, MySQL instance, secret jobs
monitoring           DCGM Exporter, monitoring CRDs (optional)
```

All SUNK operator components live in `sunk`. All Slurm workload components live in `tenant-slurm`. This separation keeps operator-level concerns (CRD controllers, cluster-wide scheduling) isolated from the tenant workload.

## The Lock Taint

The lock taint is the single most important thing to understand about SUNK on shared infrastructure. On CoreWeave, compute nodes are dedicated, so it is invisible. On other providers with shared node pools, it breaks the cluster if you do not plan for it.

### What happens

When the SUNK operator schedules a compute pod onto a Kubernetes node, it applies a `NoExecute` taint:

```
sunk.coreweave.com/lock=true:NoExecute
```

`NoExecute` means every pod on that node that does not tolerate this taint gets evicted immediately. On shared node pools, that includes critical system pods (DNS, connectivity agents, certificate managers, metrics collectors, etc.). The exact pods affected depend on your provider. See the provider-specific adaptations docs for details.

### The fix (two parts)

**Part 1: Tolerate the taint in Helm values.** Every SUNK and Slurm pod must include:

```yaml
tolerations:
  - key: sunk.coreweave.com/lock
    operator: Exists
    effect: NoExecute
```

This applies to: operator, syncer, controller, accounting, REST, login, secret job, cleanup job, NFS server, and any other pod you deploy. The `helm-values/` files in this repo already include these tolerations.

**Part 2: Patch provider system pods.** Provider-managed system deployments and DaemonSets do not know about the SUNK taint. Run the appropriate patch script for your provider after compute pods join. Providers may revert these patches during cluster upgrades, so re-run the script if connectivity or DNS breaks after an upgrade.

### Lock taint lifecycle

1. Compute pod gets scheduled onto a Kubernetes node.
2. SUNK operator applies `sunk.coreweave.com/lock=true:NoExecute` to that node.
3. Any pod without a matching toleration is evicted.
4. When the Slurm job completes and the compute pod is removed, the taint is removed.

## Data Flow

```
User
  |
  | SSH
  v
Login Pod (slurm-login-0)
  |
  | Slurm RPC
  v
Controller Pod (slurm-controller-0)  <-->  Accounting Pod (slurmdbd)  <-->  MySQL (MOCO)
  |
  | Slurm RPC
  v
Compute Pods (slurm-<nodeset>-N)  <-->  NFS Server (shared /home)
  ^
  |
SUNK Operator (applies lock taint, manages pod lifecycle)
  |
Syncer (bidirectional Slurm <-> K8s state sync)
```

## Storage

| Volume | Type | Mount | Purpose |
|--------|------|-------|---------|
| Shared home | NFS (in-cluster server or managed NFS) | `/home` on all pods | User home directories, job scripts, shared data |
| Controller state | PVC (provider StorageClass) | Controller pod | Persistent Slurm state across restarts |
| MySQL data | PVC (provider StorageClass) | MOCO MySQL pod | Slurm accounting database |
| SSH keys | PVC (provider StorageClass) | Login pod | Host keys for consistent SSH fingerprints |

The in-cluster NFS server bridges the `ReadWriteOnce` limitation of most block storage by exposing a single persistent volume as a network filesystem accessible by all pods. For production, use a managed NFS service (Google Filestore, Amazon EFS) or a customer-provided parallel filesystem (Weka, Lustre) instead of the in-cluster NFS server.
