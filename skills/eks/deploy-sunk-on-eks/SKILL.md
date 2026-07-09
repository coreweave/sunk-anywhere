---
name: deploy-sunk-on-eks
description: >
  Deploy SUNK (Slurm on Kubernetes) on Amazon Elastic Kubernetes Service from
  scratch, following the sub-$50/day budget profile defined in
  docs/eks/conventions.md. Covers quota check, cluster bootstrap, IRSA, cluster
  controllers, shared storage, SUNK + Slurm Helm install, GPU nodegroup,
  in-cluster monitoring (Grafana), CloudWatch observability + dashboards, GCM
  GPU health checks, and the verification loop. Everything is default-on; each
  step has an explicit `--skip-*` opt-out for cost-sensitive deployments. Use
  when asked to "deploy SUNK on EKS", "set up Slurm on AWS", "create a SUNK
  cluster on Amazon", "install SUNK on EKS", or "deploy Slurm on Kubernetes
  on AWS".
---

# Deploy SUNK on EKS

## Optional features — confirm each with the user before any cluster work

**Instruction to the agent (any harness — Claude Code, Codex, Cursor, plain
chat agent):** Read this list to the user and capture a yes/no per item
**before** running any deployment commands. If you have `AskUserQuestion`
(Claude Code), prefer it; otherwise ask in plain chat and parse the
response. Defaults are the recommended demo posture — the user opts out
explicitly.

1. **GPU compute** — 1× g6.xlarge L4 spot nodegroup (~$3–8/day). Default: ON. Opt out: `--skip-gpu`.
2. **CloudWatch observability** — addon + 2 dashboards + Prometheus scrape of slurm-syncer/DCGM (~$5–15/day + ~$30/mo). Default: ON. Opt out: `--skip-cloudwatch`.
3. **In-cluster Grafana + GCM GPU health checks** — kube-prometheus-stack and Node Problem Detector with 6 GPU checks. Default: ON. Opt out: `--skip-monitoring`, `--skip-gcm`.
4. **Default local user + SSH key** — caller's SSH key, slurmdbd association so `sbatch` works immediately. Default: ON. Opt out: `--skip-user-provisioning`.
5. **Shared `/home` backend** — pick one: in-cluster NFS (~$8/mo, single-AZ, demo) **or** EFS (~$30/mo, multi-AZ, production).
6. **Layer-on later (opt-in only)** — LDAP multi-user via `configure-sunk-user-auth` (OpenLDAP) or `configure-sunk-authentik-sssd` (authentik+sssd); SkyPilot via `connect-skypilot-to-sunk`.

## Default contents (everything; opt out per flag)

`deploy SUNK on EKS` produces, by default:

| Component | Default | Opt-out |
|---|---|---|
| EKS cluster + cpu-control + cpu-workers | always | n/a |
| OIDC + IRSA roles (EBS / EFS / ALB / cwagent) | always | n/a |
| Cluster controllers (cert-manager, ALB, EBS CSI, EFS CSI, MOCO) | always | n/a |
| Shared `/home` (in-cluster NFS) | always | EFS alternative |
| SUNK + Slurm Helm releases | always | n/a |
| **GPU nodegroup** (1× g6.xlarge L4 spot) | **on** | `--skip-gpu` |
| **In-cluster monitoring** (kube-prometheus-stack + Grafana) | **on** | `--skip-monitoring` |
| **CloudWatch observability** (addon + cluster + jobs dashboards) | **on** | `--skip-cloudwatch` |
| **GCM GPU health checks** | **on** when GPU enabled | `--skip-gcm` |

The defaults are the recommended demo posture; cost-sensitive customers
opt out individually. The skill's question-flow (next section) presents
each opt-out at the right point in the sequence.



Everything in this skill refers back to `docs/eks/conventions.md` (node labels,
nodegroup names, StorageClasses, budget profile, lock taint, AWS tags, region,
versions). Do not invent alternate naming. If a constraint is missing from
conventions.md, propose it as a PR against that doc before using it here.

## For orchestrating agents

If you are an LLM driving this skill on behalf of a user, use Claude Code's
`AskUserQuestion` tool for the decision points below. Do **not** ask
free-text questions or accept pasted answers — the dropdown/arrow-select UX
is what the user expects and makes the run auditable.

Ask these before the referenced step, not after. The default for every
optional component is **include it**; the customer opts out explicitly.

| When | Question | Options |
|---|---|---|
| Before Step 1 | Include GPU nodegroup? | `Yes, gpu-workers (L4 spot, ~$3-8/day) — default`; `No, CPU-only (sub-$15/day)` |
| Before Step 1, **only if** quota check suggested an alternative | Region mismatch — override target region? | one option per region the quota check returned with headroom, plus `Cancel and request a quota increase` |
| Before Step 4 | Shared `/home` storage backend? | `In-cluster NFS (~$8/mo, single-AZ, SPOF — demo/dev)`; `EFS (~$30/mo, multi-AZ, durable — production)` |
| Before Step 6, **only if** GPU was enabled in question 1 | Confirm GPU instance family? | `g6.xlarge (L4, default)`; `g5.xlarge (A10G, legacy)`; `g5.2xlarge (A10G + more CPU/RAM)` |
| Before Step 8 | CloudWatch observability (addon + dashboards)? | `Yes (~$5-15/day, default)`; `No, in-cluster Grafana only` |
| Before Step 9, **only if** GPU was enabled | GCM GPU health checks (Node Problem Detector)? | `Yes, install (default)`; `No, skip` |

Rules:
- Show the projected-cost table (`create-cluster.sh` prints it automatically
  before confirmation) in the question description so the user sees $/day
  before choosing.
- Never ask the user to pick between two code blocks by pasting one — the
  skill uses `AskUserQuestion` values to branch internally.
- If the quota check emits a cross-region snapshot, use that list verbatim
  as the region-override option set (never invent regions).

## Prerequisites

| Tool | Purpose |
|------|---------|
| `aws` CLI v2 | authenticated to the target account; region set |
| `eksctl` | cluster creation (`brew install eksctl`) |
| `helm` 3 | chart install (repo added by the Step 0 preflight; no manual `helm repo add` needed) |
| `kubectl` | cluster access |
| `jq` | pipeline glue in the scripts |

AWS quotas required before any `create-cluster.sh` run:

- **Standard vCPU (L-1216C47A)** ≥ 8 for the control plane.
- **G and VT On-Demand vCPU (L-DB2E81BA)** ≥ 8 **or** **G and VT Spot vCPU
  (L-3819A6DF)** ≥ 8 (only when `compute.nodes.gpu-workers.enabled: true`).

`create-cluster.sh` checks these automatically. If the target region is
short, it prints a cross-region snapshot (us-east-1, us-east-2, us-west-2,
eu-west-1) and suggests the first region with headroom — for example, the
validation run in 2026-04 had zero GPU quota in us-east-1 and 8 Spot vCPU
in us-east-2. Either re-run with `--region <alt>` or request an increase
and wait.

If you want to skip the GPU path entirely, set
`compute.nodes.gpu-workers.enabled: false` in `helm-values/eks/slurm-values.yaml`;
the GPU quota check is skipped in that case and step 6 is a no-op.

## Deployment steps

Each step below is a thin wrapper over a script or a sibling skill. The scripts
own the real logic; the skill orchestrates order and gates.

### 0. Preflight

Confirm CLIs are on PATH and register the `coreweave` Helm repo so step 5
finds `coreweave/sunk` and `coreweave/slurm`. Idempotent; safe to re-run.

```bash
bash infrastructure/eks/preflight.sh
```

`create-cluster.sh` re-invokes this internally, so skipping it is safe — it
just means the first agent error surfaces from deeper in the stack.

### 1. Create the cluster

`infrastructure/eks/create-cluster.sh` calls `eksctl` with the
three managed nodegroups named per `docs/eks/conventions.md`
(`cpu-control`, `cpu-workers`, `gpu-workers`), patches the `gp3` StorageClass
to default, marks `gp2` non-default, applies the AWS tags
(`Environment`, `Service=sunk`, `ManagedBy=sunk-anywhere`, `Owner=auto-cleanup`),
and writes the kubeconfig.

```bash
infrastructure/eks/create-cluster.sh --region us-east-1 --environment dev
kubectl get nodes   # expect 2 Ready m5.large nodes labeled eks.amazonaws.com/nodegroup=cpu-control
```

### 2. Set up OIDC + IRSA

`infrastructure/eks/setup-irsa.sh` enables the cluster OIDC
provider and creates the IAM service accounts for the EBS CSI driver, the
EFS CSI driver (if shared `/home` via EFS is chosen), and the AWS Load Balancer
Controller.

```bash
infrastructure/eks/setup-irsa.sh
```

### 3. Install cluster controllers

`infrastructure/eks/install-controllers.sh` installs
`cert-manager` (cluster-scoped, **not** via the SUNK subchart — the EKS
`sunk-values.yaml` sets `cert-manager.enabled: false` for this reason), the
AWS Load Balancer Controller, and the EBS CSI driver (if not auto-installed by
eksctl).

```bash
infrastructure/eks/install-controllers.sh
```

### 4. Install shared storage

SUNK needs a `ReadWriteMany` `slurm-home` PVC in the `tenant-slurm`
namespace. Pick ONE path:

```bash
# Budget path: in-cluster NFS pod backed by gp3 EBS (~$8/mo, single-AZ, one-pod SPOF).
kubectl create namespace tenant-slurm --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f infrastructure/eks/storage/nfs-server-pod-eks.yaml
```

Or, for production:

```bash
# Production path: managed EFS (~$30/mo, multi-AZ, durable).
bash infrastructure/eks/storage/setup-efs.sh \
  --cluster sunk-eks --region us-east-1 --profile your-aws-profile
sed "s/__EFS_FS_ID__/$(cat /tmp/sunk-efs-id)/g" \
  infrastructure/eks/storage/efs-pv-home.yaml.template | kubectl apply -f -
kubectl apply -f infrastructure/eks/storage/efs-storageclass.yaml.template
```

Both paths land the same `slurm-home` PVC name so the rest of the deploy
is identical. See `infrastructure/eks/storage/README.md` for the full
breakdown.

### 5. Install SUNK + Slurm Helm charts

```bash
kubectl create namespace sunk
kubectl create namespace tenant-slurm
kubectl create namespace moco-system
kubectl create namespace cert-manager
kubectl create namespace monitoring

# NOTE: On EKS we do NOT apply the universal seccomp-installer DaemonSet.
# helm-values/eks/slurm-values.yaml overrides compute.pyxis.podSecurityContext
# and appArmorProfile so pyxis runs unconstrained under the already-privileged
# slurmd container. Full reasoning: docs/universal/security-model.md.
# (GKE still requires the DaemonSet; the universal manifest stays for that.)

# Preflight posture printout — make the security choice visible before install.
echo "About to install SUNK with security posture: privileged-default (EKS AL2023)."
echo "  slurmd runs with privileged: true + SYS_NICE/SYS_ADMIN/SYS_PTRACE/SYSLOG."
echo "  Forced by AL2023 kubelet cgroup-namespace=host (cells 3a-3g evidence)."
echo "  See docs/universal/security-model.md for the per-cloud posture matrix."

helm install sunk coreweave/sunk -n sunk \
  -f helm-values/base/sunk-values.yaml \
  -f helm-values/eks/sunk-values.yaml
helm install slurm coreweave/slurm -n tenant-slurm \
  -f helm-values/base/slurm-values.yaml \
  -f helm-values/eks/slurm-values.yaml
```

**Expected transient state:** the syncer and scheduler pods will show
`CreateContainerConfigError` for 2-3 minutes while `slurm-secret-job`
generates the JWT / auth secrets. This is normal. **Do not delete or restart
pods during this window** — it only extends the outage. `kubectl get pod -n tenant-slurm -w`
should show them transition to `Running` once the secret materializes.

**Image-pull timing (normal):** On freshly created `m5.large` nodes,
first-time pulls of `ghcr.io/coreweave/slurm-containers/*` images
(~1 GiB each) take ~1 minute per pod. With 5-7 pods per node that
compounds to 3-5 minutes of `Init:ContainerCreating` on the first
deploy. Do not retry or delete pods during this window; subsequent
deploys reuse the cached layers and start in under a minute.

### 6. Add GPU nodes (default-on, skip with `--skip-gpu`)

Bring up the `gpu-workers` managed nodegroup (default: 1× g6.xlarge L4 spot,
0..1 scale, AL2023, gp3 200 GiB). The slurm chart values already have
`compute.nodes.gpu-workers.enabled: true` so the slurmd pod will schedule
onto the new node automatically.

```bash
infrastructure/eks/add-gpu-nodegroup.sh --region us-east-1 --profile your-aws-profile
```

For the deeper walkthrough (A10G alternatives, production p4de/p5 profiles,
NCCL/EFA notes), see `skills/eks/add-gpu-nodes-to-eks/SKILL.md`. To skip the
GPU step entirely, pass `--skip-gpu` to the orchestrator and ensure
`compute.nodes.gpu-workers.enabled: false` in
`helm-values/eks/slurm-values.yaml`. Keep spot + scale-to-zero on for the
default profile; leaving a GPU node running 24/7 still pushes hard on the
$50/day ceiling.

### 6.5. Patch gres.conf + system tolerations (mandatory when GPU enabled)

The slurm-controller image on EKS is built without nvml, so the chart's
default `gres.conf: AutoDetect=nvml` causes `slurmd` to drop the explicit
File= directive (`Ignoring file-less GPU gpu:l4 from final GRES list`)
and the GPU node lands in `INVALID_REG`. `sunk-post-upgrade.sh` rewrites
gres.conf with `AutoDetect=off` + `NodeName=... Type=l4 File=/dev/nvidia0`,
restarts the GPU pod, resumes the node, and re-applies system DaemonSet
tolerations for the SUNK lock taint. **Run it after every helm install
and every helm upgrade of the slurm chart.**

```bash
bash infrastructure/eks/sunk-post-upgrade.sh
```

If you used `--skip-gpu`, pass `--skip-gres` to skip the GPU half:

```bash
bash infrastructure/eks/sunk-post-upgrade.sh --skip-gres
```

### 7. In-cluster monitoring (default-on, skip with `--skip-monitoring`)

Run this right after SUNK + Slurm are healthy. The customer does not
pass anything beyond what they already provided at cluster creation
(the `AWS_PROFILE` / `AWS_REGION` already point at the cluster):

```bash
bash infrastructure/eks/install-monitoring.sh
```

What it does, idempotently:
- Adds the `prometheus-community` helm repo.
- Creates the `monitoring` namespace and a dashboard ConfigMap from
  `infrastructure/eks/dashboards/` labeled `grafana_dashboard=1`.
- Installs `kube-prometheus-stack` with
  `infrastructure/eks/observability/kube-prometheus-stack-values.yaml`
  (retention, storage, tolerations, nodeSelector tuned for budget).
- Applies the syncer PodMonitor and DCGM exporter.

The Grafana admin password prints at the end. Port-forward with
`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`
and the SUNK dashboards show up in the `SUNK` folder without any
manual import.

### 8. CloudWatch observability (default-on, skip with `--skip-cloudwatch`)

Install the AWS-managed `amazon-cloudwatch-observability` add-on (cwagent
DaemonSet + fluent-bit + DCGM exporter) and push the SUNK CloudWatch
dashboards. ContainerInsights metrics flow under the `ContainerInsights`
namespace; dashboards live at
`infrastructure/eks/dashboards/cloudwatch/*.json` and reference the
`__CLUSTER_NAME__` token so they retarget cleanly when reused.

```bash
bash infrastructure/eks/install-cloudwatch.sh --region us-east-1 --profile your-aws-profile
```

What it does, idempotently:
- Creates IRSA role `AmazonEKS_CloudWatchAgent_Role-<cluster>` with
  `CloudWatchAgentServerPolicy`.
- Installs the add-on (with `enhanced_container_insights: true`).
- Patches the `sunk.coreweave.com/lock=true:NoExecute` toleration onto the
  agent + fluent-bit + dcgm DaemonSets.
- Pushes `<cluster>-cluster-cloudwatch` and `<cluster>-jobs-cloudwatch`
  dashboards (cluster-name templated in).
- Wires a Prometheus scrape of `slurm-syncer` (tenant-slurm/8080) and
  `dcgm-exporter` (monitoring/9400) into the CWAgent CR. The
  `metric_declaration` whitelist mirrors what internal CoreWeave Grafana
  dashboards actually plot — ~70 metrics × ~100
  streams under `ContainerInsights/Prometheus`. Per-job metrics
  (`slurm_job_*`, singular) are deliberately excluded to avoid one-stream-per-
  job-id cardinality blowup; use Grafana for per-job introspection. Files:
  `observability/cloudwatch-prometheus-config.yaml` and
  `observability/cloudwatch-prometheus-cr-patch.sh`.

Cost: ~$5-15/day on a 6-node cluster from ContainerInsights metric ingest,
plus ~$30/month for the Prometheus scrape (~100 streams × $0.30/month).
Without the whitelist this would balloon to ~$120/month. Skip this step on
cost-sensitive deployments — Grafana from step 7 already
covers the same panels for free.

### 9. GCM GPU health checks (default-on when GPU enabled, skip with `--skip-gcm`)

GCM (from `facebookresearch/gcm`) runs Node Problem Detector with 6 periodic
GPU health checks (XID errors, ECC, NVLink status, DCGM diag, zombie procs,
GPU disconnect) and reports them as both k8s node conditions and Prometheus
metrics — complementary to DCGM exporter's utilization metrics.

```bash
helm install gcm oci://ghcr.io/facebookresearch/charts/gcm \
  --namespace kube-system \
  -f helm-values/eks/gcm-values.yaml
```

Verify once GPU nodes are labelled:

```bash
bash examples/06-validate-gcm-health.sh
# Expected: one block per GPU node with 6 Gcm* checks, all PASS.
```

The example script auto-detects EKS vs GKE by node label; no flag needed.
Skip with `--skip-gcm` if you only need DCGM utilization metrics.

## Verification loop (do NOT proceed until ALL 7 checks pass)

These are the gating checks before declaring the cluster healthy. Run them in
order; if any fails, stop and diagnose before moving on.

```bash
# 1. sinfo shows all expected partitions. Default profile lands with
#    ONE cpu-workers node idle (cluster-config cpu-workers.desiredCapacity=1
#    + chart replicas=1). If you want more, scale both sides in lockstep:
#      eksctl scale nodegroup --cluster=sunk-eks --name=cpu-workers --nodes=2 \
#        --nodes-max=3 --profile your-aws-profile
#      helm upgrade slurm coreweave/slurm --reuse-values \
#        --set compute.nodes.cpu-workers.replicas=2 -n tenant-slurm
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- sinfo

# 2. Minimal job completes on the CPU worker (default profile already has
#    one running; no "bring replicas up briefly" step needed).
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --mem=100 hostname

# 3. Multi-node job (requires replicas>=2; see step 1 to scale up).
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun -N2 --mem=100 hostname

# 4. GPU job runs (SKIP if CPU-only fallback is in effect).
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- srun --gres=gpu:1 nvidia-smi

# 5. Shared /home round-trip: write from login, read from a compute-srun shell.
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- \
  bash -c 'echo hello > /home/verify.txt && srun cat /home/verify.txt'

# 6. Syncer is publishing metrics and has no reconcile errors.
kubectl logs -n tenant-slurm -l app.kubernetes.io/name=sunk-syncer --tail=50 | grep -iE 'error|failed' || echo OK

# 7. The SUNK pod scheduler is scheduling at least one pod.
kubectl get pods -n tenant-slurm -o wide | grep slurm-scheduler
```

## CPU-only fallback

Triggered when G/VT vCPU quota is denied or the increase is slow. The default
`helm-values/eks/slurm-values.yaml` already has `gpu-workers.enabled: false`,
so no values changes are required. Concretely:

- Skip step 6 entirely.
- Skip verification check 4 (GPU srun).
- `sinfo` output should still show `gpu` partition as `DOWN` / no nodes — that
  is expected in CPU-only mode and does not block any of the other checks.

## Next steps

Once the 7 checks pass:

| Capability | Skill |
|------------|-------|
| Helm upgrades | `skills/universal/upgrade-sunk` |
| User authentication (LDAP/SSSD) | `skills/universal/configure-sunk-user-auth` |
| GPU monitoring (DCGM + Grafana) | `skills/universal/setup-sunk-gpu-monitoring` |
| GPU health checks (GCM) | Step 8 above, or `docs/universal/monitoring-guide.md` |
| SkyPilot integration | `skills/universal/connect-skypilot-to-sunk` |
| Patch EKS system DaemonSets for the lock taint | `skills/eks/patch-eks-system-tolerations` |
| Add more GPU capacity | `skills/eks/add-gpu-nodes-to-eks` |
| Tear down everything | `infrastructure/eks/destroy/destroy-all.sh` (filters on `ManagedBy=sunk-anywhere` plus name-pattern sweep for CloudWatch dashboards and log groups, which AWS does not let us tag) |
