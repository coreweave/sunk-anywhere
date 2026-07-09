---
name: connect-skypilot-to-sunk
description: >
  Connect SkyPilot to SUNK (Slurm on Kubernetes) clusters for GPU workload submission.
  Covers single-cluster setup and multi-cluster configurations across any provider.
  Use when: setting up SkyPilot with SUNK, configuring SSH for Slurm login nodes,
  troubleshooting SkyPilot catalog errors, launching SkyPilot jobs on Slurm,
  or adding clusters to a multi-cluster SkyPilot config. Trigger phrases:
  "connect SkyPilot to SUNK", "SkyPilot Slurm", "sky launch on SUNK".
---

# Connect SkyPilot to SUNK

This skill walks through connecting SkyPilot to one or more SUNK clusters so you can submit GPU and CPU workloads via `sky launch`.

## Prerequisites

- A running SUNK cluster with working compute nodes (`sinfo` shows nodes in `idle` state)
- User authentication configured (SSSD, manual `useradd`, or SCIM), or manual user creation on the login node
- SSH access to the login node (via port-forward or LoadBalancer)
- Python 3.10+ on the local machine
- `kubectl` access to the cluster running SUNK

## Step 1: Install SkyPilot

Run this on your **local machine**, not on the login node:

```bash
pip install "skypilot-nightly[slurm]"
```

The `[slurm]` extra pulls in the Slurm cloud connector. The nightly build is required because Slurm support is not yet in stable releases.

## Step 2: Set Up SSH Access to the Login Node

You need SSH connectivity from your local machine to the Slurm login node. Pick one option.

### Option A: Port-Forward (dev/test)

```bash
kubectl port-forward -n tenant-slurm svc/slurm-login 2222:22 &
```

This maps `localhost:2222` to the login node's SSH port. Quick for development but requires the port-forward process to stay running.

### Option B: LoadBalancer (production)

Set `login.service.type: LoadBalancer` in your provider's `helm-values/<provider>/slurm-values.yaml`, then upgrade:

```bash
helm upgrade slurm coreweave/slurm \
  -n tenant-slurm -f helm-values/<provider>/slurm-values.yaml \
  --set-json 'global.nodeSelector.affinity=null'
```

Get the external IP:

```bash
kubectl get svc -n tenant-slurm slurm-login -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

### Set Up SSH Keys on the Login Node

Inject your public key into the login node for your user:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- bash -c '
  mkdir -p /home/USERNAME/.ssh
  echo "YOUR_SSH_PUBLIC_KEY" > /home/USERNAME/.ssh/authorized_keys
  chown -R UID:GID /home/USERNAME
  chmod 700 /home/USERNAME/.ssh
  chmod 600 /home/USERNAME/.ssh/authorized_keys
'
```

Replace `USERNAME`, `YOUR_SSH_PUBLIC_KEY`, `UID`, and `GID` with actual values. Get UID/GID with `id USERNAME` on the login node.

SkyPilot requires `.bashrc` and `.bash_profile` to exist. Create them if missing:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- su - USERNAME -c 'touch ~/.bashrc ~/.bash_profile'
```

## Step 3: Configure SkyPilot

Create `~/.slurm/config` (this is SkyPilot's SSH config for Slurm clusters, NOT `~/.ssh/config`):

```
Host sunk-cluster
    HostName localhost
    User USERNAME
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

If using a LoadBalancer (Option B), set `HostName` to the external IP and `Port` to `22`.

## Step 4: Verify the Connection

```bash
sky check slurm
```

Expected output should show:

```
Slurm: enabled
  sunk-cluster: enabled
```

List available GPUs:

```bash
sky gpus list --cloud slurm
```

## Step 5: Launch Test Jobs

### CPU Test

Save as `test-cpu.yaml`:

```yaml
resources:
  cloud: slurm
  memory: 0.5

run: |
  echo "Hello from SkyPilot on SUNK!"
  hostname
  sinfo
```

Launch:

```bash
sky launch -c test-cpu test-cpu.yaml
```

### GPU Test

Save as `test-gpu.yaml`:

```yaml
resources:
  cloud: slurm
  accelerators: L4:1
  memory: 0.5

run: |
  nvidia-smi
```

Launch:

```bash
sky launch -c test-gpu test-gpu.yaml
```

## Important: SkyPilot Catalog and Memory

SkyPilot builds its instance catalog from Slurm's reported `RealMemory` on each node. On small nodes (for example, nodes with 512MB container memory limits), the catalog entries have very low memory values.

**You MUST explicitly request low memory** (e.g., `memory: 0.5` for 512MB nodes). Without it, SkyPilot defaults to requesting ~2GB and fails with:

```
Catalog does not contain any instances satisfying the request
```

This is not a bug. Larger nodes (production clusters with tens of GB of RAM) do not have this issue. Only small dev/test node pools hit this.

## Bare-Metal vs Container Mode

On managed Kubernetes providers (GKE, EKS) without Pyxis/enroot configured, SkyPilot runs in **bare-metal mode only**. Do not use the `image_id` field in your SkyPilot YAML unless the cluster has Pyxis properly configured.

Container mode (via Pyxis) is available on clusters that have Pyxis enabled and the required seccomp profiles installed.

---

## Multi-Cluster Setup

SkyPilot supports multiple Slurm clusters simultaneously. Add additional `Host` entries to `~/.slurm/config`:

```
Host sunk-gcp
    HostName localhost
    User USERNAME
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host sunk-aws
    HostName EKS_LOGIN_NODE_IP
    User USERNAME
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host cw-ml-dev
    HostName LOGIN_NODE_IP
    User USERNAME
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

### CoreWeave SSH Key Setup

CoreWeave clusters use SSSD (`sss_ssh_authorizedkeys`) for key lookup, but OpenSSH also checks `~/.ssh/authorized_keys` as a fallback.

**Critical**: On CoreWeave clusters, the home directory is usually `/mnt/home/USERNAME`, NOT `/home/USERNAME`. Always verify the actual path:

```bash
kubectl --context=CW_CONTEXT exec -n tenant-slurm slurm-login-0 -c sshd -- \
  getent passwd USERNAME | cut -d: -f6
```

Place your SSH key at the correct path:

```bash
kubectl --context=CW_CONTEXT exec -n tenant-slurm slurm-login-0 -c sshd -- bash -c '
  HOMEDIR=$(getent passwd USERNAME | cut -d: -f6)
  mkdir -p $HOMEDIR/.ssh
  echo "YOUR_PUBLIC_KEY" >> $HOMEDIR/.ssh/authorized_keys
  chmod 700 $HOMEDIR/.ssh
  chmod 600 $HOMEDIR/.ssh/authorized_keys
  chown -R UID:GID $HOMEDIR/.ssh
'
```

Also ensure the home directory itself is owned by the user (not root). OpenSSH's `StrictModes` rejects keys when parent directory ownership is wrong:

```bash
kubectl --context=CW_CONTEXT exec -n tenant-slurm slurm-login-0 -c sshd -- bash -c '
  HOMEDIR=$(getent passwd USERNAME | cut -d: -f6)
  chown UID:GID $HOMEDIR
'
```

### Multi-Cluster Verification

```bash
sky check slurm
```

Should show all clusters enabled:

```
Slurm: enabled
  sunk-gcp: enabled
  sunk-aws: enabled
  cw-ml-dev: enabled
```

List GPUs aggregated across all clusters:

```bash
sky gpus list --cloud slurm
```

### Cross-Cluster Scheduling

SkyPilot automatically considers all enabled clusters and picks the best one. Use accelerator alternatives to let SkyPilot choose:

```yaml
resources:
  cloud: slurm
  accelerators: {H200: 8, L4: 1}
  memory: 0.5
```

SkyPilot will schedule on whichever cluster can satisfy one of the listed accelerator options.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `sky check slurm` shows "not enabled" | Missing or malformed `~/.slurm/config` | Verify the file exists and has valid SSH Host entries |
| `Catalog does not contain any instances` | SkyPilot's default memory request exceeds node capacity | Add `memory: 0.5` (or appropriate value) to your resources block |
| SSH connection refused | Port-forward not running, or wrong port | Re-run `kubectl port-forward` or check LoadBalancer IP/port |
| `Permission denied (publickey)` | Key not in `authorized_keys`, wrong file permissions, or wrong home directory | Verify key is at correct path, permissions are 600/700, and home dir is owned by the user |
| `No such file or directory: .bashrc` | SkyPilot expects `.bashrc` to exist | Run `touch ~/.bashrc ~/.bash_profile` on login node as the user |
| `image_id` errors | Pyxis/enroot not available | Remove `image_id` from YAML; use bare-metal mode |
| SSH works but `sky launch` hangs | Firewall or network policy blocking compute node access | SkyPilot SSHes to login node only; check that Slurm can schedule jobs (`srun hostname` from login node) |
| Wrong home directory on CoreWeave | CW uses `/mnt/home/USERNAME` not `/home/USERNAME` | Check with `getent passwd USERNAME` and place keys at the real home path |
| `srun: error: Unable to allocate resources` | No idle nodes or partition misconfigured | Run `sinfo` to check node states; verify the partition has available nodes |
