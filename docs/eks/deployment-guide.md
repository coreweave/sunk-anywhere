# Deploying SUNK on EKS

Production-grade Slurm on a budget-friendly AWS cluster.

> All configuration follows [docs/eks/conventions.md](conventions.md). Read it first. Labels, nodegroup names, StorageClass names, namespaces, AWS tags, and version pins all come from there.

---

## Prerequisites

### Tools

| Tool | Purpose |
|------|---------|
| `aws` CLI v2 | AWS API access; authenticated against the target account |
| `eksctl` | Cluster creation (`brew install eksctl`) |
| `helm` 3 | Chart installs |
| `kubectl` | Cluster access |
| `jq` | Pipeline glue used by the scripts |
| `envsubst` | Template rendering (shipped with `gettext`) |

### AWS account

- Programmatic credentials wired to an `aws` CLI profile.
- AWS region (default: `us-east-1`).
- Service quotas:
  - **Standard vCPU** (`L-1216C47A`) ≥ 32 — covers the 2x m5.large control plane plus bootstrap transients.
  - **G/VT on-demand vCPU** (`L-DB2E81BA`) ≥ 8 — only required if the GPU nodegroup will be enabled. If denied, take the CPU-only fallback below.

### Budget awareness

Default profile is ~$6.70/day idle, ~$14-30/day with one GPU. See [cost-table.md](cost-table.md) for the full breakdown. The cost estimator (Step 11) enforces the $50/day ceiling.

---

## Step 1 — Check quotas

```bash
AWS_REGION=us-east-1
AWS_PROFILE=your-profile

aws service-quotas get-service-quota --service-code ec2 \
  --quota-code L-1216C47A --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'Quota.Value' --output text

aws service-quotas get-service-quota --service-code ec2 \
  --quota-code L-DB2E81BA --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'Quota.Value' --output text
```

If Standard vCPU < 32, request an increase and wait before proceeding. AWS typically approves modest Standard increases within a few hours. If G/VT vCPU < 8, you can still proceed: keep `compute.nodes.gpu-workers.enabled: false` and skip Step 7.

---

## Step 2 — Create the cluster

Runs in ~15-20 minutes. Creates the VPC, the EKS control plane, and the three nodegroups defined in `infrastructure/eks/cluster-config.yaml`:

- `cpu-control`: 2x `m5.large` on-demand, always running, hosts the controller, MOCO, login, syncer, scheduler.
- `cpu-workers`: 0-2x `m5.large` spot, scale-to-zero, CPU Slurm compute.
- `gpu-workers`: 0-1x `g5.xlarge` spot, scale-to-zero, GPU Slurm compute (opt-in in Step 7).

```bash
infrastructure/eks/create-cluster.sh \
  --name sunk-eks \
  --region us-east-1 \
  --profile your-profile
```

The script also:

- Patches `gp2` to non-default and applies `gp3` as the cluster's default StorageClass.
- Writes the kubeconfig to `~/.kube/config`.
- Tags every AWS resource with `ManagedBy=sunk-anywhere` so `destroy-all.sh` can find them later.

Verify:

```bash
kubectl get nodes
# Expect 2 Ready nodes labeled eks.amazonaws.com/nodegroup=cpu-control
kubectl get storageclass
# Expect gp3 marked (default); gp2 not default
```

---

## Step 3 — Configure IRSA

Creates the cluster OIDC provider and the three IAM roles that controllers in Step 4 need.

```bash
infrastructure/eks/setup-irsa.sh \
  --cluster sunk-eks --region us-east-1 --profile your-profile
```

Produces:

| ServiceAccount | Role | Purpose |
|----------------|------|---------|
| `kube-system/ebs-csi-controller-sa` | `AmazonEKS_EBS_CSI_DriverRole-sunk-eks` | EBS volume provisioning |
| `kube-system/efs-csi-controller-sa` | `AmazonEKS_EFS_CSI_DriverRole-sunk-eks` | EFS access point provisioning |
| `kube-system/aws-load-balancer-controller` | `AmazonEKS_LoadBalancer_ControllerRole-sunk-eks` | NLB for the login service |

Idempotent; safe to re-run after adding a controller later.

---

## Step 4 — Install cluster controllers

Installs in dependency order: EBS CSI, EFS CSI, AWS Load Balancer Controller, cert-manager, MOCO. Order matters — cert-manager must be Ready before MOCO's webhooks come up, and the AWS LB Controller must be Ready before any `service.beta.kubernetes.io/aws-load-balancer-type: nlb` annotation takes effect.

```bash
infrastructure/eks/install-controllers.sh \
  --cluster sunk-eks --region us-east-1 --profile your-profile
```

Verify all 5 controllers reached `Available`:

```bash
kubectl get deploy -n kube-system ebs-csi-controller aws-load-balancer-controller
kubectl get deploy -n kube-system | grep efs-csi-controller
kubectl get deploy -n cert-manager
kubectl get deploy -n moco-system
```

---

## Step 5 — Shared storage (pick one)

Slurm needs a shared `/home` accessible from every compute node. Pick the budget path or the EFS path, not both.

### Budget: in-cluster NFS pod (default)

A single pod exports 100Gi of gp3-backed NFS. Costs the EBS volume only (~$8/mo).

```bash
kubectl create namespace slurm
kubectl apply -f infrastructure/eks/storage/nfs-server-pod-eks.yaml
kubectl wait --for=condition=Available -n slurm deployment/nfs-server --timeout=5m
```

Provisions the `nfs-backing-pvc` on gp3, the `nfs-server` Deployment pinned to `cpu-control`, a ClusterIP service, and the static `slurm-home` PVC that the SUNK chart consumes by name.

### Production: managed EFS

Creates an EFS filesystem with one mount target per cluster subnet, a security group allowing NFS/2049 from the cluster, and the `efs-sc` StorageClass.

```bash
infrastructure/eks/storage/setup-efs.sh \
  --cluster sunk-eks --region us-east-1 --profile your-profile
```

Writes the new FS ID to `/tmp/sunk-efs-id`. Render the PV for shared `/home`:

```bash
sed "s/__EFS_FS_ID__/$(cat /tmp/sunk-efs-id)/g" \
  infrastructure/eks/storage/efs-pv-home.yaml.template | kubectl apply -f -
```

---

## Step 6 — Install SUNK + Slurm

The SUNK and Slurm charts are licensed. Reach out to CoreWeave at
<sunk@coreweave.com> for access instructions, then substitute the repository
URL you receive for `<COREWEAVE_HELM_REPO_URL>` below.

```bash
helm repo add coreweave <COREWEAVE_HELM_REPO_URL>
helm repo update

helm install sunk coreweave/sunk -n slurm --create-namespace \
  -f helm-values/base/sunk-values.yaml \
  -f helm-values/eks/sunk-values.yaml

helm install slurm coreweave/slurm -n slurm \
  -f helm-values/base/slurm-values.yaml \
  -f helm-values/eks/slurm-values.yaml
```

> **Security note (required reading for compliance review):** the EKS overlay
> runs `slurmd` privileged with `SYS_NICE`, `SYS_ADMIN`, `SYS_PTRACE`, `SYSLOG`
> and disables the chart's AppArmor + seccomp profile references for pyxis.
> This is **not optional** under current EKS AMI cgroup semantics. Full threat
> model, rationale, and hardening knobs are in [../universal/security-model.md](../universal/security-model.md).
> Read it before approving this deploy in a regulated environment.

**Expected transient state:** the syncer and scheduler pods show `CreateContainerConfigError` for 2-3 minutes while `slurm-secret-job` generates the JWT and auth secrets. This is NORMAL. Do not delete or restart pods during this window; that only extends the outage. Watch for the transition:

```bash
kubectl get pods -n slurm -w
# Wait for slurm-secret-job Completed, then scheduler/syncer should reach Running
```

---

## Step 7 — (Optional) Add GPU

Default has `compute.nodes.gpu-workers.enabled: false` so the GPU nodegroup stays at size 0. To bring up a single g5.xlarge A10G (or g6.xlarge L4 fallback), follow the skill:

```
skills/eks/add-gpu-nodes-to-eks/SKILL.md
```

The skill handles G/VT quota check, `eksctl create nodegroup --spot`, device-plugin verification (EKS GPU AMI auto-installs it), flipping `gpu-workers.enabled: true` in values, and re-running the toleration patch. Keep spot + scale-to-zero on; a g5.xlarge on-demand 24/7 blows the $50/day ceiling.

---

## Step 8 — (Optional) Install observability

```bash
infrastructure/eks/observability/install.sh
```

Installs kube-prometheus-stack in the `monitoring` namespace, applies the syncer `PodMonitor` in `slurm`, and deploys the DCGM exporter (runs only on `gpu-workers`). Prints the Grafana admin password and the port-forward command.

---

## Step 9 — Patch system tolerations

After the first compute pod lands, SUNK taints that node with `sunk.coreweave.com/lock=true:NoExecute`. Any system pod on that node without a matching toleration gets evicted. Run the skill:

```
skills/eks/patch-eks-system-tolerations/SKILL.md
```

The underlying script is `infrastructure/eks/patch-eks-tolerations.sh`. It patches `aws-node`, `kube-proxy`, `ebs-csi-node`, `efs-csi-node`, `nvidia-device-plugin-daemonset` (when present), `coredns`, `cert-manager*`, `moco-controller`, and `dcgm-exporter`. Re-run after every EKS upgrade — managed add-ons are re-deployed during the upgrade and lose the custom toleration.

---

## Step 10 — Verify (do NOT proceed until ALL 7 checks pass)

```bash
# 1. Partitions and nodes report as idle
kubectl exec -n slurm slurm-login-0 -c sshd -- sinfo

# 2. Minimal CPU job
kubectl exec -n slurm slurm-login-0 -c sshd -- srun --mem=100 hostname

# 3. Multi-node CPU job
kubectl exec -n slurm slurm-login-0 -c sshd -- srun -N2 --mem=100 hostname

# 4. GPU job (skip if CPU-only fallback is in effect)
kubectl exec -n slurm slurm-login-0 -c sshd -- srun --gres=gpu:1 nvidia-smi

# 5. Shared /home round-trip
kubectl exec -n slurm slurm-login-0 -c sshd -- \
  bash -c 'echo hello > /home/verify.txt && srun cat /home/verify.txt'

# 6. Syncer has no reconcile errors
kubectl logs -n slurm -l app.kubernetes.io/name=sunk-syncer --tail=50 | \
  grep -iE 'error|failed' || echo OK

# 7. SUNK pod scheduler is scheduling
kubectl get pods -n slurm -o wide | grep slurm-scheduler
```

If any check fails, stop and diagnose before moving on. Common failures map to entries in [troubleshooting.md](troubleshooting.md).

---

## Step 10b — SSH into the login node from your laptop

All verification above uses `kubectl exec`, which doesn't need a user
account or SSH key. Actual end-user access goes through the NLB. Wire it
up once, then give your users the hostname.

### 1. Get the NLB hostname

```bash
HOST=$(kubectl get svc -n tenant-slurm slurm-login \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "$HOST"
# abc123xyz.elb.us-east-1.amazonaws.com
```

If the hostname is empty, the AWS Load Balancer Controller hasn't finished
reconciling — wait 60-90s and re-run. If it's still empty, check Step 4
(`install-controllers.sh`) actually installed the controller.

### 2. Open TCP/22 on the cluster security group

The NLB forwards to the worker nodes' ENIs. You must allow inbound TCP/22
on the cluster SG from wherever you're SSHing from. For a single-user
setup, open to your public IP:

```bash
MYIP=$(curl -s ifconfig.me)
SG=$(aws eks describe-cluster --name sunk-eks \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG" \
  --protocol tcp --port 22 --cidr "$MYIP/32" 2>&1 | \
  grep -v InvalidPermission.Duplicate || true
```

For a shared cluster, whitelist a trusted CIDR or VPN exit range instead
of `0.0.0.0/0`.

### 3. Create a user and drop your public key

No user exists on the login pod by default. Run the
`bootstrap-sunk-local-user` skill to create one fast, or run
`configure-sunk-user-auth` to stand up OpenLDAP. For the one-user
fast path:

```bash
USERNAME="$USER"
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- bash -c "
  id $USERNAME >/dev/null 2>&1 || useradd -u 1001 -g 1001 -m -s /bin/bash $USERNAME || \
    (groupadd -g 1001 $USERNAME && useradd -u 1001 -g 1001 -m -s /bin/bash $USERNAME)
  install -d -o $USERNAME -g 1001 -m 0700 /home/$USERNAME/.ssh
  echo '$(cat ~/.ssh/id_ed25519.pub)' > /home/$USERNAME/.ssh/authorized_keys
  chown $USERNAME:1001 /home/$USERNAME/.ssh/authorized_keys
  chmod 0600 /home/$USERNAME/.ssh/authorized_keys
"
```

### 4. SSH in

```bash
ssh -i ~/.ssh/id_ed25519 "$USERNAME@$HOST"
# Inside:
sinfo
sbatch --wrap='hostname; sleep 5' --mem=100 -t 00:02:00
```

If you see `Permission denied (publickey)`, verify the key you passed with
`-i` matches what ended up in `/home/$USERNAME/.ssh/authorized_keys`:

```bash
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  cat /home/$USERNAME/.ssh/authorized_keys
```

For production multi-user provisioning (including key sync across pod
restarts), see `skills/universal/configure-sunk-user-auth/SKILL.md`.

---

## Step 11 — Cost monitoring

Run the estimator any time you edit the cluster config or values:

```bash
python3 infrastructure/eks/cost-estimate.py \
  --cluster-config infrastructure/eks/cluster-config.yaml \
  --slurm-values helm-values/eks/slurm-values.yaml
```

Exits non-zero if the max-running-all-nodegroups daily total exceeds `--budget` (default $50). See [cost-table.md](cost-table.md) for per-component spend and spot vs on-demand comparisons.

---

## Teardown

Removes everything `ManagedBy=sunk-anywhere`:

```bash
infrastructure/eks/destroy/destroy-all.sh \
  --cluster sunk-eks --region us-east-1 --profile your-profile
```

The script chains the per-component teardowns:

- `destroy/delete-slurm.sh` — uninstall SUNK + Slurm Helm releases, drain PVCs, delete `slurm` namespace.
- `destroy/delete-observability.sh` — uninstall kube-prometheus-stack, remove PodMonitors and DCGM exporter.
- `destroy/delete-storage.sh` — delete EFS filesystem + mount targets + security group; delete the NFS pod and backing PVC.
- `eksctl delete cluster` — remove the cluster, VPC, NAT gateway, IAM roles, and OIDC provider.

Always run `aws ec2 describe-volumes --filters Name=tag:ManagedBy,Values=sunk-anywhere` and `aws elbv2 describe-load-balancers` after teardown to confirm no stragglers.

---

## CPU-only fallback

Triggered when G/VT vCPU quota is denied. The default `helm-values/eks/slurm-values.yaml` already has `gpu-workers.enabled: false`:

- Skip Step 7 entirely.
- Skip verification check 4 (`srun --gres=gpu:1 nvidia-smi`).
- `sinfo` may show the `gpu` partition as DOWN with no nodes — expected in CPU-only mode.

---

## Troubleshooting

See [troubleshooting.md](troubleshooting.md) for symptom/cause/fix entries covering PVC Pending, NLB Pending, EFS mount errors, GPU AMI mismatches, cgroup privileges, IRSA failures, and more.

---

## See also

- [conventions.md](conventions.md) — naming contract all scripts and values obey
- [eks-adaptations.md](eks-adaptations.md) — diffs vs the GKE reference deployment
- [cost-table.md](cost-table.md) — budget profile, prod profile, spot savings
- [../universal/architecture.md](../universal/architecture.md) — SUNK component model
- [../universal/helm-values-reference.md](../universal/helm-values-reference.md) — annotated values
