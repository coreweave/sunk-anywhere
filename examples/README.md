# Slurm Test Suite

End-to-end smoke tests for a SUNK deployment. Each test runs ~1–2 min, asserts
completion, and skips cleanly when prerequisites aren't met.

## How to run

From a host with `kubectl` access to the cluster:

```bash
./examples/run-all.sh                       # run everything applicable
./examples/run-all.sh --dry-run             # print what would run
./examples/run-all.sh --only=02-sbatch-cpu-job.sh   # single test
./examples/run-all.sh --ns=tenant-slurm --login-pod=slurm-login-0
```

`run-all.sh` copies the shell tests into `slurm-login-0:/home/examples`
(shared NFS, survives pod restarts) and executes each via `kubectl exec`. YAML
tests are `kubectl apply`'d from the host. Test 16 is host-side because it
orchestrates both a pod and a Slurm job concurrently.

## Exit-code contract

Every test returns:

- `0` — PASS
- `1` — FAIL
- `2` — SKIPPED (precondition not met; not a failure)

`run-all.sh` aggregates: exit 0 if no FAIL, exit 1 otherwise.

## Tests

| #   | Name                              | What it proves                                    | Min requirements                                    |
| --- | --------------------------------- | ------------------------------------------------- | --------------------------------------------------- |
| 01  | basic-srun.sh                     | `srun hostname` works                             | 1 node in `$PARTITION` (default cpu-workers)        |
| 02  | sbatch-cpu-job.sh                 | sbatch lifecycle: submit → run → sacct COMPLETED  | 1 node in cpu-workers                               |
| 03  | gpu-stress-test.sh                | `nvidia-smi` on a GPU via Slurm                   | gpu-workers partition exists, ≥1 node               |
| 04  | validate-pod-scheduler.yaml       | 1 pod via SUNK Pod Scheduler reaches Running      | SUNK pod scheduler wired up                         |
| 07  | multi-node-srun.sh                | srun -N 2 returns 2 distinct hostnames            | ≥2 nodes in cpu-workers                             |
| 08  | array-job.sh                      | array 1–4 all COMPLETED                           | ≥1 node in cpu-workers                              |
| 09  | job-dependency.sh                 | afterok chain: B starts after A completes         | ≥1 node in cpu-workers                              |
| 10  | cpu-share.sh                      | two small jobs pack on the SAME node              | ≥1 node with ≥2 free CPUs                           |
| 11  | different-nodes.sh                | two `--exclusive` jobs land on DIFFERENT nodes    | ≥2 nodes in cpu-workers                             |
| 12  | hetjob.sh                         | heterogeneous job: both components COMPLETED      | ≥2 nodes in cpu-workers                             |
| 13  | nccl-test.sh                      | NCCL all_reduce_perf                              | ≥2 GPUs total (inter- or intra-node)                |
| 14  | overcommit-mem.sh                 | `--mem=100G` stays PENDING w/ resource reason     | ≥1 node in cpu-workers                              |
| 15  | multi-pod-scheduler.yaml          | 3 pods via pod scheduler all Succeed              | SUNK pod scheduler wired up                         |
| 16  | pod-and-slurm-concurrent.sh       | pod + Slurm job in parallel, both finish cleanly  | ≥1 node in cpu-workers, host-side kubectl           |
| 17  | pyxis-container.sh                | `srun --container-image=alpine` runs in-container | `compute.pyxis.enabled: true` + seccomp profile     |
| 18  | salloc-overlap.sh                 | 3 `srun --overlap` steps share one allocation     | ≥1 node in cpu-workers                              |
| 19  | vscode-tunnel.sh (opt-in)         | install `code` CLI; smoke or interactive tunnel   | HTTPS egress; GitHub auth for interactive mode      |

### Test 13 NCCL prerequisites (GKE-specific notes)

`13-nccl-test.sh` skips with `SKIPPED: NCCL needs >=2 GPUs total` until the
cluster has at least two GPUs reachable to Slurm. On GKE the full set of
prerequisites is:

- `GPUS_ALL_REGIONS >= 2` (project-global accelerator quota) **and**
  `NVIDIA_<TYPE>_GPUS >= 2` in the target region — both are enforced
  separately.
- GKE GPU node pool with `--num-nodes=2` (two 1-GPU nodes), or a single
  node with `>=2` GPUs (e.g. `g2-standard-24`).
- Slurm `compute.nodes.gpu-workers.replicas: 2` in
  `helm-values/gke/slurm-values.yaml` when scaling out across two 1-GPU
  nodes.
- `bash infrastructure/gke/sunk-post-upgrade.sh` after the scale-up so
  `gres.conf` contains one
  `NodeName=<gpu-pod> Name=gpu Type=<type> File=/dev/nvidia0` line per
  GPU worker pod.
- `/opt/nccl-tests/build/all_reduce_perf` (or the standard
  `all_reduce_perf` binary) present in the GPU worker container image.
  When the binary is missing, the test fails with a payload error, not a
  scheduler error.

A 1-GPU GKE cluster should report this test as `SKIPPED`, never `FAIL`.

### Opt-in tests

`19-vscode-tunnel.sh` is not in the default matrix. Run via
`bash run-all.sh --only=19-vscode-tunnel.sh`. Two modes:

- Default (smoke): sbatch job downloads the VS Code CLI and verifies
  `code --version` and `code tunnel --help` on a compute node. Validates
  egress and image compatibility.
- Interactive: set `VSCODE_TUNNEL_INTERACTIVE=1` (and optionally
  `VSCODE_TUNNEL_NAME=my-tunnel`). The test allocates a node, installs
  the CLI, and runs `code tunnel` in the foreground so the GitHub
  device-code URL is visible. Connect from your local VS Code to the
  named tunnel, then `scancel $JID` when you're done.

## Skip decisions

`run-all.sh` does NOT pre-decide skips; each test probes its own
preconditions and returns 2 if unmet. The pattern is deliberate:

- New tests can be added with their own skip logic — the runner doesn't need
  to know about them.
- If the cluster state changes between the probe and the test, the test
  re-checks.
- The skip reason is printed by the test itself, so failures to skip are
  visible, not silent.

The only cluster-wide probe run-all.sh does up front is a capability summary
(node count, partitions) printed for context.

## Budget profile notes

Tests assume the budget profile in `helm-values/eks/slurm-values.yaml`:

- m5.large (2 vCPU / 8 GiB) for cpu-workers, scaled 0..2.
- `DefMemPerCPU=3000` pinned per-partition. Jobs that don't pass `--mem`
  will request 3 GiB per CPU, which can fail scheduling on 8 GiB nodes once
  the system reserve is factored in. Every test here passes an explicit
  `--mem` to dodge that trap. See `deploy-notes.md` BUG #9.
- `gpu-workers` is opt-in (`enabled: false` by default); GPU-dependent tests
  skip with a clear reason when the partition is absent.

## Cleanup

Each test cancels its own jobs on exit via `trap`. YAML tests are
`kubectl delete`'d by run-all.sh immediately after assertion. Test 16
deletes its pod on exit. Running the whole suite twice in a row is safe.
