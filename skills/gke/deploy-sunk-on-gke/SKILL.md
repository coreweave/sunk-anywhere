---
name: deploy-sunk-on-gke
description: >
  Deploy SUNK (Slurm on Kubernetes) on Google Kubernetes Engine from scratch.
  Covers GKE cluster creation, NFS shared filesystem, MOCO MySQL, SUNK operator,
  Slurm chart with all GKE-specific adaptations, lock taint handling, and system
  pod patching. Use when asked to "deploy SUNK on GKE", "set up Slurm on GKE",
  "create a SUNK cluster on Google Cloud", or "install SUNK on a GKE cluster".
---

# Deploy SUNK on GKE

Deploy SUNK (Slurm on Kubernetes) on Google Kubernetes Engine. This skill covers the full initial deployment from a bare GCP project to a working Slurm cluster. Node pool names, machine types, and resource sizes are examples; adjust them for the target environment.

## Optional features — confirm each with the user before any cluster work

**Instruction to the agent (any harness — Claude Code, Codex, Cursor, plain
chat agent):** Read this list to the user and capture a yes/no per item
**before** running any deployment commands. Ask in chat if your harness has
no structured-input tool. Defaults are the recommended demo posture — the
user opts out explicitly.

1. **GPU compute** — opt-in node pool via `skills/gke/add-gpu-nodes-to-gke` (run after Step 11). Default: OFF.
2. **Cloud Monitoring dashboards** — "SUNK: Cluster Overview" + "SUNK: Job Metrics" in GCP console. Default: ON. Opt out: "skip monitoring".
3. **DCGM exporter + Slurm syncer scrape** — GPU + Slurm metrics into Cloud Monitoring (drives the dashboards above). Default: ON. Opt out: "skip gpu monitoring".
4. **Default local user + SSH key** — caller's SSH key, slurmdbd association so `sbatch` works immediately. Default: ON. Opt out: "skip user provisioning".
5. **Shared `/home` backend** — in-cluster NFS pod (default, single-AZ, demo). For production, swap to Filestore manually.
6. **Layer-on later (opt-in only)** — LDAP multi-user via `configure-sunk-user-auth` (OpenLDAP) or `configure-sunk-authentik-sssd`; SkyPilot via `connect-skypilot-to-sunk`.

## Scope: what this skill deploys (opt-out contract)

When the user says "deploy SUNK on GKE", run **every numbered step in this
skill** unless the user explicitly opts out of one. Do not stop after Step 7
just because compute nodes are healthy — the README's "What Gets Deployed"
list (dashboards, DCGM exporter + scrapes, default user) is part of the
contract and only ships if the corresponding step runs.

| Step       | Deliverable                                  | Skip flag from user (verbatim)   | Default |
|------------|----------------------------------------------|----------------------------------|---------|
| 1          | GKE Standard cluster                         | n/a (required)                   | always  |
| 2          | Namespaces, cert-manager, MOCO               | n/a (required)                   | always  |
| 3          | NFS server                                   | n/a (required)                   | always  |
| 4          | seccomp installer DaemonSet                  | n/a (required)                   | always  |
| 5          | SUNK operator                                | n/a (required)                   | always  |
| 6          | Slurm chart (CPU-only)                       | n/a (required)                   | always  |
| 7          | GKE system tolerations patch                 | n/a (required)                   | always  |
| 8          | Cloud Monitoring dashboards                  | "skip monitoring"                | yes     |
| 9          | DCGM exporter + Slurm syncer scrape config   | "skip gpu monitoring"            | yes     |
| 10         | Default local user with caller's SSH key     | "skip user provisioning"         | yes     |
| 11         | Verification loop (incl. dashboards/SSH)     | n/a (required)                   | always  |

If the user gives a narrower acceptance test (e.g. "don't stop until tests
pass"), treat that as the floor, not the ceiling. Steps 8–10 still run by
default. Confirm explicitly with the user before skipping any default step.

GPU node pools are **not** part of this skill — adding a GPU pool is an
opt-in via `skills/gke/add-gpu-nodes-to-gke`. If the user asks for GPUs as
part of the same deploy request, run that skill after Step 11.

## Step 0: GCP Prerequisites

Run these checks before anything else. Deploying on the wrong project or without quota wastes cluster creation time (~5 min) that you cannot recover.

```bash
# 1. Verify which GCP account is active (use corporate, not personal)
gcloud auth list

# 2. Set the target project explicitly
gcloud config set project YOUR_PROJECT_ID

# 3. Enable required APIs (idempotent, safe to re-run)
gcloud services enable container.googleapis.com compute.googleapis.com

# 4. Check CPU and GPU quota in the target region
export REGION="us-central1"  # Change to your target region
gcloud compute regions describe $REGION \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  --filter="quotas.metric:CPUS OR quotas.metric:GPU"
```

Verify that:
- The active account has Owner or Editor on the target project
- `container.googleapis.com` and `compute.googleapis.com` are enabled
- CPU quota has room for your node count (e.g., 8 CPUs for 2x e2-standard-4)
- If deploying GPU nodes later, **both** quotas have headroom for the GPU
  count you plan to add — global and regional are enforced separately:

  ```bash
  # Global accelerator quota
  gcloud compute project-info describe --project "$PROJECT_ID" \
    --format="table(quotas.metric,quotas.limit,quotas.usage)" \
    | grep GPUS_ALL_REGIONS

  # Regional accelerator quota (substitute the right metric for your GPU)
  gcloud compute regions describe "$REGION" --project "$PROJECT_ID" \
    --format="table(quotas.metric,quotas.limit,quotas.usage)" \
    | grep -E 'NVIDIA_(L4|A100|H100)_GPUS'
  ```

  Skipping the regional check is the most common reason a `node-pools create`
  succeeds but the underlying managed instance group spins on
  `Quota '... GPUS' exceeded`.

## Prerequisites

Before starting, verify the following tools are installed:

1. **gcloud CLI** with the GKE auth plugin:
   ```bash
   gcloud components install gke-gcloud-auth-plugin
   ```
2. **Helm 3** with the CoreWeave chart repo. The SUNK and Slurm charts are
   licensed; contact CoreWeave at sunk@coreweave.com for access instructions
   and substitute the repository URL you receive for `<COREWEAVE_HELM_REPO_URL>`.
   After adding the repo, fetch each chart's metadata as a preflight before
   installing so you don't discover network/auth issues mid-deploy:
   ```bash
   helm repo add coreweave <COREWEAVE_HELM_REPO_URL> --force-update
   helm repo update coreweave

   # Preflight: confirm the chart repo is reachable before installing.
   helm show chart coreweave/sunk
   helm show chart coreweave/slurm
   ```
3. **kubectl** installed.
4. **cert-manager Helm repo** (needed for MOCO):
   ```bash
   helm repo add jetstack https://charts.jetstack.io
   ```
5. **MOCO Helm repo**:
   ```bash
   helm repo add moco https://cybozu-go.github.io/moco/
   ```

## Step 1: Create GKE Cluster

GKE Standard is required. Autopilot does not work (SUNK needs privileged pods, hostNetwork, custom DaemonSets, and fine-grained node pool control).

Use the shipped wrapper:

```bash
bash infrastructure/gke/create-cluster.sh --project YOUR_PROJECT_ID --yes
```

The script enables required APIs (container, compute, iamcredentials,
monitoring), creates the cluster with the budget-profile sizing (2x
`e2-standard-4`, `cloud.google.com/gke-nodepool=cpu-4` label,
Workload Identity enabled via `--workload-pool`), fetches credentials
into the active kubeconfig, and verifies nodes are Ready. Takes ~5-8
minutes. Cost: ~$6.40/day idle.

Flags you'll reach for:

```bash
--name           default: sunk
--zone           default: us-central1-a
--machine        default: e2-standard-4
--nodes          default: 2 (minimum 1; GKE rejects 0)
--pool           default: cpu-4 (the node label every Helm value expects)
--kubeconfig     write credentials to a specific file instead of the default
--dry-run        print the gcloud command; create nothing
```

**Minimum sizing:** 2x e2-standard-4 provides ~7.8 allocatable CPU and ~26 GiB RAM. The SUNK control plane needs ~2.7 CPU and ~8.8 GiB total. `--num-nodes=0` is invalid for GKE; the script enforces `--nodes >= 1`.

## Step 2: Create Namespaces and Install Dependencies

### Namespaces

```bash
kubectl create namespace sunk
kubectl create namespace tenant-slurm
kubectl create namespace moco-system
kubectl create namespace cert-manager
kubectl create namespace monitoring
```

### cert-manager (required by MOCO)

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

MOCO is installed separately from the SUNK chart to avoid version and configuration conflicts. The SUNK chart's built-in MOCO installation is disabled later.

## Step 3: Deploy NFS Server

GCE Persistent Disks are ReadWriteOnce only. SUNK requires shared `/home` across all pods (controller, login, compute). An in-cluster NFS server backed by a PD solves this.

### NFS image compatibility (CRITICAL)

Only `itsthenetwork/nfs-server-alpine:12` works on GKE COS (Container-Optimized OS) nodes:

| Image | Works on GKE? | Failure reason |
|-------|---------------|----------------|
| `itsthenetwork/nfs-server-alpine:12` | Yes | Userspace NFS, no kernel module needed |
| `registry.k8s.io/volume-nfs:0.8` | No | Docker manifest v1 rejected by containerd v2.1 |
| `erichough/nfs-server:2.2.1` | No | Requires kernel NFS module not loaded on COS |

### NFS server manifest

The manifest ships as `infrastructure/gke/nfs-server.yaml` — no
customization required. It pins `storageClassName: premium-rwo`, the
lock-taint toleration, and `cloud.google.com/gke-nodepool=cpu-4`
affinity (matches the default pool created by `create-cluster.sh`).
Without the toleration the NFS server gets evicted as soon as SUNK
taints a node; without the affinity it can land on a GPU node.

Deploy:
```bash
kubectl apply -f infrastructure/gke/nfs-server.yaml
```

Wait for the NFS pod to reach Running before proceeding:
```bash
kubectl wait --for=condition=available deployment/nfs-server -n tenant-slurm --timeout=120s
```

## Step 4: Understand the Lock Taint (CRITICAL)

This is the single most important GKE-specific issue in the entire deployment. Read this before touching Helm values.

### What happens

The SUNK operator hardcodes a non-configurable `NoExecute` taint on every Kubernetes node running compute (NodeSet) pods:

```
sunk.coreweave.com/lock=true:NoExecute
```

On CoreWeave infrastructure, compute nodes are dedicated, so this is harmless. **On GKE with shared node pools, this taint evicts every pod that does not tolerate it**, including critical GKE system components:

- **konnectivity-agent**: Breaks `kubectl exec`, `kubectl logs`, and all webhook calls. This is the most disruptive failure because it makes the cluster nearly unmanageable.
- **kube-dns**: Breaks all in-cluster DNS resolution.
- **cert-manager**: Breaks certificate issuance, which breaks MOCO.
- **moco-controller**: Breaks MySQL management.
- **metrics-server**, **gmp-operator**, **event-exporter-gke**, **l7-default-backend**: Various cluster functionality degradation.

### Solution (two parts)

**Part 1:** Every SUNK and Slurm pod must include this toleration in its Helm values:
```yaml
tolerations:
  - key: sunk.coreweave.com/lock
    operator: Exists
    effect: NoExecute
```

This applies to: the SUNK operator, syncer, every Slurm control plane component (controller, accounting, rest, login), NFS server, secretJob, cleanupCompleting, and any other pod you deploy in the cluster.

**Part 2:** GKE system pods must be patched separately after compute nodes join. See Step 7.

## Step 5: Deploy SUNK Operator

Create `helm-values/gke/sunk-values.yaml`:

```yaml
nvidia-device-plugin:
  enabled: false  # GKE provides its own NVIDIA device plugin

operator:
  resources:
    requests: {cpu: 250m, memory: 256Mi}
    limits: {memory: 1Gi}
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: cloud.google.com/gke-nodepool
                operator: In
                values: ["CPU_POOL_NAME"]  # Replace with your CPU pool name
  podMonitor:
    enabled: false
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
  enabled: false  # Installed separately in Step 2
```

Key points:
- **`nvidia-device-plugin.enabled: false`**: GKE auto-installs NVIDIA drivers and the standard device plugin on GPU node pools. The SUNK device plugin is a CoreWeave fork with custom resource naming that conflicts.
- **Resource reductions**: The default operator requests (8 CPU / 32 Gi) are sized for CoreWeave production nodes and will not fit on e2-standard-4.
- **Monitoring CRDs disabled**: GKE does not ship Prometheus Operator or VictoriaMetrics. Leaving `podMonitor` or `vmPodScrape` enabled causes CRD-not-found errors.
- **`moco.enabled: false`**: MOCO was installed independently in Step 2.

Deploy:
```bash
helm upgrade --install sunk coreweave/sunk \
  -f helm-values/base/sunk-values.yaml \
  -f helm-values/gke/sunk-values.yaml -n sunk
```

## Step 6: Deploy Slurm Chart (CPU-only initially)

This is the most complex step. Every section has GKE-specific adaptations.

Two template values files are provided:
- **`helm-values/gke/slurm-values-minimal.yaml`**: CPU-only, nsscache disabled. Use for dev/test.
- **`helm-values/gke/slurm-values-full.yaml`**: Adds GPU workers, nsscache/LDAP, and the SUNK pod scheduler.

Copy the appropriate template and customize it. The inline example below matches the minimal profile.

Create `helm-values/gke/slurm-values.yaml`:

```yaml
global:
  cks: false  # REQUIRED: pull from public GHCR, not CoreWeave internal registry
  volumes:
    - name: shared-home
      nfs:
        server: nfs-server.tenant-slurm.svc.cluster.local
        path: /
  volumeMounts:
    - name: shared-home
      mountPath: /home

clusterName: "sunk"  # Replace with your cluster name

# --- Control Plane Components ---
# Every component needs: lock toleration + CPU pool affinity + reduced resources

controller:
  resources:
    requests: {cpu: 500m, memory: 1Gi}
    limits: {memory: 2Gi}
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  stateVolume:
    storageClassName: premium-rwo
    size: 5Gi
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: cloud.google.com/gke-nodepool
                operator: In
                values: ["CPU_POOL_NAME"]

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
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: cloud.google.com/gke-nodepool
                operator: In
                values: ["CPU_POOL_NAME"]

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
    type: ClusterIP           # Change to LoadBalancer for external SSH access
    externalTrafficPolicy: "" # REQUIRED: chart defaults to "Local", which is invalid for ClusterIP
  sshKeyVolume:
    storageClassName: premium-rwo
    size: 1Gi
    accessModes: [ReadWriteOnce]
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: cloud.google.com/gke-nodepool
                operator: In
                values: ["CPU_POOL_NAME"]
  loginController:
    podMonitor: {enabled: false}
    vmPodScrape: {enabled: false}
  directoryCache:
    podMonitor: {enabled: false}
    vmPodScrape: {enabled: false}

# --- Compute Nodes ---
compute:
  reservedMemory: "0"       # Default 4Gi causes negative DefMemPerCPU on small nodes
  cacheDropper:
    enabled: false
  pyxis:
    enabled: true            # Requires the universal seccomp-installer DaemonSet AND
                             # compute.pyxis.appArmorProfile below. Set to false to skip
                             # --container-image support entirely.
    appArmorProfile: unconfined  # COS enforces AppArmor but ships no `enroot` profile;
                                 # run slurmd unconfined. Privileged slurmd already has
                                 # the caps enroot needs, so this adds no meaningful risk.
  securityContext:
    privileged: true         # Required for cgroup management, otherwise "cgroup mountpoint does not align"
  nodes:
    cpu-workers:
      enabled: true          # CRITICAL: chart defaults to false!
      replicas: 2            # Match your CPU node count
      resources:
        requests: {cpu: 250m, memory: 256Mi}
        limits: {memory: 512Mi}
      nodeSelector:
        cloud.google.com/gke-nodepool: CPU_POOL_NAME
      tolerations: []        # Empty array prevents inheriting CoreWeave default tolerations
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: cloud.google.com/gke-nodepool
                    operator: In
                    values: ["CPU_POOL_NAME"]

# --- Syncer ---
syncer:
  enabled: true
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {memory: 256Mi}
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: cloud.google.com/gke-nodepool
                operator: In
                values: ["CPU_POOL_NAME"]

# --- Database ---
moco:
  enabled: true
  mysqlCluster:
    resources:
      requests: {cpu: 250m, memory: 512Mi}
      limits: {memory: 1Gi}
    persistence:
      storageClassName: premium-rwo
      size: 5Gi
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: cloud.google.com/gke-nodepool
                  operator: In
                  values: ["CPU_POOL_NAME"]
mysql:
  enabled: false

# --- Jobs need lock toleration ---
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

# --- Disabled CoreWeave-specific features ---
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

# --- Munge ---
munge:
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {memory: 256Mi}

# --- Slurm config ---
slurmConfig:
  DefMemPerCPU: 100  # Default 4096 exceeds small node memory. Adjust for your node size.
```

### Why each adaptation matters

| Setting | Default | GKE override | Reason |
|---------|---------|--------------|--------|
| `global.cks` | true | `false` | Pulls images from public GHCR instead of CoreWeave internal registry |
| `compute.reservedMemory` | "4Gi" | `"0"` | 4Gi subtracted from RealMemory causes negative DefMemPerCPU on small nodes |
| `compute.pyxis.enabled` | true | `true` | Kept on. Requires the seccomp-installer DS AND `appArmorProfile: unconfined` below |
| `compute.pyxis.appArmorProfile` | `localhost/enroot` | `unconfined` | COS ships no `enroot` AppArmor profile; run slurmd unconfined (privileged already covers enroot's caps) |
| `compute.securityContext.privileged` | false | `true` | Required for cgroup management; without it slurmd fails |
| `compute.nodes.*.enabled` | false | `true` | Chart defaults all node groups to disabled |
| `compute.nodes.*.tolerations` | CW defaults | `[]` | Empty array prevents inheriting CoreWeave-specific tolerations |
| `slurmConfig.DefMemPerCPU` | 4096 | `100` | Must fit within node's available memory per CPU (see formula below) |
| `login.service.externalTrafficPolicy` | "Local" | `""` | "Local" is invalid for ClusterIP services; causes Service creation failure |
| `controller.stateVolume.storageClassName` | (none) | `premium-rwo` | GKE has no default StorageClass matching CW expectations; PVC stays Pending without this |
| `autoPartition` | enabled | `false` | Depends on CoreWeave infrastructure |
| `sunkDevicePlugin` | enabled | `false` | GKE has its own NVIDIA device plugin |
| `sunkScheduler` | enabled | `false` | Depends on the SUNK device plugin |

### Deploy command

```bash
# Install the enroot seccomp profile on every node BEFORE helm install slurm.
# compute.pyxis.enabled defaults to true; without this DaemonSet, compute pods
# get stuck in Init:CreateContainerError.
kubectl apply -f infrastructure/universal/seccomp-installer-daemonset.yaml
kubectl rollout status -n seccomp-installer ds/seccomp-installer --timeout=120s

# Preflight posture printout — make the security choice visible before install.
echo "About to install SUNK with security posture: capabilities-only (GKE COS, target)."
echo "  Pyxis is OFF by default on GKE until an AppArmor profile loader ships."
echo "  See docs/universal/security-model.md for the per-cloud posture matrix."

helm upgrade --install slurm coreweave/slurm \
  -f helm-values/base/slurm-values.yaml \
  -f helm-values/gke/slurm-values.yaml \
  -n tenant-slurm
```

The base values file (`helm-values/base/slurm-values.yaml`) sets `global.nodeSelector.affinity: null`, which clears the chart's default `node.coreweave.cloud/class=cpu` affinity that would otherwise leave Slurm control-plane pods Pending on GKE. If you bypass the base file (e.g., custom values only), append `--set-json 'global.nodeSelector.affinity=null'` to the helm command instead.

> **Syncer secret delay (normal):** After `helm install`, the `slurm-syncer` and `slurm-scheduler` pods will show `CreateContainerConfigError` for 2-3 minutes. This is expected. The `slurm-secret-job` pod must generate JWT tokens first, which requires the controller to be fully running. Wait for the secret-job pod to reach `Completed` status, then the syncer and scheduler will start automatically. Do not delete or restart them during this window.

> **Image-pull timing (normal):** On freshly created `e2-standard-4`
> nodes, first-time pulls of `ghcr.io/coreweave/slurm-containers/*` images
> (~1 GiB each) take ~1 minute per pod. With 5-7 pods per node that
> compounds to 3-5 minutes of `Init:ContainerCreating` on the first
> deploy. Do not retry or delete pods during this window; subsequent
> deploys reuse the cached layers and start in under a minute.

### DefMemPerCPU sizing

`DefMemPerCPU` controls how much memory Slurm allocates per CPU by default. The chart default of 4096 MB works for large CoreWeave nodes but will exceed the available memory on small GKE nodes, causing jobs to be rejected.

**Formula:**

```
DefMemPerCPU = (node_allocatable_memory_MB - reservedMemory_MB) / cpus_available_to_slurm
```

Where:
- `node_allocatable_memory_MB` = what Kubernetes reports as allocatable (not total)
- `reservedMemory_MB` = the `compute.reservedMemory` value (set to "0" for small nodes)
- `cpus_available_to_slurm` = node vCPUs minus what the compute pod requests

**Examples by node size:**

| Machine type | Allocatable RAM | vCPUs | Compute pod CPU req | Slurm CPUs | Recommended DefMemPerCPU |
|-------------|----------------|-------|--------------------|-----------|-----------------------|
| e2-standard-4 | ~15,000 MB | 4 | 250m | ~3.75 | 100 (conservative) to 3000 |
| e2-standard-8 | ~30,000 MB | 8 | 250m | ~7.75 | 3000-3800 |
| e2-standard-16 | ~62,000 MB | 16 | 250m | ~15.75 | 3800-4000 |
| n2-standard-32 | ~125,000 MB | 32 | 250m | ~31.75 | 4000 (default is fine) |

For small dev clusters (e2-standard-4), set `DefMemPerCPU: 100` so basic jobs like `srun hostname` work without specifying `--mem`. For production nodes with 128+ GiB RAM, the chart default of 4096 is appropriate.

## Step 7: Patch GKE System Pods (MANDATORY — do not skip)

This step is not optional. Skipping it is how the GKE verify run
produces 14 test failures in a row: the SUNK operator taints the
compute node the moment the first NodeSet pod schedules, every
GKE-managed system pod without a matching toleration gets evicted,
and `kubectl exec` stops working because `konnectivity-agent` is one
of those pods. Once `kubectl exec` is broken, the whole test suite
and most debugging tools cannot reach the login pod — symptoms look
like unrelated "unable to upgrade connection" errors, DNS failures,
or timeouts on every verification step.

Run this script immediately after `helm install slurm` schedules the
first compute pod, BEFORE running any `kubectl exec` that matters:

```bash
bash infrastructure/gke/patch-gke-tolerations.sh
```

Expected output is a series of `<ns>/<deploy>: patched` lines for
kube-system, cert-manager, moco-system, gmp-system, plus a
MySQLCluster patch in `tenant-slurm`. Any `FAILED to patch` line is
a hard error; investigate before proceeding.

The script patches: `konnectivity-agent(-autoscaler)`,
`kube-dns(-autoscaler)`, `event-exporter-gke`, `l7-default-backend`,
`metrics-server` (dynamically discovered because of its version suffix),
`cert-manager` + its `cainjector`/`webhook`, `moco-controller`,
`gmp-operator`, the `kube-state-metrics` StatefulSet in `gke-managed-cim`,
and the MOCO `MySQLCluster` custom resource in `tenant-slurm`. Strategic
merge patch is attempted first; the script then re-reads
`.spec.template.spec.tolerations` and falls back to an explicit JSON patch
if the lock toleration did not stick (some GKE-managed workloads have
silently no-op'd strategic merges in observed runs). For CRDs whose
`podTemplate` does not support strategic merge (MySQLCluster), it uses a
read-merge-write JSON merge patch.

After the script reports `patched`, wait for rollouts to settle before you
trust `kubectl exec`:

```bash
kubectl rollout status deploy/konnectivity-agent -n kube-system --timeout=180s
kubectl rollout status deploy/kube-dns -n kube-system --timeout=180s
kubectl rollout status sts/kube-state-metrics -n gke-managed-cim --timeout=180s
```

**GKE reverts these patches during cluster upgrades.** If `kubectl exec`
or DNS suddenly stops working after a GKE release-channel upgrade,
re-run this script before anything else. For a long-lived cluster,
wire it into your CD pipeline so it runs on every GKE upgrade.

## Step 8: Install Cloud Monitoring dashboards (default; skip with "skip monitoring")

Run this immediately after SUNK and Slurm are healthy. It is part of
the main deploy flow; the customer does not need to type anything
beyond `--project`. Only skip this step if the user explicitly says
they don't want Cloud Monitoring dashboards.

```bash
bash infrastructure/gke/install-monitoring.sh --project YOUR_PROJECT_ID
```

What it does, idempotently:
- Enables `iamcredentials.googleapis.com` and `monitoring.googleapis.com`.
- Creates the `gmp-reader` GSA with `roles/monitoring.viewer`.
- Binds `gmp-reader` to the `monitoring/default` KSA via Workload
  Identity and annotates the KSA with
  `iam.gke.io/gcp-service-account`. Without this, the GMP frontend
  returns 403 on every query.
- Loops over `infrastructure/observability/*-gcm-dashboard.json` and
  calls `gcloud monitoring dashboards create`, skipping any whose
  `displayName` already exists in the project.

After the script finishes, the dashboards "SUNK: Slurm Cluster
Overview" and "SUNK: Slurm Job Metrics" appear at
`https://console.cloud.google.com/monitoring/dashboards?project=YOUR_PROJECT_ID`.

The JSON files are GCM-native (`mosaicLayout` + `displayName`). They
are NOT Grafana dashboards; loading them into Grafana crashes the
pod. Grafana-format dashboards, if any, live under
`infrastructure/observability/grafana/`.

## Step 9: Install DCGM exporter and Slurm syncer scrape (default; skip with "skip gpu monitoring")

The dashboards from Step 8 query Google Managed Prometheus. Until something
is scraping GPU and Slurm metrics, every panel reads empty. This step wires
both up. Skip only if the user explicitly says they don't want GPU/Slurm
metrics — the dashboards from Step 8 are useless without it.

The DCGM DaemonSet has a `nodeAffinity` for `cloud.google.com/gke-nodepool=gpu`,
so it stays Pending until a GPU pool is added (via
`skills/gke/add-gpu-nodes-to-gke`). That's intentional — the manifest is safe
to apply on a CPU-only cluster and starts emitting metrics the moment a GPU
node joins.

```bash
# DCGM exporter DaemonSet + ConfigMap + Service (GPU metrics)
kubectl apply -f infrastructure/observability/dcgm-exporter.yaml

# GMP PodMonitoring CRDs that scrape DCGM and the Slurm syncer
kubectl apply -f infrastructure/observability/dcgm-podmonitoring.yaml
kubectl apply -f infrastructure/observability/syncer-podmonitoring.yaml
```

What ships:
- `monitoring/dcgm-exporter` — DaemonSet pinned to GPU nodes, emitting
  `DCGM_FI_DEV_GPU_UTIL`, `_GPU_TEMP`, `_POWER_USAGE`, `_FB_USED`,
  `_XID_ERRORS`, etc. on port 9400.
- `monitoring/PodMonitoring/dcgm-exporter` — GMP scrape config for the above.
- `tenant-slurm/PodMonitoring/sunk-syncer` — GMP scrape of the Slurm syncer
  on port 8080, exposing `slurm_node_state`, `slurm_jobs_running`,
  `slurm_scheduler_jobs_submitted`, etc.

If the cluster has no GPU pool yet, the DCGM pod will be `0/0 Pending`. That
is expected; the dashboards will still get the syncer (Slurm) metrics. Once
a GPU pool is added, DCGM auto-schedules and the GPU panels light up.

For provider-agnostic monitoring (EKS/generic), see
`skills/universal/setup-sunk-gpu-monitoring`.

#### What "GPU monitoring" includes by default vs. opt-in

The default Step 9 deliverables on GKE are:

- Cloud Monitoring dashboards (from Step 8)
- DCGM exporter DaemonSet
- GMP PodMonitoring for DCGM and the Slurm syncer

`facebookresearch/gcm` (the GPU Cluster Monitoring chart that surfaces
on-node GPU health as Node conditions) is **NOT** part of the default flow.
Install it only when the user explicitly asks for GCM-style health
checks:

```bash
helm upgrade --install gcm oci://ghcr.io/facebookresearch/charts/gcm \
  -f helm-values/gke/gcm-values.yaml \
  --set healthChecks.cluster="$CLUSTER_NAME" \
  -n kube-system \
  --wait \
  --timeout=5m

bash infrastructure/gke/patch-gcm-for-gke.sh
```

Verify:

```bash
helm status gcm -n kube-system
kubectl get pods -n kube-system -l app.kubernetes.io/name=gcm
kubectl get node "$GPU_NODE" -o json | jq '.status.conditions[] | select(.type | test("Gcm"))'
```

GCM pods should be Running and the GPU node should show `Gcm*` conditions
with `status: "False"` for problem types (i.e. no problem detected).

## Step 10: Provision the default local user (default; skip with "skip user provisioning")

A SUNK cluster you can't `ssh` into is a demo, not a deploy. This step drops
a single POSIX user onto the login pod with the caller's SSH public key and
registers them with slurmdbd so `sbatch` works without a manual
`sacctmgr add user`. Skip only if the user explicitly says they don't want a
default user, or they're going straight to LDAP via
`skills/universal/configure-sunk-authentik-sssd`.

Defaults (override on the command line if needed):
- `--username`: `$USER` from the caller's shell
- `--uid`/`--gid`: `1001`
- `--ssh-key`: `~/.ssh/id_ed25519.pub`, falling back to `~/.ssh/id_rsa.pub`
- `--email`: `<username>@cluster.local`

```bash
SSH_KEY_FILE="$HOME/.ssh/id_ed25519.pub"
[ -f "$SSH_KEY_FILE" ] || SSH_KEY_FILE="$HOME/.ssh/id_rsa.pub"
[ -f "$SSH_KEY_FILE" ] || { echo "no SSH public key found; ask the user for one or skip user provisioning"; exit 1; }

bash infrastructure/universal/add-sunk-user.sh add \
    --username "$USER" --uid 1001 --gid 1001 \
    --email "$USER@cluster.local" \
    --ssh-key "$(cat "$SSH_KEY_FILE")"
```

This handles only login-pod identity. Cross-pod identity on compute pods is a
separate concern — see `skills/universal/bootstrap-sunk-local-user/SKILL.md`
for the `compute.extraUsers` Helm-values knob, or
`configure-sunk-authentik-sssd` for LDAP-backed identity across all pods.

For a one-line login URL once provisioned (after Step 11 verification):

```bash
# If login.service.type=ClusterIP (default), port-forward:
kubectl port-forward -n tenant-slurm svc/slurm-login 2222:22
# Then: ssh -p 2222 <username>@localhost
```

Switch `login.service.type` to `LoadBalancer` in
`helm-values/gke/slurm-values.yaml` if you want a public address instead.

## Step 11: Verification Loop

**Repeat the checks below. If any fail, consult the troubleshooting table. Do not proceed until ALL pass.**

### Check 1: All pods healthy

```bash
kubectl get pods -n tenant-slurm
kubectl get pods -n sunk
```

**Pass condition:** All pods show `Running` or `Completed`. No `CrashLoopBackOff`, `Error`, or `Pending` (except: syncer/scheduler may show `CreateContainerConfigError` for up to 3 minutes after initial install, which is normal).

| Failure | Consult |
|---------|---------|
| Pods in `Pending` | Troubleshooting: "Compute pods stuck in Pending" |
| `CrashLoopBackOff` on NFS | Troubleshooting: "NFS pod CrashLoopBackOff" |
| `CreateContainerConfigError` after 5+ min | Troubleshooting: "Syncer/scheduler show CreateContainerConfigError" |
| Pods evicted repeatedly | Troubleshooting: "Pods evicted from compute nodes unexpectedly" |

### Check 2: Slurm nodes idle

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo
```

**Pass condition:** All nodes show `idle` state. No nodes in `down`, `drain`, or `unknown`.

| Failure | Action |
|---------|--------|
| `kubectl exec` returns "No agent available" | Run `bash infrastructure/gke/patch-gke-tolerations.sh`, then retry |
| Nodes in `down` or `drain` | Check slurmd logs: `kubectl logs -n tenant-slurm <compute-pod> -c slurmd` |
| No nodes listed | Verify `compute.nodes.cpu-workers.enabled: true` in values |

### Check 3: Job execution works

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname
```

**Pass condition:** Returns the hostname of a compute pod (e.g., `slurm-cpu-workers-000-xxxxx`).

| Failure | Action |
|---------|--------|
| `srun` hangs indefinitely | Check munge keys match: `kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- munge -n \| kubectl exec -n tenant-slurm -i <compute-pod> -c slurmd -- unmunge` |
| `error: Unable to allocate resources` | Check `slurmConfig.DefMemPerCPU` is not too high for node size |
| `srun: error: ...Invalid user id` | User auth issue; verify nsscache or use root: `srun --uid=0 --mem=100 hostname` |

### Check 4: Shared filesystem works

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- bash -c 'echo verification-test > /home/v.txt && srun --mem=100 cat /home/v.txt && rm /home/v.txt'
```

**Pass condition:** Prints `verification-test`. This confirms NFS is mounted and accessible from both login and compute nodes.

| Failure | Action |
|---------|--------|
| `/home/v.txt: No such file or directory` | NFS not mounted on compute. Check `global.volumes` and `global.volumeMounts` in values |
| `Permission denied` | NFS server pod may need restart, or PVC is full |
| Write succeeds but `srun cat` fails | NFS mounted on login but not compute. Verify global volume config applies to compute pods |

### Check 5: Dashboards and scrapes are wired up (skip if Step 8 or 9 was skipped)

```bash
# Dashboards exist
gcloud monitoring dashboards list --project YOUR_PROJECT_ID \
  --format='value(displayName)' | grep -E '^SUNK: '

# Slurm syncer scrape target is up (PodMonitoring → GMP)
kubectl run sprobe -n tenant-slurm --rm -i --restart=Never \
  --image=curlimages/curl --timeout=60s \
  --overrides='{"spec":{"tolerations":[{"key":"sunk.coreweave.com/lock","operator":"Exists","effect":"NoExecute"}]}}' \
  -- curl -s --max-time 20 http://slurm-syncer.tenant-slurm.svc:8080/metrics | grep '^slurm_nodes_idle '

# DCGM exporter scrape target is up — only when a GPU pool exists.
kubectl get pod -n monitoring -l app.kubernetes.io/name=dcgm-exporter --no-headers
```

**Pass condition:**
- Both `SUNK: Slurm Cluster Overview` and `SUNK: Slurm Job Metrics` listed.
- `slurm_nodes_idle` line printed with a numeric value.
- DCGM pod is `Running` (or `0/0` if no GPU pool yet — that's expected).

| Failure | Action |
|---------|--------|
| Dashboards missing | Re-run `bash infrastructure/gke/install-monitoring.sh --project YOUR_PROJECT_ID` |
| Syncer scrape returns nothing | Re-apply `infrastructure/observability/syncer-podmonitoring.yaml`; verify `kubectl get pod -l app.kubernetes.io/name=sunk-syncer -n tenant-slurm` is Running |
| DCGM CrashLoopBackOff | Confirm GPU node has the NVIDIA driver mounted at `/home/kubernetes/bin/nvidia` (GKE default; see `skills/universal/setup-sunk-gpu-monitoring`) |

### Check 5b: Run the full example suite (recommended)

Checks 1–5 are the minimal smoke. Several issues caught during real GKE
deployments only surface under the broader matrix in `examples/` — raw-pod
eviction from the lock taint, host-side context propagation, NCCL skip
behavior, etc. Run the full suite from the host once Checks 1–4 are green:

```bash
./examples/run-all.sh \
  --ns=tenant-slurm \
  --login-pod=slurm-login-0 \
  --context="$KUBE_CONTEXT"   # gke_<project>_<zone>_<cluster>
```

Expected on a 1-GPU GKE cluster after this skill's fixes:

- `01,02,03,07,08,09,10,11,12,14,16,17,18,04,15` → `PASS`
- `13-nccl-test.sh` → `SKIPPED` (needs `>=2` GPUs; not a failure on a
  1-GPU cluster — see `examples/README.md` for the full prerequisites)
- `19-vscode-tunnel.sh` → not in the default matrix; opt-in via `--only=`
- `FAIL=0`

After the suite finishes, sanity-check there is no leaked state:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- squeue -a
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo -Nel
kubectl get pods -A --no-headers | grep -vE 'Running|Completed' || true
```

Empty `squeue`, all nodes `idle`, and no stuck pods — the suite cleans up
its own jobs and pods on exit, so anything left behind is a real signal.

### Check 6: Default user can SSH and submit (skip if Step 10 was skipped)

```bash
# In one terminal:
kubectl port-forward -n tenant-slurm svc/slurm-login 2222:22 &

# In another:
ssh -o StrictHostKeyChecking=no -p 2222 "$USER"@localhost id
ssh -p 2222 "$USER"@localhost srun --mem=100 hostname
```

**Pass condition:** `id` reports `uid=1001(<username>)`; `srun` returns a
compute-pod hostname.

| Failure | Action |
|---------|--------|
| `Permission denied (publickey)` | Re-run Step 10 with the correct `--ssh-key` value |
| `srun: error: ...Invalid user id` | Compute pods don't know about the user. Either set `compute.extraUsers` in `helm-values/gke/slurm-values.yaml` and `helm upgrade`, or migrate to `configure-sunk-authentik-sssd` |
| `port-forward` cannot connect | Confirm `login.service.type` is `ClusterIP` (default) and the login pod is Running |

## Minimum Resource Requirements

### CPU nodes (control plane)

At least **2x e2-standard-4** (4 vCPU, 16 GiB each). Provides ~7.8 allocatable CPU and ~26 GiB total.

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
| **Total** | **~2.7 CPU** | **~8.8 Gi** |

### Storage

| PVC | Size | StorageClass |
|-----|------|--------------|
| Controller state | 5Gi | premium-rwo |
| MySQL data | 5Gi | premium-rwo |
| SSH keys | 1Gi | premium-rwo |
| NFS backing store | 10Gi+ | premium-rwo |

### Resource profiles: minimal vs production

Use `slurm-values-minimal.yaml` for dev/test and `slurm-values-full.yaml` for production. Key differences:

| Component | Minimal (dev) | Production |
|-----------|--------------|------------|
| **Node type** | 2x e2-standard-4 | 4+ e2-standard-16 or larger |
| **controller CPU/mem** | 500m / 2Gi | 2000m / 8Gi |
| **accounting CPU/mem** | 100m / 512Mi | 500m / 2Gi |
| **login CPU/mem** | 250m / 1Gi | 1000m / 4Gi |
| **syncer CPU/mem** | 100m / 256Mi | 500m / 1Gi |
| **SUNK operator CPU/mem** | 250m / 1Gi | 1000m / 4Gi |
| **MySQL CPU/mem** | 250m / 1Gi | 1000m / 4Gi |
| **NFS backing PVC** | 10Gi | 100Gi+ |
| **MySQL PVC** | 5Gi | 50Gi+ |
| **compute.reservedMemory** | "0" | "4Gi" |
| **slurmConfig.DefMemPerCPU** | 100 | 4096 |
| **nsscache** | disabled | enabled (with LDAP) |
| **GPU workers** | disabled | enabled |
| **login.service.type** | ClusterIP | LoadBalancer |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `kubectl exec/logs` returns "No agent available" | konnectivity-agent evicted by lock taint | Run `infrastructure/gke/patch-gke-tolerations.sh` |
| slurmd: "cgroup mountpoint does not align" | Missing privileged mode | Set `compute.securityContext.privileged: true` |
| Pyxis pod validation error (seccompProfile) | `/var/lib/kubelet/seccomp/profiles/enroot` missing | Apply `infrastructure/universal/seccomp-installer-daemonset.yaml` and wait for `ds/seccomp-installer` Ready before `helm install slurm` |
| Compute pod stuck `Init:CreateContainerError`, `apparmor profile not found enroot` | COS enforces AppArmor, chart default annotation references a profile COS doesn't ship | Ensure `compute.pyxis.appArmorProfile: unconfined` is in your values. If it still fails, flip `compute.pyxis.enabled: false` and accept that `--container-image` is unavailable |
| Negative DefMemPerCPU, slurmd won't register | Default 4Gi reservedMemory exceeds node capacity | Set `compute.reservedMemory: "0"` and lower `slurmConfig.DefMemPerCPU` |
| Compute pods stuck in Pending | Node group not enabled | Set `compute.nodes.<name>.enabled: true` |
| NFS pod CrashLoopBackOff | Wrong NFS image for GKE COS nodes | Use `itsthenetwork/nfs-server-alpine:12` only |
| Pods evicted from compute nodes unexpectedly | Lock taint applied, pods lack toleration | Add lock taint toleration to every affected pod |
| Helm install fails with CRD errors | Monitoring CRDs (PodMonitor, VMPodScrape) not installed | Disable `podMonitor` and `vmPodScrape` on all components |
| MySQL pods fail to start | MOCO controller evicted or cert-manager broken | Run `infrastructure/gke/patch-gke-tolerations.sh`, verify cert-manager pods are running |
| Slurm chart pulls fail (image not found) | `global.cks` defaults to true (CoreWeave registry) | Set `global.cks: false` |
| Chart applies CoreWeave node affinity | Base values not loaded, or override stripped | Confirm `helm-values/base/slurm-values.yaml` is in `-f`. If not, append `--set-json 'global.nodeSelector.affinity=null'` |
| DNS resolution fails inside pods | kube-dns evicted by lock taint | Run `infrastructure/gke/patch-gke-tolerations.sh` |
| Login Service fails to create | `externalTrafficPolicy: Local` on ClusterIP | Set `login.service.externalTrafficPolicy: ""` |
| Controller PVC stuck in Pending | No StorageClass set, GKE has no matching default | Set `controller.stateVolume.storageClassName: premium-rwo` |
| Syncer/scheduler show `CreateContainerConfigError` | Secret-job has not completed yet (normal) | Wait 2-3 min for `slurm-secret-job` to complete; do not delete pods |
| `gcloud container clusters create` fails with `--num-nodes=0` | GKE requires at least 1 node | Use `--num-nodes=$CPU_NODE_COUNT` (minimum 1) |

## Generalizing to Other Environments

The specific values in this skill (e2-standard-4, cpu-4 pool name, premium-rwo, 100 DefMemPerCPU) are examples for a minimal dev cluster. When deploying to a different environment:

- **Node pools**: Replace `cloud.google.com/gke-nodepool` values throughout all Helm values files and the NFS manifest.
- **Machine types**: Larger nodes may not need resource reductions or DefMemPerCPU overrides.
- **Storage**: Replace `premium-rwo` with the appropriate StorageClass. On non-GKE clusters, use whatever CSI driver provides RWO block storage.
- **DefMemPerCPU**: Calculate as (node allocatable memory / number of CPUs available to Slurm). For large nodes, the default 4096 may be fine.
- **reservedMemory**: On nodes with ample RAM, the default 4Gi is appropriate.

The core principles that apply regardless of scale:
1. The lock taint must be tolerated by every pod on compute nodes.
2. CoreWeave-specific features (device plugin, scheduler, autoPartition, cacheDropper) must be disabled.
3. `global.cks: false` is always required outside CoreWeave.
4. NFS or another RWX filesystem is required for shared `/home`.
5. Compute node groups must be explicitly enabled (`enabled: true`).

## Next Steps

After base deployment is verified, add these capabilities:

| Capability | Skill | Description |
|------------|-------|-------------|
| **Helm upgrades** | `skills/universal/upgrade-sunk` | Full upgrade checklist with post-upgrade script for gres.conf, tolerations, and node recovery |
| **User authentication and SSH access** | `skills/universal/configure-sunk-user-auth` | Deploy OpenLDAP, enable nsscache, configure SSH public key injection for multi-user access |
| **GPU workers** | `skills/gke/add-gpu-nodes-to-gke` | Add GPU node pools and configure Slurm gres for GPU scheduling |
| **GPU monitoring** | `skills/universal/setup-sunk-gpu-monitoring` | Deploy DCGM Exporter and configure Prometheus/GMP scraping |
| **GKE system pod patching** | `skills/gke/patch-gke-system-tolerations` | Fix system pods evicted by the SUNK lock taint |
| **SkyPilot integration** | `skills/universal/connect-skypilot-to-sunk` | Enable Kubernetes-native job submission via SkyPilot |
