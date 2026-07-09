# How SSH access works on SUNK

A common first-touch mental model is that SUNK exposes an HTTP endpoint you
log into with credentials from a Kubernetes Secret. It doesn't. SSH on SUNK
is plain OpenSSH, running inside the login pod, listening on port 22,
exposed through a Kubernetes Service. This page explains the whole path so
you can debug any step.

## Pick your path

Three ways to populate Linux users + SSH keys onto a SUNK cluster. Pick one
per cluster. They share the same endpoint plumbing (sections 1-2 below)
and differ only in how users land inside the pod (section 3).

| Path | When to pick it | Skill / Doc | Status on `sunk-anywhere` |
|------|-----------------|-------------|----------------------------|
| **Simple: SSH key + Linux user + sacctmgr** | Small teams, first-touch verification, demos, no existing identity stack. One user per invocation. | [`bootstrap-sunk-local-user`](../../skills/universal/bootstrap-sunk-local-user/SKILL.md) | **Default.** Recommended starting point. |
| **authentik + sssd** | You already run authentik; need cross-pod identity, LDAP groups, dynamic user lifecycle, or PAM hooks. | [`configure-sunk-authentik-sssd`](../../skills/universal/configure-sunk-authentik-sssd/SKILL.md) | **Opt-in.** Validated minimal profile ships under `infrastructure/universal/authentik-minimal/`. |
| **CoreWeave IAM + nsscache + SCIM** | CoreWeave Cloud customers only. | CoreWeave Cloud Console docs. | **Not available on sunk-anywhere.** See note below. |

> **CoreWeave IAM SCIM note:** SUNK on CoreWeave Cloud is provisioned
> differently — CW IAM pushes POSIX users via SCIM into a cluster-managed
> nsscache, and the chart's `nsscache.enabled: true` path consumes it.
> That pipeline depends on CoreWeave control-plane components that do not
> exist on EKS/GKE. If you're reading this doc, you're on a managed
> cluster outside CW Cloud and the SCIM path is not available to you —
> pick simple or authentik+sssd.

**SSH keys always live on shared NFS** at `/home/<user>/.ssh/authorized_keys`,
regardless of which path you pick. sssd is **not** wired to serve keys by
default — the chart only templates `ldap_user_ssh_public_key` for
`schema: AD` (via the `altSecurityIdentities` attribute), not for
`rfc2307bis`. If you want sssd to serve keys on the authentik path, you
must add an `additionalConfig` snippet (see section 3.B below, marked
untested). For simple path + sssd-without-key-serving, sshd falls through
to `AuthorizedKeysFile /home/%u/.ssh/authorized_keys` on the NFS mount,
which Just Works.

## What's actually running

```
                 laptop                 cluster
                 ─────                  ─────────────────────────────────────
                                        ┌────────────────────────────────────┐
                                        │ Service: slurm-login               │
ssh -i key \                            │ type: LoadBalancer (EKS)           │
   user@<HOST> ────────> 22 ──────────> │   or ClusterIP  (GKE default)      │
                                        │   or NodePort                      │
                                        └──────────────┬─────────────────────┘
                                                       │
                                        ┌──────────────┴─────────────────────┐
                                        │ Pod: slurm-login-0                 │
                                        │  Container: sshd (openssh)         │
                                        │  Port: 22                          │
                                        │  Reads: /home/$USER/.ssh/authorized_keys
                                        │  Mount: NFS /home (RWX)            │
                                        └────────────────────────────────────┘
```

Three questions decide whether SSH works:
1. Can your laptop reach `<HOST>:22`? (Service type + firewall)
2. Does `<HOST>` route to the login pod's sshd? (Service selector, pod
   health)
3. Does sshd let you in? (authorized_keys populated, user resolvable)

Each section below answers one of the three.

## 1. Reaching the login pod from your laptop

### EKS: Network Load Balancer

`helm-values/eks/slurm-values.yaml` exposes the login service as a
LoadBalancer with NLB annotations:

```yaml
login:
  service:
    type: LoadBalancer
    metadata:
      global:
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-type: nlb
          service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
          service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
```

After `helm install`:

```bash
kubectl get svc -n tenant-slurm slurm-login
# NAME          TYPE           EXTERNAL-IP                                 PORT(S)
# slurm-login   LoadBalancer   abc123.elb.us-east-1.amazonaws.com          22:30237/TCP
HOST=$(kubectl get svc -n tenant-slurm slurm-login -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

Security group: the NLB itself is wide open but it targets the worker
nodes' ENIs. You must allow inbound TCP/22 on the worker-node SG from your
laptop's public IP (or 0.0.0.0/0 for open clusters):

```bash
MYIP=$(curl -s ifconfig.me)
SG=$(aws eks describe-cluster --name sunk-eks --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "$MYIP/32"
```

### GKE: ClusterIP + port-forward (default) or LoadBalancer (opt-in)

The GKE path keeps the login service as ClusterIP by default to dodge
egress cost; customers port-forward from their laptop:

```bash
kubectl port-forward -n tenant-slurm svc/slurm-login 2222:22
ssh -i ~/.ssh/id_ed25519 -p 2222 user@localhost
```

If you want a public IP, flip the service to LoadBalancer in your values
overlay. GKE will provision a Google network LB automatically; no
annotations required for a basic L4. Add a firewall rule to let your IP
reach port 22.

### NodePort (any cloud, any cluster)

If you override `service.type: NodePort`, the login service gets a random
port in 30000-32767 on every node. Either node's public IP routes kube-proxy
traffic to the pod, regardless of which node the pod is on:

```bash
kubectl get svc -n tenant-slurm slurm-login
# NAME          TYPE       PORT(S)
# slurm-login   NodePort   22:30237/TCP
PORT=$(kubectl get svc -n tenant-slurm slurm-login -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
ssh -p "$PORT" user@"$NODE_IP"
```

## 2. Service → Pod routing

If `ssh -v` says "connected to HOST:22" and then hangs or closes, the
Service routes to the node but the pod isn't accepting. Check:

```bash
kubectl get pod -n tenant-slurm slurm-login-0
# Expect: 2/2 Running. If 0/2 Pending -> resources. If 1/2 Running -> look at the sshd container specifically.
kubectl describe svc -n tenant-slurm slurm-login | grep Endpoints
# Expect: <pod-ip>:22. If empty, the service selector isn't matching any pod.
kubectl logs -n tenant-slurm slurm-login-0 -c sshd --tail=30
# Expect: "Server listening on 0.0.0.0 port 22." at startup.
```

Two services exist:
- `slurm-login` -- selects all login pods (useful when replicas > 1)
- `slurm-login-0` -- sticky to pod-0 specifically (useful when you need to
  reach that exact replica)

With the default `login.replicas: 1` both route to the same pod.

## 3. Who can log in

sshd inside the login pod uses the chart's `/etc/ssh/sshd_config`: public-key
auth enabled, password auth disabled, `AuthorizedKeysFile` pointing at
`%h/.ssh/authorized_keys` (the user's NFS home). The two supported paths
differ only in how `/etc/passwd` and `/home/<user>/.ssh/authorized_keys`
get populated.

### Path A: Simple (default) — `bootstrap-sunk-local-user` skill

You run `infrastructure/universal/add-sunk-user.sh add --username alice
--uid 1001 --gid 1001 --email alice@example.com --ssh-key "$(cat
~/.ssh/id_ed25519.pub)"`. The helper creates a Linux account on the login
pod, writes `authorized_keys` on the shared NFS, and registers the user
with slurmdbd so `sbatch` works without `sacctmgr add user` first. One
user per invocation. Idempotent.

- **Rotation**: `add-sunk-user.sh update-key --username alice --ssh-key ...`
- **Removal**: `add-sunk-user.sh remove --username alice --confirm`
  (removes Linux user + Slurm association; preserves sacct history)
- **Scope**: user is resolvable on the login pod only. Compute-pod
  identity requires `compute.extraUsers` in your provider values — see
  the skill's Step 2 or `infrastructure/universal/user-provisioning.md`.

### Path B: authentik + sssd — `configure-sunk-authentik-sssd` skill

You deploy authentik as the directory source and enable sssd on every
SUNK pod. User lifecycle is managed in authentik; sssd resolves `alice`
to UID 1001 on login and compute pods uniformly. See the skill for the
directoryService values generator and the `authentik-minimal` validation
profile.

SSH keys still live on NFS `/home/<user>/.ssh/authorized_keys`. The
chart does not template `ldap_user_ssh_public_key` for
`schema: rfc2307bis` — it only does so for `schema: AD`. If you want
sssd to serve keys from authentik (instead of NFS), add this
`additionalConfig` snippet to your `directoryService.directories[]`
entry:

```yaml
directoryService:
  directories:
    - name: authentik
      schema: rfc2307bis
      # ...usual connection/bind config...
      additionalConfig: |
        ldap_user_ssh_public_key = sshPublicKey
```

**Untested on sunk-anywhere.** The authentik LDAP outpost must expose
the `sshPublicKey` attribute (under `ldapPublicKey` objectClass), and
sshd's `AuthorizedKeysCommand sss_ssh_authorizedkeys` must be wired.
The chart bakes the `AuthorizedKeysCommand` into the login pod's
`sshd_config`, but we haven't validated the authentik side end-to-end.
Until we do, keep keys on NFS — either via `add-sunk-user.sh`
(simple+authentik hybrid) or by directly writing `authorized_keys`.

#### Key rotation on the authentik path

authentik alone is not enough. Update the key in authentik (so any
future rollout from authentik is correct) AND rewrite the NFS file (so
today's sshd accepts the new key):

```bash
# 1. Update in authentik via UI or API
# 2. Rewrite NFS file
./infrastructure/universal/add-sunk-user.sh update-key \
    --username alice --ssh-key "$(cat new.pub)"
# 3. Drift check: both should match
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
    cat /home/alice/.ssh/authorized_keys
# Compare to the key stored in authentik.
```

#### Removal on the authentik path

Disable the user in authentik (so future logins stop) AND remove the
NFS key (so existing sessions + sshd stop trusting the old key):

```bash
# 1. Disable user in authentik UI
# 2. Remove the NFS key
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
    rm -f /home/alice/.ssh/authorized_keys
```

Full removal (home dir, Slurm association) is a manual `userdel -r` +
`sacctmgr remove user` — the simple path's `add-sunk-user.sh remove`
does both atomically if you want to use it as a cleanup helper even on
authentik clusters.

### Which path do I have?

```bash
# Is sssd running in the login pod?
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- pgrep -x sssd && echo "authentik path" || echo "simple path"

# Is nsscache running? (Only CW Cloud clusters; sunk-anywhere should say "no")
kubectl get cronjob -n tenant-slurm -l app.kubernetes.io/component=nsscache-update
```

## What SUNK does NOT have

- **No HTTP login endpoint.** `slurm-login` is port 22/tcp, not 80 or 443.
  There is no web terminal out of the box. (You can layer one via SkyPilot,
  Open OnDemand, or similar, but that's separate.)
- **No Kubernetes-Secret-based auth.** Your SSH key doesn't live in a
  `Secret`. The chart provisions an `sshKeyVolume` PVC for the login pod's
  *host keys* (so sshd's identity is stable across restarts), not for user
  keys.
- **No automatic user creation from `kubectl auth`.** Cluster-admin on
  Kubernetes does not give you a UNIX account on the login pod. You must
  provision users explicitly via one of the two skills above.

## See also

- [`skills/universal/bootstrap-sunk-local-user/SKILL.md`](../../skills/universal/bootstrap-sunk-local-user/SKILL.md) — simple path walkthrough.
- [`skills/universal/configure-sunk-authentik-sssd/SKILL.md`](../../skills/universal/configure-sunk-authentik-sssd/SKILL.md) — authentik+sssd walkthrough.
- [`infrastructure/universal/add-sunk-user.sh`](../../infrastructure/universal/add-sunk-user.sh) — the helper script both paths reuse for NFS key drops.
- [`infrastructure/universal/user-provisioning.md`](../../infrastructure/universal/user-provisioning.md) — the simple path's attributes, limitations, and compute-pod identity options.
- [`docs/universal/user-provisioning.md`](user-provisioning.md) — nsscache/LDAP conceptual reference (legacy; see banner).
- [`docs/universal/troubleshooting.md`](troubleshooting.md) section "User Authentication" — the usual failure modes (Permission denied publickey, user not found, home dir permissions).
