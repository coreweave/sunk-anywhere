# Interpreting Core Dump Results

## Contents
- Failure cascades
- Slurm node states
- Common drain reasons
- GPU health
- Cgroup / CPU / memory
- SUNK CRD health
- Storage

## Failure Cascades

The three most common failure cascades, all caused by the lock taint evicting system pods:

| Root Cause | Symptoms | Check |
|------------|----------|-------|
| cert-manager evicted | Certificates expire → MOCO MySQL fails → Slurm accounting fails | `services/cert-manager-pods.txt` shows no Running pods |
| Connectivity agent evicted | `kubectl exec` fails → appears everything is broken, but pods are actually running | `network/exec-test.txt` fails; `services/kube-system-pods.txt` shows evicted agent pods |
| Syncer down | Slurm nodes drain → jobs fail, new nodes never join | `sunk/pods.txt` shows syncer not Running; `slurm-state/drained-nodes.txt` has many entries |

## Slurm Node States

| State | Meaning | What to Check |
|-------|---------|---------------|
| `idle` | Healthy, available | Normal |
| `alloc` | Running jobs | Normal |
| `mix` | Partially allocated | Normal |
| `drain` / `drained` / `draining` | Manually or auto-drained | `slurm-state/drained-nodes.txt` for reason |
| `down` / `down*` | Unreachable | `slurm-state/down-nodes.txt`; check pod status in `slurm-k8s/pods.txt` |
| `INVALID_REG` | GRES mismatch | Compare `slurm-k8s/gres-conf.yaml` with `gpu/<pod>_nvidia-smi.txt` |

## Common Drain Reasons

| Reason | Meaning | Resolution |
|--------|---------|------------|
| `Prolog error` | Syncer pre-hook failed | Check syncer logs; may auto-resolve |
| `Prolog hung` | Syncer pre-hook timed out | Check syncer health and connectivity |
| `gres/gpu count reported lower` | NVML failure or GPU disappeared | Check `gpu/<pod>_nvidia-smi.txt` and dmesg |
| `k8s: pod terminated` | Compute pod was deleted | Check if pod was recreated; if not, NodeSet issue |
| `k8s: pod deletion timeout` | Epilog timeout exceeded KillWait | Check `slurm-state/killwait-prolog.txt` for KillWait value |
| `Kill task failed` | slurmctld couldn't kill a task | Node stays drained; may need manual undrain |

## GPU Health

| Signal | Meaning |
|--------|---------|
| 100% utilization + 0 MiB memory in nvidia-smi | Phantom GPU — orphaned kernel context. Check `gpu/<pod>_gpu-fuser.txt` |
| `nvidia-smi: command not found` | NVIDIA driver not mounted. Check s6 nvidia-setup in Helm values |
| Missing GPUs (count mismatch) | Hardware failure. Check `gpu/gpu-node-conditions.txt` |
| Xid errors in dmesg | GPU hardware issue. Xid 31=MMU fault, 43=GPU fault, 145=NVLink/NVSwitch |
| GPU node condition status=True | Provider health check failed (conditions are problems — True means problem exists) |

## Cgroup / CPU / Memory

| Signal | Meaning |
|--------|---------|
| cgroup v1 on a cluster running Slurm 25.11+ | Deprecated — Slurm 25.11 requires v2 for full task/cgroup support |
| `cpu.max` shows throttled (not "max") | Pod has CPU limits — jobs may run slower than expected |
| `memory.events` shows `oom` > 0 | OOM kills have occurred — check if `memory.max` matches Slurm's `RealMemory` |
| `pids.current` near `pids.max` | PID exhaustion — jobs will fail with fork errors |
| `nproc` differs from Slurm's `CPUTot` for the node | CPU count mismatch — node may show wrong capacity in Slurm |
| `ptrace_scope` = 1 or higher | `gcore` won't work for non-root users — only signal-generated core dumps |
| `core_pattern` empty or pointing to `/dev/null` | Core dumps disabled — set `kernel.core_pattern` if debugging crashes |

## SUNK CRD Health

In `sunk/nodesets.yaml`:
- `status.numberReady` should equal `status.desiredNumberScheduled`
- `status.numberDrain` > 0 means nodes are being drained
- `status.numberUnavailable` > 0 means capacity shortfall

In `sunk/sunkclusters.yaml` or `sunk/slurmclusters.yaml`:
- Check `.status.conditions` — all should have `status: "True"` for healthy conditions
- Key conditions: `Ready`, `SlurmClusterAvailable`, `NodeSetsAvailable`, `CertManagerAvailable`

## Storage

- `slurm-k8s/pvcs.txt`: All PVCs should be `Bound`. Pending PVCs block MySQL/MOCO startup.
- `slurm-state/mounts.txt`: NFS should be mounted at `/home`. Missing mount = shared filesystem broken.
