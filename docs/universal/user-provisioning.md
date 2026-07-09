# User Provisioning

> **Heads up — this doc is the nsscache/LDAP reference only.**
>
> - For the **simple default** (SSH key + local user + sacctmgr on the
>   login pod), see the [`bootstrap-sunk-local-user`
>   skill](../../skills/universal/bootstrap-sunk-local-user/SKILL.md).
> - For the **authentik + sssd** path (dynamic user lifecycle, cross-pod
>   identity), see the [`configure-sunk-authentik-sssd`
>   skill](../../skills/universal/configure-sunk-authentik-sssd/SKILL.md).
> - For an **overview comparing all three paths** (simple, authentik+sssd,
>   and the CW-IAM-SCIM path that isn't available outside CW Cloud), see
>   [`ssh-access.md`](ssh-access.md).
>
> The nsscache pipeline documented below is the mechanism SUNK on
> CoreWeave Cloud uses for CW IAM SCIM integration. `sunk-anywhere`
> (EKS/GKE) deployments should use the simple or authentik+sssd
> paths instead.

How users, groups, and SSH keys flow from a directory service into SUNK pods. This is a conceptual overview and reference.

## Provisioning Pipeline

All three provisioning paths follow the same pipeline:

```
Directory Source        nsscache CronJob         K8s Secrets          Slurm Pods
(LDAP / AD / SCIM) --> (queries + syncs) -----> (passwd, group, --> (projected volumes
                                                  shadow, sshkey      at /etc/nsscache/)
                                                  cache files)
```

1. A directory source holds POSIX user/group records and SSH public keys.
2. The nsscache CronJob queries that source on a schedule (default: every minute).
3. nsscache writes cache files (passwd.cache, group.cache, shadow.cache, sshkey.cache) and stores them as Kubernetes Secrets.
4. The Slurm Helm chart projects those Secrets into every pod (login, compute, controller) at `/etc/nsscache/`.
5. NSS (`/etc/nsswitch.conf`) is configured to check `files` then `cache`, so `getent passwd <user>` resolves users from the cache.
6. sshd uses an `AuthorizedKeysCommand` that reads `sshkey.cache` to authenticate SSH connections.

## Directory Backends

### Path 1: In-Cluster OpenLDAP

Best for evaluation, small teams, or environments without existing directory services.

- Deploy OpenLDAP as a single-replica Deployment in the `tenant-slurm` namespace.
- Users are defined in an LDIF seed ConfigMap.
- SSH keys are stored as `sshPublicKey` attributes using the `ldapPublicKey` objectClass.
- Adding or removing users requires updating the LDIF and redeploying (or using `ldapmodify`).

Required objectClasses:
- **Users**: `inetOrgPerson`, `posixAccount`, `shadowAccount`, `ldapPublicKey`
- **Groups**: `posixGroup`

nsscache config:
```yaml
nsscacheConfig:
  default:
    source: ldap
    ldap_uri: "ldap://openldap.tenant-slurm.svc.cluster.local:389"
    ldap_base: "dc=example,dc=local"
    ldap_bind_dn: "cn=readonly,dc=example,dc=local"
    ldap_rfc2307bis: 0
    ldap_scope: sub
```

### Path 2: Existing LDAP or Active Directory

Best for enterprises with an existing directory. Point nsscache at the corporate LDAP:

```yaml
nsscacheConfig:
  default:
    source: ldap
    ldap_uri: "ldap://corp-ldap.example.com:389"
    ldap_base: "dc=corp,dc=example,dc=com"
    ldap_bind_dn: "cn=sunk-reader,ou=service-accounts,dc=corp,dc=example,dc=com"
    ldap_rfc2307bis: 1   # 1 for Active Directory / RFC 2307bis
    ldap_scope: sub
```

For Active Directory, use `ldap_rfc2307bis: 1` and adjust LDAP filters to match your schema. AD stores SSH keys differently; you may need the `msDS-cloudExtensionAttribute` or a custom schema extension.

### Path 3: SCIM (Okta, Azure AD)

Best for cloud-first organizations using identity providers with SCIM support:

```yaml
nsscacheConfig:
  default:
    source: scim
    scim_base_url: "https://your-scim-endpoint.example.com/scim/v2"
  sshkey:
    scim_path_username: userName
    scim_path_ssh_keys: urn:ietf:params:scim:schemas:extension:posix:2.0:User/sshPublicKey
```

Use `nsscache.existingSecret` to store the SCIM auth token.

## SSH Key Authentication Flow

```
+----------+     +--------------+     +------------------+     +---------------+
|  Admin   |---->|   Directory  |---->|  nsscache        |---->| K8s Secrets   |
| (LDIF/   |     |  (LDAP/AD/   |     |  (CronJob)       |     | (cache files) |
|  SCIM)   |     |   SCIM)      |     |                  |     |               |
+----------+     +--------------+     +------------------+     +-------+-------+
                                                                       |
                                                                       | projected
                                                                       | volume
                                                                       v
+----------+     +--------------+     +------------------+     +---------------+
|  User    |---->|   sshd       |---->| AuthorizedKeys   |---->| sshkey.cache  |
| (ssh)    |     |  (login pod) |     | Command (python)  |     | (/etc/nsscache)|
+----------+     +--------------+     +------------------+     +---------------+
```

1. Admin adds an SSH public key to the directory (LDIF attribute, SCIM field, etc.).
2. nsscache CronJob syncs keys into `sshkey.cache` (format: `username:ssh-ed25519 AAAA...`).
3. CronJob stores the cache as a K8s Secret (`slurm-nsscache-sshkey`).
4. The Secret is projected into all Slurm pods at `/etc/nsscache/sshkey.cache`.
5. User runs `ssh username@<login-node>`.
6. sshd invokes `AuthorizedKeysCommand` (a Python script that reads sshkey.cache).
7. Script returns matching public keys; sshd validates the offered key against them.

### Key files in the Helm chart

| File | Purpose |
|------|---------|
| `scripts/nsscache-authorized-keys-command.py` | Python script invoked by sshd to look up SSH keys from cache |
| `scripts/nsscache-update.sh` | Shell script run by the CronJob to sync directory data and create K8s Secrets |
| `templates/config/sshd-conf-configmap.yaml` | Adds `AuthorizedKeysCommand` directive when nsscache is enabled |
| `templates/config/nsscache-conf-configmap.yaml` | Generates nsscache.conf from Helm values |
| `templates/nsscache-update-cronjob.yaml` | CronJob definition, RBAC, and ConfigMap for the update script |
| `templates/_helpers.tpl` (`nsscache.volumeMounts`) | Mounts nsscache results, script, and configs into all pod types |

## OpenLDAP Quick Start

Minimal steps to get OpenLDAP running for evaluation. For full details, see the skill guide.

1. Create `infrastructure/openldap.yaml` with a Deployment, Service, and seed ConfigMap.
   - Use the `copy-seed` init container pattern (ConfigMap volumes are read-only in most providers).
   - Set `LDAP_REMOVE_CONFIG_AFTER_SETUP=false` to prevent the image from deleting seed LDIFs.
2. Apply: `kubectl apply -f infrastructure/openldap.yaml`
3. Create the bind secret: `kubectl create secret generic nsscache-ldap-credentials --from-literal=nsscache-ldap-password='readonly' -n tenant-slurm`
4. Add the `nsscache:` block to `helm-values/slurm-values.yaml` (see skill guide for full config).
5. Run `helm upgrade` and restart the login pod.
6. Verify with `getent passwd <username>` from within the login pod.

## Verification Checklist

Run these checks after any provisioning change to confirm the pipeline is working end-to-end.

### Directory layer

```bash
# Verify LDAP entries are accessible (OpenLDAP example)
kubectl exec -n tenant-slurm deployment/openldap -- \
  ldapsearch -x -H ldap://localhost -b "dc=example,dc=local" \
  -D "cn=readonly,dc=example,dc=local" -w "readonly" \
  "(objectClass=posixAccount)" uid uidNumber sshPublicKey
```

### nsscache layer

```bash
# Check CronJob has completed at least once
kubectl get jobs -n tenant-slurm -l app.kubernetes.io/name=nsscache --sort-by=.status.startTime

# Check CronJob logs for errors
kubectl logs -n tenant-slurm -l job-name --tail=50
```

### Pod layer (user resolution)

```bash
# Verify user resolves via NSS
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- getent passwd <username>
# Expected: username:x:UID:GID:Full Name:/home/username:/bin/bash

# Verify group membership
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- id <username>

# Verify SSH key cache is populated
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- cat /etc/nsscache/sshkey.cache
# Expected: username:ssh-ed25519 AAAA...
```

### SSH layer

```bash
# Port-forward and test SSH login
kubectl port-forward -n tenant-slurm svc/slurm-login 2222:22 &
ssh -i <private-key> -p 2222 -o StrictHostKeyChecking=no <username>@localhost
```

### Slurm layer

```bash
# Verify user can submit jobs
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- su - <username> -c 'srun --mem=100 whoami'
# Expected: <username>
```

## Common Pitfalls

| Problem | Cause | Fix |
|---------|-------|-----|
| nsscache logs "Source map empty" | `ldap_scope` defaults to `ONE_LEVEL`, missing nested OUs | Set `ldap_scope: sub` |
| `getent passwd` returns nothing | Login pod has old volume mounts | Delete and recreate the pod |
| SSH key auth fails | `sshkey` map missing from nsscache config, or `ldapPublicKey` objectClass missing from LDIF | Add `sshkey` to `maps` list and verify LDIF objectClasses |
| "Permission denied" in /home | NFS home dir owned by root | `chown -R UID:GID /home/username` from the sshd container |
| Wrong LDAP filter objectClasses | Using AD classes (`user`, `group`) against OpenLDAP | Use `posixAccount`, `posixGroup`, `shadowAccount` |
