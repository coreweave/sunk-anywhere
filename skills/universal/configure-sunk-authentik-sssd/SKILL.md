---
name: configure-sunk-authentik-sssd
description: |
  Configure the coreweave/slurm Helm chart's directoryService block to
  resolve users from an existing authentik LDAP outpost via sssd. Produces
  a provider-specific values overlay (sssd enabled, nsscache disabled),
  creates the LDAP bind secret, and documents the perf/correctness knobs
  that bit customers in the past.
  Use when: "configure authentik for SUNK", "deploy authentik LDAP for
  Slurm", "set up sssd on SUNK", "wire authentik to Slurm", "switch from
  local users to authentik", "authentik bind secret for Slurm".
---

# Configure SUNK to resolve users from authentik via sssd

This skill points SUNK's `directoryService` at an existing authentik LDAP
outpost so every SUNK pod (login, compute, controllers) resolves users
uniformly through sssd. It's the opt-in path for customers who want
centralized identity, cross-pod resolution, group memberships, and
dynamic user lifecycle without running the simple per-user helper.

Use this when you need any of:
- User is resolvable inside compute pods (`id alice`, group membership,
  `srun --pty bash` shows a real GECOS).
- Authentik is already the company's identity source and SUNK should not
  be a second source of truth.
- You need LDAP groups to drive Slurm QoS / account membership (optional
  PAM hook below).

If you don't already run authentik, **don't pick this path first.** The
simple default (`bootstrap-sunk-local-user`) gets you to `ssh` + `sbatch`
in one command. Come back here when you outgrow it.

## Prerequisites

- SUNK deployed and healthy (`kubectl get pod -n tenant-slurm slurm-login-0`
  shows `2/2 Running`).
- Authentik already running somewhere reachable from the cluster (same
  namespace, different namespace, or external). The LDAP outpost must be
  deployed with the `sshPublicKey` attribute exposed under the
  `ldapPublicKey` objectClass **only if** you want sssd to serve keys
  (unvalidated; see "SSH key source" below).
- An authentik service account (bind DN) with read access to the user
  subtree, and its password handy.
- Decide the POSIX schema: `rfc2307bis` (recommended; works with
  authentik's default user/group object classes) or `AD` (the chart's
  only schema that ships `ldap_user_ssh_public_key` wired).

If you're standing up authentik from scratch in a sandbox, see
`infrastructure/universal/authentik-minimal/` — a validated single-node
authentik profile that fits on a 2-node `e2-standard-4` or
`m5.large`-class cluster.

## Decisions you must make

Prompt the customer (or their agent) for these. Defaults are designed for
a first-working config.

| Field                      | Default                                                                          | Notes                                                                                                                                                                  |
|----------------------------|----------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `ldapUri`                  | `ldap://authentik-outpost-ldap-outpost.authentik.svc.cluster.local`              | In-cluster outpost. Use `ldaps://` only if the outpost has TLS; with `startTLS: true` the `ldap://` URI is still encrypted post-bind.                                 |
| `bindDn`                   | *required, no default*                                                           | e.g. `cn=ldapsvc,dc=example,dc=com`. Service account in authentik.                                                                                                    |
| `searchBase`               | *required, no default*                                                           | e.g. `dc=example,dc=com`.                                                                                                                                              |
| `bindSecretName`           | `slurm-bind-authtok`                                                             | Must exist in `tenant-slurm` with key `bind-password`. Create with `infrastructure/universal/create-ldap-bind-secret.sh`.                                             |
| `overrideHomeDir`          | `/home/%u`                                                                       | Customer A uses `/mnt/vast/home/%u` to park homes on a dedicated volume. Pick once; sssd bakes it into passwd responses.                                              |
| `schema`                   | `rfc2307bis`                                                                     | Matches authentik's default emission. Switch to `AD` only if you explicitly configured authentik to emit AD attributes.                                               |
| `userObjectClass`          | `user` (authentik default)                                                       | Chart default is `posixAccount`, wrong for authentik. This is the #1 "I copy-pasted the customer's config and nothing resolves" gotcha.                                |
| `userNameAttr`             | `cn`                                                                             | Customer A uses `employeeNumber` (they store the POSIX username there, and `cn` holds the full display name). Match authentik's user attribute convention.             |
| `accessFilter.group`       | `slurm-users`                                                                    | Only members of this group can log in. Rendered into `additionalConfig` as `ldap_user_search_base = <base>?subtree?(memberOf=cn=<group>,ou=groups,<base>)`.         |
| `sudoGroups`               | `[slurm-sudo]`                                                                   | Members get passwordless sudo on login pods. Omit if you don't want sudo exposed.                                                                                     |
| `startTLS`                 | `true`                                                                           | Encrypts the post-bind channel over `ldap://`. Leave on.                                                                                                               |
| `ignoreGroupMembers`       | `true`                                                                           | **Critical perf knob.** Skips enumerating `memberUid` for every `getent group` call. Brought sssd query latency from 2min → 4s on authentik outposts with large groups. |
| `negativeCacheTimeout`     | `600`                                                                            | Don't retry authentik for unknown users more than once per 10 min. Matches Customer A.                                                                                |
| `enablePamSacctmgrHook`    | `false`                                                                          | Opt-in. When true, adds a PAM `session` hook on the login pod that runs `sacctmgr add user` on first SSH. See caveat below.                                           |
| `sshKeySource`             | `nfs`                                                                            | `nfs` = keys live at `/home/%u/.ssh/authorized_keys` (what sshd reads by default). `ldap` = ask sssd to serve keys from authentik (UNVALIDATED; see below).           |

### About `enablePamSacctmgrHook`

When enabled, the skill emits a `pam_exec` hook that runs
`sacctmgr -i add user $PAM_USER DefaultAccount=users` on first SSH
session. Customer A does this so authentik is the only UI that matters
for onboarding. **Caveat:** login now depends on slurmdbd being
reachable. If slurmdbd is degraded, users get `Permission denied` at SSH
time, not a useful error. Leave this off unless the customer explicitly
wants it.

### About `sshKeySource: ldap`

The chart templates `ldap_user_ssh_public_key = altSecurityIdentities`
only when `schema: AD`. For `rfc2307bis` (the authentik default), setting
`sshKeySource: ldap` emits an `additionalConfig` snippet:

```yaml
additionalConfig: |
  ldap_user_extra_attrs = sshPublicKey
  ldap_user_ssh_public_key = sshPublicKey
```

This is **untested on sunk-anywhere**. For it to work, all three have to
line up: (1) authentik's LDAP outpost must expose `sshPublicKey` under
`ldapPublicKey` objectClass, (2) the bind DN must have read access to
that attribute, (3) sshd's `AuthorizedKeysCommand sss_ssh_authorizedkeys`
must be wired (the chart does this in the login pod's sshd_config). Until
we validate end-to-end, keep `sshKeySource: nfs` and drop keys via the
`bootstrap-sunk-local-user` helper (`add-sunk-user.sh update-key`).

## Step 1: Create the LDAP bind secret

```bash
cd sunk-anywhere
./infrastructure/universal/create-ldap-bind-secret.sh \
    --namespace tenant-slurm \
    --name slurm-bind-authtok \
    --password "<authentik-service-account-password>"
```

The script does `kubectl create secret generic` idempotently (deletes +
recreates, so rotations work). Key: `bind-password`.

## Step 2: Emit the values overlay

Pick your provider directory (`eks`, `gke`) and write a
`user-auth.yaml` overlay alongside `slurm-values.yaml`. The skill emits
this template — fill in the customer-specific bits:

```yaml
# helm-values/<provider>/user-auth.yaml
# Layered on top of slurm-values.yaml via `-f`.

nsscache:
  enabled: false

sssdContainer:
  enabled: true

directoryService: &directoryService
  negativeCacheTimeout: "600"
  sudoGroups:
    - slurm-sudo
  directories:
    - name: authentik
      enabled: true
      debugLevel: 1
      overrideHomeDir: "/home/%u"
      fallbackHomeDir: "/home/%u"
      userObjectClass: user
      groupObjectClass: group
      groupNameAttr: cn
      userNameAttr: cn
      ldapUri: ldap://authentik-outpost-ldap-outpost.authentik.svc.cluster.local
      user:
        bindDn: cn=ldapsvc,dc=example,dc=com
        searchBase: dc=example,dc=com
        existingSecret: slurm-bind-authtok
      defaultShell: "/bin/bash"
      schema: rfc2307bis
      startTLS: true
      ignoreGroupMembers: true
      additionalConfig: |
        ldap_user_search_base = dc=example,dc=com?subtree?(memberOf=cn=slurm-users,ou=groups,dc=example,dc=com)

# The chart renders directoryService into controllers + login; compute
# reuses the same block via the yaml anchor.
compute:
  directoryService: *directoryService
```

Swap values for your customer's authentik deployment. The chart sidecar
`sssd` runs on every pod that mounts this block.

## Step 3: Upgrade and verify

```bash
helm upgrade slurm coreweave/slurm \
    -n tenant-slurm \
    -f helm-values/base/slurm-values.yaml \
    -f helm-values/<provider>/slurm-values.yaml \
    -f helm-values/<provider>/user-auth.yaml

# Wait for the rollout
kubectl rollout status -n tenant-slurm statefulset/slurm-login
kubectl rollout status -n tenant-slurm deployment/slurm-controller

# Smoke test: a known authentik user resolves
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
    getent passwd <canary_user>
# -> alice:*:1001:1001:Alice <alice@example.com>:/home/alice:/bin/bash

# Check sssd saw the directory
kubectl exec -n tenant-slurm slurm-login-0 -c sssd -- \
    sssctl user-checks <canary_user>
```

If `getent passwd` returns nothing, **don't touch sssd yet** — check the
bind first:

```bash
# Can the pod even reach authentik?
kubectl exec -n tenant-slurm slurm-login-0 -c sssd -- \
    ldapsearch -H ldap://authentik-outpost-ldap-outpost.authentik.svc.cluster.local \
    -D cn=ldapsvc,dc=example,dc=com -w "$(kubectl get secret -n tenant-slurm slurm-bind-authtok -o jsonpath='{.data.bind-password}' | base64 -d)" \
    -b dc=example,dc=com "(cn=<canary_user>)" cn uidNumber
```

## Step 4: Drop the first SSH key

Even on the authentik path, keys live on NFS (see SSH Key Source decision
above). Reuse the simple-path helper:

```bash
./infrastructure/universal/add-sunk-user.sh add \
    --username <canary_user> \
    --uid 1001 --gid 1001 \
    --email alice@example.com \
    --ssh-key "$(cat ~/.ssh/id_ed25519.pub)"
```

Note: `add-sunk-user.sh add` also runs `useradd` and `sacctmgr add user`.
When sssd is authoritative, `useradd` will hit a conflict if the
authentik side already has the user (UID is the same). The helper's
preflight catches this and exits cleanly. For authentik clusters, you
typically only want the key-drop + sacctmgr bits:

```bash
./infrastructure/universal/add-sunk-user.sh update-key \
    --username <canary_user> \
    --ssh-key "$(cat ~/.ssh/id_ed25519.pub)"
```

`update-key` skips the useradd step and reads UID/GID/home from sssd-resolved
passwd entries, which is exactly right on the authentik path.

## Validation profile: authentik-minimal

Never used authentik and want to validate this skill end-to-end? Use the
throwaway profile in `infrastructure/universal/authentik-minimal/`:

```bash
cd infrastructure/universal/authentik-minimal
./install.sh                 # helm install authentik in its own ns
./seed-test-users.sh         # create test_user_1 + test_user_2 with UID/GID/sshPublicKey
# ...run this skill's Step 2-4 against the just-installed outpost...
./teardown.sh                # helm uninstall + ns delete when done
```

The profile is sized for a 2-node e2-standard-4 (GKE) or m5.large (EKS),
2-4 GiB RAM for authentik total. Customer-production profiles
(`solutions-architecture-services/charts/authentik-ha`) want 4-8+ GiB and
multi-replica — too big for $50/day test clusters.

## Troubleshooting

| Symptom                                                          | Likely cause                                               | Fix                                                                                                                                                                            |
|------------------------------------------------------------------|------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `getent passwd <user>` returns nothing                           | `userObjectClass` doesn't match authentik's emissions      | Change to `user` (authentik default) or check authentik outpost config                                                                                                        |
| `getent passwd` hangs for 2 min then times out                   | `ignoreGroupMembers: false` against a large group          | Flip to `true`. Brings sssd query latency from 2min → 4s.                                                                                                                     |
| `ldapsearch` in pod hangs                                        | Outpost not reachable from the pod network                 | `kubectl get svc -n authentik authentik-outpost-ldap-outpost`; if no ClusterIP, the outpost deployment hasn't registered                                                       |
| `Permission denied (publickey)` even though user resolves        | `sshKeySource: nfs` (default) but no `authorized_keys` file | Drop the key with `add-sunk-user.sh update-key`; default path is `/home/%u/.ssh/authorized_keys` on NFS                                                                       |
| `Permission denied` at SSH time and `pam_exec` in logs           | `enablePamSacctmgrHook: true` + slurmdbd unreachable        | Check slurmdbd pod health; disable the hook until slurmdbd is stable                                                                                                          |
| `Invalid credentials (49)` in sssd logs                          | Wrong bind password                                        | `create-ldap-bind-secret.sh --password <new>` and restart login pod                                                                                                            |
| `sacctmgr add user` fails in PAM hook: "Unknown account"         | User's `slurm_account` doesn't exist in slurmdbd           | `sacctmgr -i add account users` first, or set PAM hook's account to one that exists                                                                                            |

## See also

- [`infrastructure/universal/authentik-minimal/README.md`](../../infrastructure/universal/authentik-minimal/README.md) — the throwaway authentik profile for validation.
- [`infrastructure/universal/create-ldap-bind-secret.sh`](../../infrastructure/universal/create-ldap-bind-secret.sh) — helper for the bind-password Secret.
- [`skills/universal/bootstrap-sunk-local-user/SKILL.md`](../bootstrap-sunk-local-user/SKILL.md) — the simple default path; useful even on authentik clusters for key drops + sacctmgr association.
- [`docs/universal/ssh-access.md`](../../../docs/universal/ssh-access.md) — decision table comparing the three user-provisioning paths.
- Customer A reference (internal): `solutions-architecture-services/monorepo/189d5b-github-rno2/slurm/values-rno2a-prod.yaml` — production-scale version of this config (schema=rfc2307bis, userNameAttr=employeeNumber, /mnt/vast/home/%u, PAM sacctmgr hook enabled).
