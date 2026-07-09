---
name: configure-sunk-user-auth
description: |
  Set up POSIX user authentication and SSH key injection for SUNK using
  OpenLDAP and nsscache. Enables multi-user access with proper UID/GID resolution
  and SSH public key authentication across all Slurm pods. Works on any provider.
  Use when: "add users to SUNK", "set up LDAP for Slurm", "configure nsscache",
  "enable multi-user auth on SUNK", "user authentication for SUNK",
  "nsscache source map empty", "getent not resolving users",
  "SSH key injection for SUNK", "configure SSH access to SUNK".
---

# Configure SUNK User Authentication (OpenLDAP + nsscache)

Deploy OpenLDAP as the POSIX user/group directory and configure the SUNK Helm chart's nsscache integration to sync users and SSH public keys into all Slurm pods. This enables password-less SSH login to SUNK login nodes.

> **Companion guide:** For a conceptual overview of the provisioning pipeline, alternative directory backends (existing LDAP/AD, SCIM), SSH key lifecycle management, and end-to-end SSH verification, see [`user-provisioning.md`](../../../docs/universal/user-provisioning.md). For a non-LDAP single-user path (useful for first verification), see [`bootstrap-sunk-local-user`](../bootstrap-sunk-local-user/SKILL.md).

## Prerequisites

- Base SUNK deployed and healthy (see your provider's deploy skill under `skills/<provider>/`)
- Slurm login node accessible via `kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- bash`
- Helm repo `coreweave/slurm` available and your provider's `helm-values/<provider>/slurm-values.yaml` exists

## Step 1: Deploy OpenLDAP

Create `infrastructure/openldap.yaml` with a Deployment, Service, and seed ConfigMap.

### Provider-specific notes for osixia/openldap:1.5.0

The image has two behaviors that break on managed Kubernetes:

1. **Read-only ConfigMap volumes** -- the image runs `chown` on the custom LDIF directory, which fails on a read-only ConfigMap mount. Fix: use an init container (`copy-seed`) to copy LDIFs from a read-only ConfigMap volume to a writable emptyDir.
2. **Volume removal on setup** -- the image runs `rm -rf` on the custom LDIF directory after processing. Fix: set the env var `LDAP_REMOVE_CONFIG_AFTER_SETUP=false`.

### Deployment spec

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openldap
  namespace: tenant-slurm
spec:
  replicas: 1
  selector:
    matchLabels: {app: openldap}
  template:
    metadata:
      labels: {app: openldap}
    spec:
      tolerations:
        - key: sunk.coreweave.com/lock
          operator: Exists
          effect: NoExecute
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: YOUR_CPU_NODE_LABEL_KEY
                    operator: In
                    values: ["YOUR_CPU_NODE_LABEL_VALUE"]
      initContainers:
        - name: copy-seed
          image: busybox:1.36
          command: ["sh", "-c", "cp /seed-ro/* /seed-rw/"]
          volumeMounts:
            - {name: ldap-seed-ro, mountPath: /seed-ro}
            - {name: ldap-seed-rw, mountPath: /seed-rw}
      containers:
        - name: openldap
          image: osixia/openldap:1.5.0
          ports:
            - {containerPort: 389, name: ldap}
          env:
            - {name: LDAP_ORGANISATION, value: "Your Org"}
            - {name: LDAP_DOMAIN, value: "example.local"}
            - {name: LDAP_ADMIN_PASSWORD, value: "admin"}
            - {name: LDAP_READONLY_USER, value: "true"}
            - {name: LDAP_READONLY_USER_USERNAME, value: "readonly"}
            - {name: LDAP_READONLY_USER_PASSWORD, value: "readonly"}
            - {name: LDAP_REMOVE_CONFIG_AFTER_SETUP, value: "false"}
          resources:
            requests: {cpu: 50m, memory: 128Mi}
            limits: {memory: 256Mi}
          volumeMounts:
            - {name: ldap-data, mountPath: /var/lib/ldap}
            - {name: ldap-config, mountPath: /etc/ldap/slapd.d}
            - {name: ldap-seed-rw, mountPath: /container/service/slapd/assets/config/bootstrap/ldif/custom}
      volumes:
        - {name: ldap-data, emptyDir: {}}
        - {name: ldap-config, emptyDir: {}}
        - name: ldap-seed-ro
          configMap: {name: openldap-seed}
        - {name: ldap-seed-rw, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata:
  name: openldap
  namespace: tenant-slurm
spec:
  selector: {app: openldap}
  ports:
    - {port: 389, targetPort: 389, protocol: TCP}
  type: ClusterIP
```

Replace `YOUR_CPU_NODE_LABEL_KEY` and `YOUR_CPU_NODE_LABEL_VALUE` with the node selector labels used by your provider (e.g., `cloud.google.com/gke-nodepool: cpu-4` for GKE, or `eks.amazonaws.com/nodegroup: cpu` for EKS). Adjust `LDAP_DOMAIN`/`LDAP_ORGANISATION` as needed.

### Seed LDIF (ConfigMap)

Use these objectClasses for nsscache compatibility:
- **Users**: `inetOrgPerson`, `posixAccount`, `shadowAccount`, `ldapPublicKey` (for SSH keys)
- **Groups**: `posixGroup`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openldap-seed
  namespace: tenant-slurm
data:
  01-users.ldif: |
    dn: ou=users,dc=example,dc=local
    objectClass: organizationalUnit
    ou: users

    dn: ou=groups,dc=example,dc=local
    objectClass: organizationalUnit
    ou: groups

    dn: cn=slurm-users,ou=groups,dc=example,dc=local
    objectClass: posixGroup
    cn: slurm-users
    gidNumber: 10000
    memberUid: jdoe

    dn: cn=slurm-admins,ou=groups,dc=example,dc=local
    objectClass: posixGroup
    cn: slurm-admins
    gidNumber: 10001
    memberUid: admin

    dn: uid=jdoe,ou=users,dc=example,dc=local
    objectClass: inetOrgPerson
    objectClass: posixAccount
    objectClass: shadowAccount
    objectClass: ldapPublicKey
    uid: jdoe
    cn: Jane Doe
    sn: Doe
    givenName: Jane
    uidNumber: 10001
    gidNumber: 10000
    homeDirectory: /home/jdoe
    loginShell: /bin/bash
    userPassword: changeme
    sshPublicKey: ssh-ed25519 AAAA_REPLACE_WITH_USERS_PUBLIC_KEY jdoe@example
```

Deploy and verify:

```bash
kubectl apply -f infrastructure/openldap.yaml

# Wait for pod to be ready
kubectl wait -n tenant-slurm deployment/openldap --for=condition=Available --timeout=120s

# Verify LDAP entries are accessible via the readonly bind user
kubectl exec -n tenant-slurm deployment/openldap -- \
  ldapsearch -x -H ldap://localhost -b "dc=example,dc=local" \
  -D "cn=readonly,dc=example,dc=local" -w "readonly" \
  "(objectClass=posixAccount)" uid uidNumber
```

You should see each user's `uid` and `uidNumber` in the output. If the search returns nothing, the seed LDIF was not loaded. Check pod logs with `kubectl logs -n tenant-slurm deployment/openldap`.

## Step 2: Create LDAP Secret

nsscache needs credentials to bind to LDAP. Create a secret with the readonly password:

```bash
kubectl create secret generic nsscache-ldap-credentials \
  --from-literal=nsscache-ldap-password='readonly' \
  -n tenant-slurm
```

## Step 3: Enable nsscache in slurm-values.yaml

Add the following block to your provider's `helm-values/<provider>/slurm-values.yaml`:

```yaml
nsscache:
  enabled: true
  existingSecret: nsscache-ldap-credentials
  cronJobSchedule: "* * * * *"
  tolerations:
    - key: sunk.coreweave.com/lock
      operator: Exists
      effect: NoExecute
  resources:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {memory: 256Mi}
  sudoGroups:
    - slurm-admins
  nsscacheConfig:
    default:
      source: ldap
      cache: files
      maps: [passwd, shadow, group, sshkey]
      timestamp_dir: /var/lib/nsscache
      ldap_uri: "ldap://openldap.tenant-slurm.svc.cluster.local:389"
      ldap_base: "dc=example,dc=local"
      ldap_bind_dn: "cn=readonly,dc=example,dc=local"
      ldap_rfc2307bis: 0
      ldap_default_shell: "/bin/bash"
      ldap_scope: sub
      files_dir: /etc/nsscache
      files_cache_filename_suffix: cache
    passwd:
      ldap_filter: "(objectClass=posixAccount)"
    group:
      ldap_filter: "(objectClass=posixGroup)"
    shadow:
      ldap_filter: "(objectClass=shadowAccount)"
    sshkey:
      ldap_filter: "(objectClass=ldapPublicKey)"
  nsswitchConfig:
    passwd: [files, cache]
    group: [files, cache]
    shadow: []
```

### Critical settings

- **`ldap_scope: sub`** -- REQUIRED. Without this, nsscache uses `ONE_LEVEL` scope and misses entries nested under `ou=users` or `ou=groups`. This is the single most common cause of "Source map empty" errors.
- **`ldap_rfc2307bis: 0`** -- Use 0 for standard `posixAccount`/`posixGroup` schema (RFC 2307). Set to 1 only if your directory uses RFC 2307bis (`groupOfNames` with `member` DN attributes).
- **LDAP filters** -- Must reference `posixAccount`, `posixGroup`, `shadowAccount`. Do NOT use `user` or `group`, which are Active Directory objectClasses and will match nothing in OpenLDAP.
- **`cronJobSchedule: "* * * * *"`** -- Syncs every minute. Adjust to `*/5 * * * *` or less frequent once initial setup is confirmed working.

## Step 4: Helm Upgrade and Restart

```bash
helm upgrade slurm coreweave/slurm \
  -f helm-values/<provider>/slurm-values.yaml \
  --set-json 'global.nodeSelector.affinity=null' \
  -n tenant-slurm

# Wait for the nsscache CronJob to complete at least one run (up to 60 seconds)
sleep 65

# Restart the login pod so it picks up the new nsscache volume mounts
kubectl delete pod slurm-login-0 -n tenant-slurm

# Wait for it to come back
kubectl wait -n tenant-slurm pod/slurm-login-0 --for=condition=Ready --timeout=120s
```

Replace `<provider>` with your provider directory (e.g., `gke`, `eks`).

## Step 5: Fix Home Directory Ownership

NFS-backed home directories are created as root when the user first logs in or a job runs. Fix ownership for each user:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  chown -R 10001:10000 /home/jdoe
```

Replace `10001:10000` with the user's `uidNumber:gidNumber` and `/home/jdoe` with their home directory.

## Step 6: Verify

```bash
# Check user resolution via NSS
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- getent passwd jdoe
# Expected: jdoe:x:10001:10000:Jane Doe:/home/jdoe:/bin/bash

# Check group membership
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- id jdoe
# Expected: uid=10001(jdoe) gid=10000(slurm-users) groups=10000(slurm-users)

# Submit a Slurm job as the user
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- su - jdoe -c 'srun --mem=100 whoami'
# Expected: jdoe
```

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| nsscache logs show "Source map empty" | `ldap_scope` defaults to `ONE_LEVEL`, missing nested OUs | Set `ldap_scope: sub` in nsscacheConfig |
| OpenLDAP pod crashes with "Read-only file system" | ConfigMap volume is read-only, image tries to `chown` | Add `copy-seed` init container to copy LDIFs to an emptyDir |
| OpenLDAP logs "cannot remove /container/.../custom" | Image tries to delete LDIF dir after setup | Set env `LDAP_REMOVE_CONFIG_AFTER_SETUP=false` |
| `getent passwd` returns nothing after helm upgrade | Login pod still has old volume mounts | Delete and recreate the pod: `kubectl delete pod slurm-login-0 -n tenant-slurm` |
| "Permission denied" creating files in /home/user | NFS home dir owned by root | Run `chown -R UID:GID /home/username` from the sshd container |
| nsscache CronJob fails with LDAP connection error | OpenLDAP pod not running or service DNS not resolving | Verify with `kubectl get pods -l app=openldap -n tenant-slurm` and check service exists |
| Users resolve but `srun` fails with "Invalid user" | Slurm compute nodes have not synced nsscache yet | Wait for the next CronJob run, then restart compute pods if needed |
| LDAP search returns entries but nsscache finds none | Wrong objectClass in LDAP filter (e.g., `user` instead of `posixAccount`) | Use `posixAccount`, `posixGroup`, `shadowAccount` in filters |
| SSH key auth fails, password prompted instead | `sshkey` map missing from nsscache config or `ldapPublicKey` objectClass missing from LDIF | Add `sshkey` to `maps` list and `sshkey` section with `ldap_filter: "(objectClass=ldapPublicKey)"` |
| `/etc/sshkey.cache` is empty or missing | nsscache CronJob did not sync SSH keys | Check CronJob logs: `kubectl logs -n tenant-slurm -l job-name --tail=50`; verify `sshkey` is in maps list |
| SSH connection rejected with "Permission denied (publickey)" | Key in LDAP does not match client key, or sshkey.cache not mounted | Verify key matches: `kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- cat /etc/nsscache/sshkey.cache` |

## How SSH Key Authentication Works

Understanding the end-to-end flow helps diagnose issues and explains why each configuration piece matters.

### Architecture

```
┌──────────┐     ┌──────────────┐     ┌──────────────────┐     ┌───────────────┐
│  Admin    │────>│   OpenLDAP   │────>│  nsscache        │────>│ K8s Secrets   │
│ (LDIF)   │     │  (directory) │     │  (CronJob)       │     │ (cache files) │
└──────────┘     └──────────────┘     └──────────────────┘     └───────┬───────┘
                                                                       │
                                                                       │ projected
                                                                       │ volume
                                                                       ▼
┌──────────┐     ┌──────────────┐     ┌──────────────────┐     ┌───────────────┐
│  User    │────>│   sshd       │────>│ AuthorizedKeys   │────>│ sshkey.cache  │
│ (ssh)    │     │  (login pod) │     │ Command (python)  │     │ (/etc/nsscache)│
└──────────┘     └──────────────┘     └──────────────────┘     └───────────────┘
```

### Step-by-step flow

1. **Admin adds SSH key to LDAP.** The user's LDIF entry includes `objectClass: ldapPublicKey` and one or more `sshPublicKey` attributes containing the user's public key(s).

2. **nsscache CronJob syncs keys.** The CronJob runs on the configured schedule (default: every minute). It queries LDAP for all entries matching `(objectClass=ldapPublicKey)`, extracts the `sshPublicKey` attributes, and writes them to `/etc/nsscache/sshkey.cache` in the format `username:ssh-ed25519 AAAA...`.

3. **CronJob stores cache as K8s Secret.** The `nsscache-update.sh` script creates/updates a Secret named `slurm-nsscache-sshkey` containing the `sshkey.cache` file.

4. **Secret projected into pods.** The Helm chart's `nsscache-results` projected volume mounts Secrets for each map (passwd, shadow, group, sshkey) into `/etc/nsscache/` on all Slurm pods (login, compute, controller).

5. **User initiates SSH connection.** The user runs `ssh -p <port> username@<login-node-address>`.

6. **sshd invokes AuthorizedKeysCommand.** The sshd config contains `AuthorizedKeysCommand /usr/local/share/nsscache-authorized-keys-command.py`. OpenSSH calls this script with the connecting username.

7. **Script looks up keys in cache.** The Python script reads `/etc/sshkey.cache` (symlinked from the projected volume at `/etc/nsscache/sshkey.cache`), finds all lines matching the username, and prints matching public keys to stdout.

8. **sshd validates the key.** If the user's offered key matches one returned by the script, authentication succeeds and the user gets a shell.

### Key files in the Helm chart

| File | Purpose |
|------|---------|
| `scripts/nsscache-authorized-keys-command.py` | Python script invoked by sshd to look up SSH keys from cache |
| `scripts/nsscache-update.sh` | Shell script run by the CronJob to sync LDAP data and create K8s Secrets |
| `templates/config/sshd-conf-configmap.yaml` | Adds `AuthorizedKeysCommand` directive when nsscache is enabled |
| `templates/config/nsscache-conf-configmap.yaml` | Generates nsscache.conf from Helm values |
| `templates/nsscache-update-cronjob.yaml` | CronJob definition, RBAC, and ConfigMap for the update script |
| `templates/_helpers.tpl` (`nsscache.volumeMounts`) | Mounts nsscache results, script, and configs into all pod types |

## First Login: End-to-End Walkthrough

Follow these steps to verify SSH key authentication works for a new user. This assumes you have completed Steps 1-5 above.

### 1. Generate a test SSH key pair (if you don't have one)

```bash
ssh-keygen -t ed25519 -f /tmp/sunk-test-key -N "" -C "testuser@sunk"
cat /tmp/sunk-test-key.pub
# Output: ssh-ed25519 AAAAC3... testuser@sunk
```

### 2. Add the public key to the LDAP seed LDIF

Replace the placeholder `sshPublicKey` value in your `openldap-seed` ConfigMap with the actual public key from step 1:

```yaml
sshPublicKey: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... testuser@sunk
```

If OpenLDAP is already running, either:
- Redeploy: `kubectl delete -f infrastructure/openldap.yaml && kubectl apply -f infrastructure/openldap.yaml`
- Or add the key via ldapmodify:
  ```bash
  kubectl exec -n tenant-slurm deployment/openldap -- \
    ldapmodify -x -H ldap://localhost -D "cn=admin,dc=example,dc=local" -w "admin" <<EOF
  dn: uid=testuser,ou=users,dc=example,dc=local
  changetype: modify
  replace: sshPublicKey
  sshPublicKey: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... testuser@sunk
  EOF
  ```

### 3. Verify LDAP has the SSH key

```bash
kubectl exec -n tenant-slurm deployment/openldap -- \
  ldapsearch -x -H ldap://localhost -b "dc=example,dc=local" \
  -D "cn=readonly,dc=example,dc=local" -w "readonly" \
  "(uid=testuser)" sshPublicKey
# Should show the sshPublicKey attribute with your key
```

### 4. Wait for nsscache sync and verify

```bash
# Wait for the next CronJob run (up to 60 seconds)
sleep 65

# Verify user resolution
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- getent passwd testuser
# Expected: testuser:x:10001:10000:Test User:/home/testuser:/bin/bash

# Verify SSH key cache contains the key
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- cat /etc/nsscache/sshkey.cache
# Expected: testuser:ssh-ed25519 AAAAC3...
```

### 5. SSH into the login node

```bash
# Port-forward the login node's SSH port
kubectl port-forward -n tenant-slurm svc/slurm-login 2222:22 &

# SSH using the test key
ssh -i /tmp/sunk-test-key -p 2222 -o StrictHostKeyChecking=no testuser@localhost

# You should get a shell as testuser
whoami    # testuser
srun --mem=100 hostname   # runs on a compute node
```

### 6. For production: expose via LoadBalancer

Instead of port-forwarding, set `login.service.type: LoadBalancer` in your Helm values:

```yaml
login:
  service:
    type: LoadBalancer
    externalTrafficPolicy: ""
```

After `helm upgrade`, get the external IP:

```bash
kubectl get svc -n tenant-slurm slurm-login -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Users can then SSH directly: `ssh -i ~/.ssh/mykey username@<external-ip>`

## User Provisioning Paths

This skill covers the simplest path (in-cluster OpenLDAP). Two other options exist for larger deployments.

### Path 1: In-Cluster OpenLDAP (this guide)

Best for: evaluation, small teams, environments without existing directory services.

Users are defined in an LDIF seed ConfigMap. SSH keys are stored as `sshPublicKey` attributes. Adding or removing users requires updating the LDIF and redeploying OpenLDAP (or using `ldapmodify`).

### Path 2: Existing LDAP or Active Directory

Best for: enterprises with an existing directory. Point nsscache at the corporate LDAP:

```yaml
nsscacheConfig:
  default:
    ldap_uri: "ldap://corp-ldap.example.com:389"
    ldap_base: "dc=corp,dc=example,dc=com"
    ldap_bind_dn: "cn=sunk-reader,ou=service-accounts,dc=corp,dc=example,dc=com"
    ldap_rfc2307bis: 1   # 1 for Active Directory / RFC 2307bis
    ldap_scope: sub
```

For Active Directory, use `ldap_rfc2307bis: 1` and adjust LDAP filters to match your schema. AD stores SSH keys differently; you may need the `msDS-cloudExtensionAttribute` or a custom schema extension.

### Path 3: SCIM (Okta, Azure AD)

Best for: cloud-first organizations using identity providers with SCIM support. Configure nsscache with SCIM source instead of LDAP:

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
