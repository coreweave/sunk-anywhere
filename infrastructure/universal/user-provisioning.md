# `add-sunk-user.sh` — what it does and what it doesn't

This directory ships `add-sunk-user.sh`, a single-user provisioning helper
for SUNK clusters that don't have an identity backend (authentik+sssd,
CoreWeave IAM, etc.). It's the same primitive the
`bootstrap-sunk-local-user` skill invokes under the hood.

See `skills/universal/bootstrap-sunk-local-user/SKILL.md` for the guided
flow. This file is the "what the script does and what it explicitly
doesn't do" reference you read before reaching for it at 2am.

## What it does

One user per invocation. Three subcommands:

| Subcommand  | Effect                                                                                                 |
|-------------|--------------------------------------------------------------------------------------------------------|
| `add`       | Ensures Slurm account → creates Linux user on login pod → drops SSH key → registers Slurm association |
| `update-key`| Replaces `authorized_keys` atomically, preserves everything else                                       |
| `remove`    | `sacctmgr remove user` (keeps sacct history) + `userdel -r` on the login pod. Requires `--confirm`.    |

All three are idempotent. Re-running `add` with the same flags rewrites
the SSH key atomically and leaves the Linux + Slurm sides alone.

Attributes the script captures per user:

- `username` (required)
- `uid` / `gid` (required on `add`; gid defaults to uid)
- `email` — goes into the GECOS field, so `finger alice` / mail
  notifications work
- `ssh_key` — full openssh pubkey line
- `shell` (default `/bin/bash`)
- `home` (default `/home/<username>`, on the shared NFS mount)
- `slurm_account` (default `users`, auto-created in slurmdbd if absent)

Read-back after `add` prints `id`, the key file's stat, and `sacctmgr
show user` so you can confirm all three sides agree before walking away.

## What it does NOT do

**The user is only resolvable on the login pod.** SSH works. Everything
else that needs the user's name (not just UID) does not.

- `kubectl exec <compute-pod> -- id alice` returns "no such user".
- `kubectl exec <controller-pod> -c slurmctld -- id alice` returns "no
  such user".
- **`sbatch` FAILS** with `Invalid account or account/partition
  combination specified`. Root cause: slurmctld runs on the controller
  pod and does `getpwuid(UID)` to map submissions to Slurm associations;
  with no passwd entry the controller logs "User N not found" and
  rejects the job. This was validated on live GKE + EKS on 2026-04-20.
- `srun --pty bash` shows you as a bare numeric UID; `$HOME` isn't
  populated, `whoami` returns nothing.
- Group memberships aren't enforced anywhere beyond the primary GID.

**There is no `compute.extraUsers` (or equivalent) in the upstream
`coreweave/slurm` chart as of v7.3.0.** Earlier drafts of this doc
referenced one; it was inaccurate. The chart assumes an external
directory service populates `/etc/passwd` on every pod.

To reach a working `sbatch` flow, you need one of:

1. **`configure-sunk-authentik-sssd` skill** — stands up authentik as the
   directory source with sssd as a sidecar on every pod. This is the
   supported multi-pod identity path for sunk-anywhere. Heavier setup;
   correct for anyone who actually needs to run jobs.
2. **Roll your own chart overlay** — template a synthetic passwd/group
   into controller + login + compute pod volumes. Non-trivial; out of
   scope for this helper.

This helper's current value is: SSH access + Slurm association for a
user whose passwd resolution will come from a directory service you
deploy separately.

## What it also does NOT do

- **Batch provisioning** — one user per invocation. Wrap it in a `for`
  loop yourself if you want to seed many users. The script optimizes for
  atomicity, not ergonomics.
- **Key fingerprint allowlisting / hardware-key enrollment / MFA** — the
  key you pass is the key that lands in `authorized_keys`. Upstream
  hygiene is on you.
- **Cross-cluster sync** — each cluster is provisioned independently.
  Run the command once per `--kubeconfig` / `--context`.
- **Remove from compute pods** — `remove` tears down the login-pod Linux
  user and the Slurm association, but if you wired Option A
  (`compute.extraUsers`), you still need to strip the entry from values
  and `helm upgrade` to flush compute pods.

## Usage pointers

```bash
# Add a user end-to-end
./add-sunk-user.sh add \
    --username alice \
    --uid 1001 --gid 1001 \
    --email alice@example.com \
    --ssh-key "$(cat ~/.ssh/id_ed25519.pub)"

# Rotate the key only
./add-sunk-user.sh update-key \
    --username alice \
    --ssh-key "$(cat ~/.ssh/id_ed25519_new.pub)"

# Offboard
./add-sunk-user.sh remove --username alice --confirm

# Multi-cluster
./add-sunk-user.sh add --kubeconfig ~/.kube/eks-prod --context prod \
    --username alice --uid 1001 --gid 1001 \
    --email alice@example.com --ssh-key "ssh-ed25519 AAA..."
```

Run `./add-sunk-user.sh --help` for the full flag surface.
