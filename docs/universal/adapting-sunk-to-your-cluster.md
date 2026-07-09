# Adapting SUNK to your own cluster

SUNK runs on any Kubernetes cluster: EKS, GKE, or bare-metal. Because it
was first built for CoreWeave Cloud, a handful of settings (node labels, image
registry, host security profiles, and security context) need to match your
environment rather than CoreWeave's. This page walks through each one, points to
the script or values file that handles it, and flags the parts you set for your
own cluster.

It is an orientation map, not a step-by-step. Each item links to the doc,
script, or values file that carries the detail.

## Before you start

- **Status.** Running SUNK on your own infrastructure is early and actively
  evolving. The [provider table](../README.md) shows which tracks are validated
  today; the others ship the same skills and values and are being hardened.
- **Images come from public GHCR.** Point your cluster at them as described in
  [container-images.md](container-images.md).
- **Know the namespace.** The Slurm workload components land in `tenant-slurm`,
  and the chart hardcodes the in-cluster NFS server hostname
  (`nfs-server.tenant-slurm.svc.cluster.local`,
  `helm-values/base/slurm-values.yaml`) to that namespace. The SUNK operator
  lands in `sunk`, and dependencies (cert-manager, MOCO) use their own
  namespaces (see [architecture.md](architecture.md)). Keep `tenant-slurm` for
  the Slurm side.

Every `helm install` layers a base values file plus a provider overlay. The
shape below shows the layering; your provider's `deployment-guide.md` has the
complete command, including the namespace flag and any affinity override:

```bash
helm install slurm <chart> -n tenant-slurm \
  -f helm-values/base/slurm-values.yaml \
  -f helm-values/<provider>/slurm-values.yaml
```

## What you must adapt

These are the things a deployment will trip on if you skip them. The "Status"
line tells you whether the repo automates it, ships a script, or leaves it to
you.

### 1. Node labels and affinity

- **What differs:** The upstream charts default to CoreWeave node affinity
  (`node.coreweave.cloud/class`, `node.coreweave.cloud/state`). Your nodes do
  not carry those labels, so control-plane and compute pods sit `Pending`.
- **What you do:** Set `nodeSelector` / `affinity` to your cluster's own labels.
  The base compute nodes ship with `nodeSelector: {}` and a `PROVIDER:` marker
  (`helm-values/base/slurm-values.yaml`); the per-provider overlays
  (`helm-values/{eks,gke,generic}/sunk-values.yaml`) show the pattern for the
  operator and control plane. Either match your nodes to those overlays or
  rewrite the affinity for your own label scheme.
- **Status:** Helm-values, per provider. You own the mapping to your labels.

### 2. Pyxis / enroot host security profiles

- **What differs:** `srun --container-image=...` (pyxis/enroot) needs a seccomp
  profile, and on AppArmor-enforcing hosts an AppArmor profile, that managed
  distros do not ship.
- **What you do:** Apply the installer DaemonSets before `helm install slurm`:
  - seccomp: `infrastructure/universal/seccomp-installer-daemonset.yaml`
  - AppArmor (only on hosts that enforce it, e.g. Ubuntu): the vendored
    `infrastructure/universal/apparmor-profiles/enroot.profile` plus
    `infrastructure/universal/apparmor-installer-daemonset.yaml`. The installer
    is a no-op on hosts without `apparmor_parser` (AL2, AL2023, Bottlerocket).
  See [security-model.md](security-model.md) for the three enablement paths and
  for the Ubuntu detail: the upstream NVIDIA profile uses `abi <abi/4.0>`, which
  AppArmor 3.x on **Ubuntu 22.04** cannot parse. **Ubuntu 24.04** (AppArmor 4.x)
  parses it; the vendored CoreWeave profile avoids the `abi` line and parses on
  both.
- **Status:** Scripted (DaemonSets). You decide which path your host needs.

### 3. The lock taint and system pods

- **What differs:** The SUNK syncer taints Slurm nodes with
  `sunk.coreweave.com/lock=true:NoExecute`. Pods that do not tolerate it get
  evicted, including your CNI, kube-proxy, and CSI node drivers, which breaks
  the node.
- **What you do:** SUNK's own pods already carry the toleration in
  `helm-values/base/*.yaml`. For the system pods, run the toleration patch
  script for your provider: `infrastructure/{eks,gke,generic}/patch-*-tolerations.sh`.
  On bare-metal there is no fixed list: `infrastructure/generic/patch-generic-tolerations.sh`
  is a template you must edit for your actual DaemonSets (CNI, CSI, device
  plugin).
- **Status:** Scripted for managed providers, manual audit for generic. Re-run
  after cluster upgrades, which can revert managed system pods.

### 4. Container images

- **What differs:** The chart can pull from CoreWeave's internal registry,
  which you cannot reach.
- **What you do:** Keep `global.cks: false` (the base default) so images pull
  from public GHCR. Full detail, including the air-gapped case, in
  [container-images.md](container-images.md).
- **Status:** Helm-values (one flag, already set in base).

### 5. Privileged slurmd and cgroups

- **What differs:** slurmd needs to manage cgroups on the host. How much
  privilege that takes depends on the node's kubelet cgroup configuration.
- **What you do:** The base default is `compute.securityContext.privileged: true`
  (`helm-values/base/slurm-values.yaml`), and that is the current posture on
  every provider. On EKS AL2023 it is required: the kubelet runs pods with
  `cgroup-namespace=host`, so an unprivileged slurmd hits a read-only cgroup
  filesystem and crash-loops (evidence in
  [security-model.md](security-model.md), test cells 3a-3g). A capabilities-only
  (non-privileged) posture is under investigation for hosts that allow it (k3s
  on Ubuntu 24.04 defaults to `cgroup-namespace=pod` and is reported to work),
  but it is not yet the shipped default anywhere. Plan for privileged slurmd
  unless you have validated otherwise on your nodes.
- **Status:** Helm-values default (privileged). Non-privileged is not yet
  shipped.

### 6. Storage and PVC permissions

- **What differs:** slurmctld runs as GID 401 and must write to its state PVC.
- **What you do:** The base values set `podSecurityContext.fsGroup: 401` on the
  controller and login pods. CSI drivers that honor `fsGroup` (EBS, GCE PD)
  chown the volume on attach and it works. Drivers that do not chown
  on mount can still give "Permission denied" on the state PVC; verify your
  driver honors `fsGroup`, or arrange ownership another way. You also set
  `storageClassName` (left `null` in base, with a `PROVIDER:` marker) for the
  controller state volume, login SSH-key volume, and MOCO.
- **Status:** Helm-values (fsGroup set). You verify your CSI driver and pick a
  storage class.

### 7. User provisioning

- **What differs:** CoreWeave Cloud provisions users via CW IAM and SCIM into
  nsscache. That pipeline does not exist on your cluster, and `nsscache.enabled`
  is `false` by default here for that reason.
- **What you do:** Pick one of the two paths that work off-CoreWeave (see the
  decision table in [ssh-access.md](ssh-access.md)):
  - **Simple** (`bootstrap-sunk-local-user` skill +
    `infrastructure/universal/add-sunk-user.sh`): creates an SSH-able Linux user
    and a Slurm association on the **login pod**. Good for first-touch and
    verification. Be aware of its hard limit, documented in
    [`infrastructure/universal/user-provisioning.md`](../../infrastructure/universal/user-provisioning.md):
    the user resolves only on the login pod, so **`sbatch` fails** ("Invalid
    account or account/partition combination") because slurmctld on the
    controller pod cannot resolve the user. There is no `compute.extraUsers` in
    `coreweave/slurm` v7.3.0.
  - **authentik + sssd** (`configure-sunk-authentik-sssd` skill): authentik as
    the directory source with sssd on every pod, so users resolve uniformly on
    controller and compute. This is the intended multi-pod identity path for
    `sbatch`, and the one to use if you need to run jobs. Validate it on your
    cluster; end-to-end authentik+sssd validation is still being hardened.
- **Status:** Two documented paths. Simple is scripted but login-only;
  multi-pod identity (authentik+sssd) you stand up yourself.

### 8. Reaching the login node

- **What differs:** There is no web UI and no Kubernetes-Secret login. Access is
  SSH (or `kubectl exec`) into `slurm-login-0`, exposed through a Service. The
  base Service type is `ClusterIP`.
- **What you do:** Expose it for your cluster: a LoadBalancer (the EKS overlay
  ships NLB annotations), `kubectl port-forward` (the GKE default), or NodePort.
  NodePort and external routing assume a working kube-proxy and CNI, which a
  vanilla cluster may not have. The full path, including firewall and
  Service-to-pod debugging, is in [ssh-access.md](ssh-access.md).
- **Status:** Helm-values per provider, plus your firewall/CNI.

### 9. GPU device plugin

- **What differs:** On CoreWeave, SUNK ships its own GPU device plugin
  (`sunkDevicePlugin`). Your managed GPU node pool ships its own NVIDIA plugin
  instead.
- **What you do:** Use your provider's NVIDIA device plugin. The base disables
  the bundled one (`nvidia-device-plugin.enabled: false` in
  `helm-values/base/sunk-values.yaml`) because managed GPU node pools ship their
  own; the generic overlay enables it for bare-metal that has none. The
  CoreWeave-specific `sunkDevicePlugin` and `sunkScheduler` keys are disabled in
  base. The chart's Pod Scheduler (`scheduler.enabled: true`, which schedules
  Kubernetes pods through Slurm) stays enabled and is unaffected.
- **Status:** Helm-values. You run on your provider's device plugin.

## What you handle yourself

These are real and the repo gives you a starting point or an example, but there
is no automation and you own the outcome.

- **Slurm topology.** `topology.conf` is not generated for you off-CoreWeave.
  `docs/generic/generic-adaptations.md` shows the `TopologyPlugin: topology/tree`
  values syntax; you write the topology to match your fabric.
- **Node health checks.** GPU health checks are available via GCM (opt-in, see
  [monitoring-guide.md](monitoring-guide.md)). General node health and
  remediation on CoreWeave is a platform service, not part of SUNK, so off-
  CoreWeave there is nothing to port. If you want node health gating, supply
  your own (for example via prolog/epilog or Node Problem Detector).
- **InfiniBand / RDMA and NCCL.** The chart does not assume your fabric.
  `docs/generic/generic-adaptations.md` shows example RDMA resource requests;
  adjust device names and any NCCL environment to match your hardware.
- **Host-image dependencies.** Anything CoreWeave bakes into its node image that
  SUNK relies on, you replicate on your nodes.
- **Scale-down.** Scaling compute to zero is future work; wire up Karpenter
  or the cluster-autoscaler yourself if you need it.

## Not covered here

- **WEKA storage integration.** WEKA documents how to run their client with
  SUNK; that is their guide to maintain, not this repo's.
- **OpenShift.** Not addressed. Its SecurityContextConstraints and runtime
  differ enough that nothing here is known to apply.
- **RoCE.** Not covered or validated by these docs.

## See also

- [README.md](../README.md): provider tracks and validation status.
- [security-model.md](security-model.md): privilege, cgroup, seccomp, AppArmor, the tested-alternatives matrix.
- [ssh-access.md](ssh-access.md): login Service exposure and the user-provisioning decision table.
- [container-images.md](container-images.md): pulling images on a non-CoreWeave cluster.
- [architecture.md](architecture.md): the lock taint, namespaces, and data flow.
