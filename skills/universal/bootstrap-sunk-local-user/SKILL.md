---
name: bootstrap-sunk-local-user
description: |
  Create a single local UNIX user on a SUNK deployment without setting up
  authentik/LDAP or SCIM. Drops an SSH public key, captures username + email
  + UID/GID, and registers the user with slurmdbd automatically so they can
  submit jobs without a manual sacctmgr step. Works on any provider (EKS,
  GKE, CoreWeave).
  Use when: "add a local user to SUNK", "create test user on SUNK",
  "skip LDAP for SUNK", "one-off SUNK user", "how do I SSH into SUNK without LDAP",
  "bootstrap SUNK without nsscache", "put my public key on the login pod",
  "rotate a user's SSH key", "remove a SUNK user".
---

# Bootstrap a local user on SUNK

This skill provisions a single POSIX user on a SUNK deployment: drops an SSH
public key into `authorized_keys` on the shared NFS home, captures the
user's email/UID/GID, and adds the Slurm association so `sbatch` works
immediately. No authentik, no OpenLDAP, no SCIM.

Use this when:
- You're standing up a new cluster and want to verify SSH + sbatch before
  you commit to a directory backend.
- You run a single-tenant cluster and don't need centralized IAM.
- You're writing a demo and don't want to introduce LDAP complexity.

If you need multi-user provisioning with authentik as the source of truth,
use `configure-sunk-authentik-sssd` instead. The two skills are compatible:
you can bootstrap one local user first and migrate to authentik later,
because the NFS home directory is the same either way.

## Prerequisites

- Base SUNK deployed and healthy. `kubectl get pod -n tenant-slurm slurm-login-0`
  should show `2/2 Running`.
- `kubectl exec` works against the login pod. Test:
  `kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- id`
- Your public SSH key file (e.g. `~/.ssh/id_ed25519.pub`).

## Decisions you must make

| Choice       | Default               | Why it matters                                                                                                                                   |
|--------------|-----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| `USERNAME`   | your laptop `$USER`   | Has to be consistent across the login pod and every compute pod so Slurm can resolve it.                                                         |
| `EMAIL`      | `user@example.com`    | Stored in the GECOS field and used for Slurm mail notifications (`--mail-user`). Not required for auth, but the helper refuses an empty string. |
| `UID`        | 1001                  | Must be the same on every pod that mounts `/home`. Pick something outside the system range (1000+).                                              |
| `GID`        | 1001 (= UID)          | Same constraint as UID. Use 100 (users) if you prefer a shared primary group.                                                                    |
| `SHELL`      | /bin/bash             | Has to exist inside the login-pod image. `/bin/sh` also works.                                                                                   |
| `HOME`       | /home/$USERNAME       | Lives on the shared NFS volume, which is why the same path works across login + compute pods.                                                    |
| `SLURM_ACCOUNT` | `users`            | Auto-created in slurmdbd if absent. The user is added as a member with `DefaultAccount=<slurm_account>` so jobs don't need `--account`.         |

## Step 1: Provision the user with the helper script

Use `infrastructure/universal/add-sunk-user.sh`. One invocation creates the
Linux user, drops the SSH key, and registers the Slurm association.

```bash
cd sunk-anywhere

./infrastructure/universal/add-sunk-user.sh add \
    --username alice \
    --uid 1001 --gid 1001 \
    --email alice@example.com \
    --ssh-key "$(cat ~/.ssh/id_ed25519.pub)"
```

The script is idempotent. Re-running with the same flags is a no-op except
for rewriting `authorized_keys` atomically.

What it does, in order:
1. **Preflight** — checks that `$NS/$LOGIN_POD` exists and is reachable.
2. **Ensures the Slurm account** (`users` by default) exists in slurmdbd
   via `sacctmgr -i add account`. Skipped if already present.
3. **Ensures the Linux user** via `groupadd` + `useradd -m` on the login
   pod. If the user exists, updates only the GECOS (email) field.
4. **Drops the SSH key** into `$HOME/.ssh/authorized_keys` using an atomic
   rename. The key is streamed via `kubectl exec -i` stdin so shell
   quoting of the key material cannot corrupt it.
5. **Adds the Slurm user** via `sacctmgr -i add user $USERNAME
   DefaultAccount=users`. Users can then `sbatch` without specifying
   `--account`. Skipped if the association already exists.
6. **Read-back verification** — prints `id`, key file `stat`, and
   `sacctmgr show user` so you can confirm all three sides (Linux, NFS,
   slurmdbd) before walking away.

Flags you'll reach for:

```bash
--slurm-account myteam      # override the default account name
--namespace sunk-prod       # override NS (default tenant-slurm)
--login-pod slurm-login-0   # override login pod
--kubeconfig ~/.kube/eks-1  # when you're juggling multiple clusters
--context gke-dev           # same
```

## Step 2: Honest limits — this is SSH-only without a directory service

The login pod now has `alice` in its local `/etc/passwd`. No other pod
does. That means:

- **`ssh alice@<login>`** works.
- **`sbatch` FAILS** with `Invalid account or account/partition
  combination specified`. Cause: slurmctld runs in the controller pod,
  calls `getpwuid(UID)` to map submissions to Slurm associations, and
  gets "User N not found" because the controller pod has never heard of
  `alice`. See `slurm-controller -c slurmctld` logs for the actual error.
- **`srun --pty bash`** shows a numeric UID with no GECOS / no `$HOME`
  populated from passwd.

**There is no chart-level `compute.extraUsers` (or equivalent) that fixes
this in the upstream `coreweave/slurm` chart as of v7.3.0.** Earlier
versions of this skill referenced such a value; it doesn't exist and
setting it has no effect. The chart assumes an external directory
service populates passwd/group on every pod.

To get job submission working for a user:

1. **Use the authentik path** (`configure-sunk-authentik-sssd` skill).
   sssd runs as a sidecar on every pod, so the controller resolves
   users uniformly. This is the only supported "multi-pod identity"
   path for sunk-anywhere deployments today.
2. **Roll your own**: build a custom chart overlay that mounts a
   synthetic `passwd`/`group` into the controller + login + compute
   pods. Non-trivial; out of scope for this skill.

If all you need is SSH access plus a Slurm association so an authentik-
backed user can submit later (common pattern: authentik provides
`/etc/passwd` via sssd, but you still want to drop the NFS SSH key and
call `sacctmgr add user` for the association), this helper is the right
tool — just skip Step 3's `sbatch` expectation until the authentik path
is in place.

## Step 3: Verify SSH + sbatch work end-to-end

Get the login endpoint for your provider:

```bash
# EKS (NLB)
HOST=$(kubectl get svc -n tenant-slurm slurm-login -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ssh -i ~/.ssh/id_ed25519 alice@$HOST"

# GKE (ClusterIP + port-forward)
kubectl port-forward -n tenant-slurm svc/slurm-login 2222:22 &
echo "ssh -i ~/.ssh/id_ed25519 -p 2222 alice@localhost"
```

SSH should succeed and drop you to a shell as `alice`. That's the full
extent of what this skill alone gets you.

**Do not expect `sbatch` to work yet.** Per Step 2, slurmctld can't
resolve `alice` on the controller pod without a directory service, so
submission fails with `Invalid account or account/partition combination
specified`. This is surprising to first-time users — validated on GKE +
EKS on 2026-04-20 and it's a chart-level gap, not a helper-script bug.

To reach `sbatch` → `COMPLETED`, stand up the authentik path on top of
the user you just created (`configure-sunk-authentik-sssd` skill), then
re-submit. The NFS `authorized_keys` you dropped here stays valid.

## Rotating a user's SSH key

```bash
./infrastructure/universal/add-sunk-user.sh update-key \
    --username alice \
    --ssh-key "$(cat ~/.ssh/id_ed25519_new.pub)"
```

`update-key` reads the user's UID/GID/home directly from the login pod,
so you can't accidentally rewrite the file with the wrong ownership.

## Removing a user

```bash
./infrastructure/universal/add-sunk-user.sh remove --username alice --confirm
```

This runs `sacctmgr remove user` (preserves job history in `sacct`) and
`userdel -r` on the login pod (removes `/home/alice` from NFS). Compute
pods still carry the `/etc/passwd` entry if you used Option A; strip it
from values and `helm upgrade` to fully clean up.

## Migrate to authentik later (optional)

Once the deployment is proven, swap this local user for a directory-backed
one:

1. Run the `configure-sunk-authentik-sssd` skill to deploy authentik and
   enable sssd.
2. Re-create `alice` as an authentik user with the same UID/GID.
   `/home/alice` already exists and is writable, so there's no data
   migration.
3. Run `./infrastructure/universal/add-sunk-user.sh remove --username alice
   --confirm` on the login pod to drop the local `/etc/passwd` entry.
   sssd will then resolve `alice` from authentik on every pod.

## Troubleshooting

| Symptom                                          | Likely cause                                       | Fix                                                                                     |
|--------------------------------------------------|----------------------------------------------------|-----------------------------------------------------------------------------------------|
| `ssh: connection refused` on the NLB hostname    | Security group doesn't allow port 22 inbound       | Open TCP/22 on the cluster's worker-node SG (EKS) or the login NodePort (GKE)           |
| `Permission denied (publickey)` from the NLB     | Key mismatch between laptop and `authorized_keys`  | Re-run `update-key` with the correct pubkey, or `ssh -v` to see which key ssh tried     |
| `sbatch: error: Invalid user id: alice`          | Compute pod `/etc/passwd` missing `alice`          | Step 2 option A (chart override) or option B (manual append)                            |
| `sbatch: error: Unable to create directory`      | NFS home dir owned by root, not `alice:alice`      | `kubectl exec ... chown -R alice:1001 /home/alice`                                      |
| `sbatch: error: User's group is not permitted to use this account` | User exists but no Slurm association      | Re-run the helper's `add` subcommand, or `sacctmgr add user alice DefaultAccount=users` |
| `add` fails: `user already exists with UID=...`  | Existing local user has a different UID            | Pick a new UID, or `userdel -r` the existing user first (destroys their NFS home)      |
| LoadBalancer stuck `<pending>` on EKS            | AWS Load Balancer Controller not installed         | See `skills/eks/deploy-sunk-on-eks/SKILL.md` step on AWS LB controller                  |

## See also

- `infrastructure/universal/add-sunk-user.sh` — the helper script this
  skill wraps. All three subcommands (`add`, `update-key`, `remove`) live
  there.
- `skills/universal/configure-sunk-authentik-sssd/SKILL.md` — the
  authentik path for multi-user production.
- `docs/universal/ssh-access.md` — decision table comparing the three
  user-provisioning paths (this skill, authentik+sssd, CW IAM SCIM).
- `docs/universal/user-provisioning.md` — conceptual overview of directory
  backends and SSH key lifecycle.
