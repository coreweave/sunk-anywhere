# SUNK Security Model (universal)

This document is the source of truth for **how SUNK's `slurmd` runs on each
supported cloud, and why**. It explains the threat model, lays out a per-cloud
posture matrix, calls out the cache-dropper invariant, and gives customers
running their own Kubernetes (BYO Ubuntu, k3s, etc.) the information they need
to assess fit.

The goal posture for SUNK is **capabilities-only** (no `privileged: true`).
We get there everywhere we can. EKS AL2023 is the one cloud where stock
kubelet defaults still force `privileged: true` today; the matrix below
explains exactly why and points to the evidence.

If you are reading this to decide whether to change the posture in your
environment, read all the way through before editing any values file. Most
of the obvious tightenings are already considered here and come with
non-obvious tradeoffs.

---

## TL;DR per cloud

- **EKS AL2023**: `privileged: true` + capability list, AppArmor disabled,
  custom seccomp disabled, Slurm cgroup constraints off. Forced by AL2023's
  default kubelet `cgroup-namespace=host`. Evidence: 7-cell test campaign
  (cells 3a-3g, see [Tested alternatives](#tested-alternatives-2026-04-28)).
- **GKE COS**: capabilities-only is the target; smoke test pending. Pyxis is
  off by default until we ship an AppArmor profile loader.
- **Generic K8s / BYO Ubuntu / k3s**: capabilities-only is the target;
  smoke test pending. k3s defaults to `cgroup-namespace=pod`, which is why
  customers running k3s report unprivileged slurmd works for them.

---

## Threat model

The trust boundary is: **"everything authenticated on the login pod"** is
inside the trust circle.

**In the trust circle:**

- The slurmd container image (pulled from GHCR, pinned tag in
  `helm-values/base/slurm-values.yaml`)
- Every Linux/LDAP user with a shell on the login pod
- Every container image users `srun --container-image=` with
- IRSA / pod-identity / workload-identity credentials attached to the
  slurmd ServiceAccount

**Outside the trust circle:**

- Unauthenticated network traffic (the login Service enforces TCP/22 key-only SSH)
- Other pods on the same node (pod/namespace boundary still enforced by kubelet)
- The host root filesystem outside chart-provided hostPath volumes
- Other nodes in the cluster (Slurm cgroup compromise is node-local)

### What a compromised slurmd looks like

If a user job achieves RCE as the LDAP user inside a slurmd pod:

- They can read `/proc/1/environ` of slurmd (injected env + pod-identity token paths)
- They can read any file the slurmd container can read, including
  `/var/run/secrets/...` mounts for any ServiceAccount binding
- With `SYS_ADMIN`, they can mount arbitrary host paths if those host paths
  are already declared as `hostPath` volumes — they cannot enumerate or
  reach paths not declared at pod-spec time
- They **cannot** escape to other pods on the same node without exploiting
  the kernel itself — pod namespaces are still enforced

If they then escalate to the slurmd process (which runs as root inside the
pod, not the LDAP user):

- Full root on everything the pod can see
- Can write to any `hostPath` mount (on GPU nodes: `/opt/dlami/nvme/enroot`
  or equivalent)
- Can see pod-identity tokens, registry pull creds, the SUNK JWT
- Can use `SYS_PTRACE` to inspect other pod processes — but with
  `hostPID: false` (chart default), the only "other processes" visible are
  slurmd's own

### What they cannot do

- Escape `hostNetwork: false` — still subject to cluster NetworkPolicy
- Break into other pods on the node — kubelet enforces the pod boundary via
  cgroups + namespaces, and the chart does not grant `hostPID` or `hostNetwork`
- Compromise the cluster control plane — control-plane traffic uses separate auth

The realistic worst case: one compromised node. This is the same worst case
as any traditional Slurm HPC cluster with privileged-root `slurmd`.

### Mitigations we rely on

1. **`hostPID: false`, `hostNetwork: false`** — chart defaults. If a cluster
   admin flips these, the blast radius changes qualitatively. Don't.
2. **Dedicated compute nodegroups** — `cpu-workers` and `gpu-workers` are
   for Slurm only. Other tenant workloads go elsewhere.
3. **Spot + scale-to-zero** — the compute nodegroup is frequently replaced,
   limiting any foothold to the node lifecycle.
4. **Lock taint** — `sunk.coreweave.com/lock=true:NoExecute` evicts non-Slurm
   pods off the node as soon as Slurm takes it, so there is typically no
   co-tenant to pivot to.
5. **Tight pod-identity role** — the ServiceAccount bound to compute pods
   should have only the cloud permissions the workload needs. Scope aggressively.

---

## Per-cloud posture matrix

| Cloud | Default posture | Why | Evidence |
|---|---|---|---|
| **EKS AL2023** | privileged-default (`privileged: true`, caps `SYS_NICE`/`SYS_ADMIN`/`SYS_PTRACE`/`SYSLOG`, AppArmor off, custom seccomp off, Slurm `Constrain*` off) | AL2023's stock kubelet runs pods with `cgroup-namespace=host`, which read-only-mounts `/sys/fs/cgroup` into unprivileged containers. slurmd writes `/sys/fs/cgroup/system{,.slice}` unconditionally at startup, so any unprivileged variant crashes with `EROFS` before serving. Adding caps does not unlock the read-only mount; bind-mounting a writable cgroup just exposes the host-pid-namespace mismatch instead. | Cells 3a-3g in [Tested alternatives](#tested-alternatives-2026-04-28) |
| **GKE COS** | capabilities-only (target) — TBD pending smoke test | GKE COS does not expose the same cgroup-namespace problem as EKS AL2023 in our scoping notes, and pyxis is off by default on GKE today (the COS AppArmor profile for enroot is not preinstalled, so the chart's `localhost/enroot` annotation would block admission). | Smoke test scheduled separately |
| **Generic K8s / BYO Ubuntu / k3s** | capabilities-only (target) — TBD pending smoke test. Customers running k3s on Ubuntu 24.04 today report unprivileged slurmd works | k3s defaults to `cgroup-namespace=pod`, which gives the slurmd container its own writable cgroup view; the EKS-AL2023 EROFS problem does not appear there. Ubuntu 24.04 is required for the NVIDIA enroot AppArmor profile (it uses `abi <abi/4.0>`, which AppArmor 3.x on Ubuntu 22.04 cannot parse). | Smoke test scheduled separately |

> The "TBD" rows above represent the goal — capabilities-only without
> `privileged: true` — once the corresponding smoke test confirms it. They
> are not aspirational guesses; they are claims that need one cell of
> evidence each.

---

## Cache-dropper invariant

`compute.cacheDropper.enabled: true` reintroduces a privileged container
into the compute pod. It runs as root and writes to host caches. Customers
who flip it on are explicitly opting back into a privileged surface for the
sake of cache-clearing benchmarks. **Default is `false` in both
`helm-values/base/slurm-values.yaml` and the EKS overlay**, so out of the
box the privileged surface is bounded to slurmd itself.

**Default-off limits the privileged-container blast radius** to slurmd
itself; turning the cache-dropper on roughly doubles it. If you are running
a posture audit, flag any overlay where `compute.cacheDropper.enabled` is
true and confirm the operator is aware.

---

## Customer-DIY: BYO Ubuntu / k3s

The "sunk-anywhere" path that customers most often DIY is Ubuntu 24.04 EC2
(or equivalent) with k3s. This is the path closest to "capabilities-only,
no privileged, AppArmor on" today.

### Required:

- **Ubuntu 24.04 recommended** (over 22.04). Two AppArmor profiles are in
  play and it pays to know which one your tooling picks up:
  - **Upstream NVIDIA enroot profile** (shipped by the `enroot` package on
    Ubuntu) starts with `abi <abi/4.0>`, which AppArmor 3.x on Ubuntu 22.04
    cannot parse — the profile fails to load and any pod annotated for it
    fails admission or is silently ignored depending on kubelet version.
    Ubuntu 24.04 ships AppArmor 4.x and parses it cleanly.
  - **CoreWeave canonical profile** vendored in this repo at
    `infrastructure/universal/apparmor-profiles/enroot.profile`. It does NOT
    use `abi <abi/4.0>` and parses on AppArmor 3.x. If you choose to load
    this one instead of the upstream profile, the AppArmor-version blocker
    on 22.04 goes away — but 24.04 remains the recommended target for the
    rest of the stack (newer kernel, better cgroup-v2 ergonomics).
- **k3s** (or any kubelet started with `--cgroup-namespace-mode=pod`).
  k3s sets this by default; stock kubelet on EKS AL2023 does not.
- **NVIDIA driver + nvidia-container-toolkit** installed on every GPU node
  before slurmd starts.

### AppArmor profile sourcing

The canonical CoreWeave AppArmor profile is vendored at
`infrastructure/universal/apparmor-profiles/enroot.profile` (profile name:
`enroot`, matching the chart's `localhost/enroot` annotation).
`infrastructure/universal/apparmor-installer-daemonset.yaml` ships a
DaemonSet that installs it onto each node and reloads `apparmor_parser`;
it is a no-op on hosts without `apparmor_parser` (AL2/AL2023/Bottlerocket).

If you prefer not to apply the DaemonSet, install manually on each node:

1. Copy `infrastructure/universal/apparmor-profiles/enroot.profile` to
   `/etc/apparmor.d/enroot`, and
2. Run `apparmor_parser -r /etc/apparmor.d/enroot` (or reload via your
   config-management of choice).

Live-cluster acceptance for the DaemonSet path is gated behind the
Ubuntu smoke tests; the YAML is reviewed and dry-run-validated but
has not yet been exercised on an AppArmor-enforcing host.

### Verification:

```bash
# Confirm cgroup namespace is per-pod (not host) on a node:
sudo cat /proc/$(pgrep -f kubelet | head -1)/status | grep -i cgroup
# Look for "Cgroups: ..." consistent with per-pod namespacing.

# Confirm AppArmor profile is loaded on a node:
sudo aa-status | grep enroot
```

---

## Why we did not unify on capabilities-only

Capabilities-only **is** the goal. We just cannot unify on it yet because
EKS AL2023 — by far the most-requested target — fails on stock kubelet
defaults. The blocker is not the chart and not Slurm; it is kubelet's
`cgroup-namespace=host` default, which is fixed at node-bring-up time and
not reachable from a Helm value.

Two paths get us to one unified capabilities-only posture across clouds:

1. **Kubelet config change**: ship guidance and (eventually) a managed
   knob that flips the EKS GPU/CPU nodegroup to
   `--cgroup-namespace-mode=pod`. This requires a kubelet config patch
   shipped via the EKS managed-nodegroup launch template; it is tracked
   as a follow-up experiment.
2. **slurmd patch**: get slurmd upstream to skip the
   `/sys/fs/cgroup/system{,.slice}` writes when running inside a pod-scoped
   cgroup. Larger lift, requires upstream coordination.

Until one of those lands, EKS gets the privileged-default posture and other
clouds get capabilities-only as their default once the smoke tests confirm.

---

## Why privileged is required on EKS AL2023 (deep dive)

### `slurmd` needs to manage cgroups

Slurm's job isolation — `--mem`, `--cpus-per-task`, `--gres=gpu:N`, job-step
namespacing — is implemented via Linux cgroups. `slurmd` writes into
`/sys/fs/cgroup/...` at job launch and at startup to set up per-step limits.

On EKS (AL2023 default, AL2 legacy), the cgroup hierarchy is owned by **host
systemd** (v2) or by the kubelet (v1). Pods see the cgroup sysfs, but most
controller files are either read-only or owned outside the pod's user
namespace. A non-privileged pod, even with targeted caps like `CAP_SYS_ADMIN`
alone, cannot reliably write to the cgroup tree from inside the pod.

The working combination on both AL2 and AL2023 is:

- `privileged: true` (drops the user-namespace restriction on the cgroup sysfs)
- `SYS_ADMIN` (mount operations, cgroup writes)
- `SYS_NICE` (set process scheduling priority, used by Slurm step launchers)
- `SYS_PTRACE` (required by some enroot container introspection and by Slurm's
  task/prolog scripts that inspect child processes)
- `SYSLOG` (enroot reads `/dev/kmsg` for nvidia-container-toolkit diagnostics)

Dropping `privileged: true` and keeping only the caps above **does not work**:
you get `EPERM` on cgroup writes because the cgroup FS is mounted with
`nosuid,noexec,nodev` and owned by a different user namespace.

### pyxis/enroot needs mount, chroot, unshare

`--container-image=...` runs enroot inside the slurmd pod. Enroot does:

- `unshare(CLONE_NEWNS | CLONE_NEWUSER)` to create a new mount/user namespace
- `mount(2)` to bind-mount the container rootfs and /etc/passwd/group/etc
- `chroot` / `pivot_root` into the container

All three require `CAP_SYS_ADMIN`, and the `mount` syscall is blocked by
containerd's `RuntimeDefault` seccomp profile without privileged.

### The four capabilities, explained

| Cap | Why Slurm needs it | Blast radius if slurmd is compromised |
|---|---|---|
| `SYS_ADMIN` | cgroup writes, mount(2), unshare(CLONE_NEWNS) for enroot, setns() for task launch | Effectively full root in the pod's namespaces; with privileged, full root on host devices/FS visible to the pod |
| `SYS_NICE` | setpriority/sched_setscheduler for job priority | Minor; local DoS via priority inversion within the node |
| `SYS_PTRACE` | ptrace children for step accounting; enroot container introspection | Can attach to any process the pod can see. With `hostPID: false` (chart default) this is limited to pod processes — **keep hostPID off** |
| `SYSLOG` | read `/dev/kmsg` for driver diagnostics (nvidia-container-toolkit) | Reads kernel ring buffer. Information disclosure: kernel pointers, hardware topology, driver versions. Not a write vector |

`SYS_ADMIN` is the load-bearing one. The others are auxiliary. Removing any
of the four breaks one of Slurm's code paths in hard-to-diagnose ways
(especially `SYS_PTRACE`, which surfaces as "Step-launch failed" deep in the
accounting subsystem).

### cgroup v2 on EKS

EKS AMI defaults:

| AMI | Cgroup mode |
|---|---|
| AL2 (legacy, pre-1.27) | cgroup v1 hybrid (legacy + unified) |
| AL2023 (current default) | cgroup v2 unified |
| Bottlerocket | cgroup v2 unified |
| Ubuntu EKS AMI | cgroup v2 unified |

The unified cgroup v2 tree is owned by host systemd. Pods see the tree via
the kubelet-mounted cgroup v2 sysfs. When slurmd runs inside a pod and tries
to set up per-task cgroups, it has two options:

1. **Ask systemd via D-Bus** to create a transient scope. From inside a k8s
   pod there is no D-Bus socket to the host systemd, and the pod's own
   systemd (if any) does not own the host hierarchy. This does not work.
2. **Write directly** to the cgroup sysfs. With privileged + `SYS_ADMIN`,
   slurmd can create sub-scopes under the pod's own cgroup and write
   controller files. Slurm's `Constrain{Cores,Devices,RAMSpace}` flags fail
   with `EACCES` at the root level even here, so we set them to `no` and
   rely on the k8s pod limits as the enforcement boundary.

Resolution, matching the customer production pattern:

```yaml
slurmConfig:
  cgroupConfig:
    CgroupPlugin: cgroup/v2
    IgnoreSystemd: yes
    ConstrainCores: no
    ConstrainDevices: no
    ConstrainRAMSpace: no
```

**Consequence**: Slurm does not enforce CPU / memory / GPU limits per task.
A user job requesting `--cpus-per-task=1` and `--mem=1G` is free to use all
cores and memory on the node. The k8s pod limits
(`compute.nodes.<ng>.resources.limits.cpu/memory`) become the only
enforcement boundary.

If you need per-task enforcement, run one slurmd per node (dedicated
nodegroup). The "production customer" pattern we sourced this from runs one
slurmd per `p4de.24xlarge`, each user job getting the whole node.

---

## Tested alternatives (2026-04-28)

Before settling on the privileged posture documented above, we ran a 7-cell
test campaign against a live EKS AL2023 cluster (`m5.large` CPU workers,
default kubelet) varying `securityContext`, seccomp profile, AppArmor
annotation, and Slurm cgroup plugin.

| Cell | Privileged | seccomp | AppArmor | Outcome | Failure mode (concrete) |
|---|---|---|---|---|---|
| 3a | true | RuntimeDefault | (none) | Running | Baseline — slurmd Ready, all caps effective |
| 3b | false | RuntimeDefault | (none) | CrashLoopBackOff | `unable to create cgroup '/sys/fs/cgroup/system' : Read-only file system` |
| 3c | true | RuntimeDefault | `localhost/enroot` | Pending | kubelet: `Cannot enforce AppArmor: AppArmor is not enabled on the host` (the host-level admission gate fires before profile-name resolution, so the result is identical regardless of which profile name is requested) |
| 3d | false | RuntimeDefault | `localhost/enroot` | Pending | Same kubelet AppArmor block as 3c (admission gate fires before runtime) |
| 3e | false | Localhost (caps: SYS_NICE, SYS_ADMIN, SYS_PTRACE, SYSLOG) | (none) | CrashLoopBackOff | Same cgroup EROFS as 3b — adding caps does not unlock the read-only mount |
| 3f | false | Localhost (caps + `ProctrackType=proctrack/linuxproc` + `TaskPlugin=task/affinity`) | (none) | CrashLoopBackOff | Same cgroup EROFS — slurmd's image entrypoint AND the slurmd binary itself write `/sys/fs/cgroup/{system.slice,system}` regardless of plugin choice |
| 3g | false | Localhost (caps + cgroup hostPath rw mount) | (none) | CrashLoopBackOff | New failure: `cgroup mountpoint does not align with the current namespace ... cgroup /sys/fs/cgroup contains pids from outside of our pid namespace, so we cannot manage this` |

The standard EKS AL2023 kubelet runs pods with `cgroup-namespace=host`, so
slurmd inside an unprivileged pod sees the host cgroup tree as read-only and
cannot create the scopes it needs — and bind-mounting a writable cgroup
mount just exposes the host-pid-namespace mismatch instead. None of the
chart-values permutations available today (capability sets, custom seccomp,
custom AppArmor, alternate proctrack/task plugins, custom cgroup mounts)
get an unprivileged slurmd to Running on stock EKS. The long-term path
requires kubelet configuration changes outside the chart's reach
(`--cgroup-namespace-mode=pod`), tracked separately as a follow-up
experiment.

---

## Hardening knobs

Customers / agents evaluating whether to tighten this should look at these
options, in roughly increasing order of effort:

### Drop `SYS_PTRACE` and `SYSLOG`

`SYSLOG` is only read by the NVIDIA container toolkit during diagnostic
dumps, and `SYS_PTRACE` is mainly used for Slurm accounting. Dropping both
reduces the info-disclosure surface without breaking core Slurm scheduling.

**Risk**: job accounting for GPU jobs may have gaps; `nvidia-smi` failures
inside enroot containers may log less detail. Test with your workload.

### Run one slurmd per node

Set the nodegroup to dedicated instances and make the slurmd pod claim the
whole node via resource requests. Then the multi-tenant-fairness concern
from the cgroup section disappears — there is no tenant to share with.

### Dedicate a nodegroup per tenant

Add a `tenant=<X>` taint + toleration to each nodegroup, and use Slurm
partitions to route each tenant's jobs to their own nodes. Blast radius
of a slurmd compromise is bounded to one tenant's nodegroup.

### Use Bottlerocket for compute

Bottlerocket ships with an immutable root FS, SELinux in enforcing mode,
and an update mechanism that replaces whole nodes rather than patching
them. Larger lift, substantially raises the cost of a host-level compromise.

### Drop privileged entirely (not yet possible on EKS)

Tracked as a follow-up. Two viable paths:

- Kubelet config change to `--cgroup-namespace-mode=pod` on the EKS
  managed nodegroup, then re-run cell 3e — expectation is slurmd reaches
  Running with caps-only.
- slurmd upstream patch to skip `/sys/fs/cgroup/system{,.slice}` writes
  when running inside a pod-scoped cgroup.

---

## FAQ

**Q: Why not just set `allowPrivilegeEscalation: false` and the caps above?**

A: The caps alone do not grant the ability to write to cgroup controllers
that a different user namespace owns. `privileged: true` does two things:
it grants every cap (which we narrow with the explicit list as
documentation), *and* it lifts the user-namespace restriction on host
resources visible to the pod. We need both on EKS AL2023.

**Q: Can I use Pod Security Standards `restricted`?**

A: Not on EKS AL2023. SUNK-on-EKS compute pods require `privileged`, which
is incompatible with both `baseline` and `restricted` PSS levels. Use PSS
`privileged` for the namespace that holds compute pods. On clouds where we
land at capabilities-only, `baseline` may be reachable; confirm with the
matching smoke test.

**Q: Our compliance team will not allow `privileged: true`. What now?**

A: Three paths, in order of effort:

1. Run SUNK on CoreWeave Cloud (not EKS). CoreWeave nodes use a custom AMI
   where privileged is not needed. This repo is "sunk-anywhere" precisely
   because the CoreWeave-native path avoids this trade.
2. Run on a cluster with `cgroup-namespace=pod` (k3s today; managed EKS
   once the kubelet-config follow-up lands).
3. Run EKS with a dedicated nodegroup per tenant — risk is bounded.

---

## See also

- [`docs/eks/eks-adaptations.md`](../eks/eks-adaptations.md) — quick diff
  table vs. the GKE reference
- [`docs/eks/deployment-guide.md`](../eks/deployment-guide.md) —
  step-by-step walkthrough
- [`docs/eks/troubleshooting.md`](../eks/troubleshooting.md) — symptom /
  cause / fix for posture-related issues
- `helm-values/eks/slurm-values.yaml` — the actual values file
- `helm-values/base/slurm-values.yaml` — provider-agnostic defaults
- `infrastructure/universal/apparmor-profiles/enroot.profile` — canonical
  CoreWeave AppArmor profile (vendored)
