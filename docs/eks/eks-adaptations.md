# EKS Adaptations

Focused diffs between the GKE reference deployment and SUNK on EKS. Every row lists the concern, what GKE does, what EKS does, and why they differ. Configuration contract: [conventions.md](conventions.md).

---

## Diff table

| Concern | GKE | EKS | Why it differs |
|---------|-----|-----|----------------|
| Load balancer for login service | GCE L4 internal load balancer via `service.beta.kubernetes.io/backend-config` | AWS NLB with `service.beta.kubernetes.io/aws-load-balancer-type: nlb`, `aws-load-balancer-nlb-target-type: ip`, `aws-load-balancer-scheme: internet-facing`, `aws-load-balancer-cross-zone-load-balancing-enabled: "true"` | AWS NLB is the closest L4 equivalent; the `ip` target type is required so the controller programs targets against pod IPs rather than node ports. |
| Metrics pipeline | Google Managed Prometheus (GMP) `PodMonitoring` CRD in the `gmp-public` namespace | `kube-prometheus-stack` with standard `PodMonitor` + `ServiceMonitor` CRDs in the `monitoring` namespace | EKS has no managed Prometheus offering equivalent to GMP. `kube-prometheus-stack` is the standard self-hosted path. |
| Shared filesystem (production) | GCP Filestore (managed NFS) | Amazon EFS (managed NFS) via the `efs.csi.aws.com` driver | Both are managed NFS but the provisioning story differs: Filestore mounts as a static PV; EFS uses access points via the CSI driver and requires a per-subnet mount target plus a security group allowing TCP/2049. |
| Shared filesystem (budget) | In-cluster NFS pod backed by a PD | In-cluster NFS pod backed by a gp3 EBS volume (`infrastructure/eks/storage/nfs-server-pod-eks.yaml`) | Same pattern, different underlying block storage. EKS default `cheap-nfs` StorageClass pairs with a single-replica NFS pod pinned to `cpu-control`. |
| Default StorageClass | `standard-rwo` (pd-balanced) set as default by GKE | `gp2` set as default by EKS; `create-cluster.sh` patches `gp3` to default and `gp2` to non-default | EKS ships with legacy `gp2` as default. gp3 is cheaper ($0.08/GB-mo vs $0.10) and higher baseline performance. |
| GPU AMI / drivers | GKE auto-provisions GPU drivers via `container.googleapis.com/accelerator` taints and the GKE device plugin | EKS GPU-optimized AMI (`AmazonLinux2-EKS-1.30-GPU`) ships with NVIDIA drivers, the container toolkit, and the `nvidia-device-plugin-daemonset` pre-installed | AWS does not auto-install GPU drivers on the standard AMI; the GPU AMI is required. Using the wrong AMI leaves `nvidia.com/gpu` unallocatable on the node. |
| System DaemonSets to tolerate the lock taint | `kube-proxy`, `gke-metadata-server`, `fluentbit-gke`, `gke-node-problem-detector` | `aws-node` (VPC CNI), `kube-proxy`, `ebs-csi-node`, `efs-csi-node`, `nvidia-device-plugin-daemonset` (on GPU nodes), `coredns` | Different cloud-owned DaemonSets. On EKS, `aws-node` being evicted is the most catastrophic failure — all pod networking breaks. |
| Primary node label key | `cloud.google.com/gke-nodepool` | `eks.amazonaws.com/nodegroup` | Each provider auto-applies its own label when nodes join. Values files and selectors must use the native key; no manual labeling required. |
| Control plane cost | Free on GKE Standard | $0.10/hr flat ($2.40/day, ~$73/month) on EKS | AWS charges for the managed control plane regardless of workload. This is the single biggest fixed cost on the budget profile. |
| cgroup mode | GKE defaults to cgroup v2, chart manages per-task cgroups | EKS AL2023 is cgroup v2, but the unified hierarchy is owned by host systemd; a pod-scoped `slurmd` cannot ask systemd for transient scopes and cannot write most controller files | `slurmd` on EKS must run privileged with `SYS_NICE`, `SYS_ADMIN`, `SYS_PTRACE`, `SYSLOG` AND `slurmConfig.cgroupConfig` has to set `IgnoreSystemd: yes` with `ConstrainCores/Devices/RAMSpace: no`. K8s pod limits become the only enforcement boundary. Full rationale: [../universal/security-model.md](../universal/security-model.md). |
| Pyxis/enroot enablement | GKE COS enforces AppArmor; chart's `localhost/enroot` profile is absent on COS, so pyxis is disabled on GKE | EKS AL2023 does not load custom AppArmor profiles for pods (kubelet admission rejects `localhost/enroot` outright — cell 3c). We drop the chart's `localhost/enroot` annotation and clear the chart's custom seccomp profile reference; slurmd then runs enroot under privileged + caps. `/enroot` is on the container rootfs for CPU nodes and a hostPath to instance-local NVMe for GPU nodes | AppArmor enforcement is a separate axis from privileged (cell 3c showed the admission gate fires regardless of `privileged: true`). On EKS we disable the AppArmor reference and clear the seccomp profile because the host has neither loaded. On GKE the right move is to keep pyxis off until we ship an AppArmor installer DaemonSet. See [../universal/security-model.md](../universal/security-model.md) for the threat model and `localhostProfile: null` render-discipline note. |
| Enroot seccomp DaemonSet | Required (`infrastructure/universal/seccomp-installer-daemonset.yaml`) if pyxis is ever enabled | NOT required. EKS relies on `compute.pyxis.podSecurityContext: null` + privileged slurmd. Skipping the DaemonSet removes a privileged hostPath-writing component from the cluster | The DaemonSet exists for providers that run pyxis unprivileged. EKS doesn't fit that path, so we avoid the extra moving part. |
| Ingress for web UIs | GKE Ingress with managed certs via Google-managed SSL certs | AWS ALB via the Load Balancer Controller; certs via ACM or cert-manager | Not used by base SUNK but relevant if exposing Grafana or the SUNK UI. |
| IAM workload identity | Google Workload Identity (KSA→GSA binding) | IRSA (`eks.amazonaws.com/role-arn` annotation on ServiceAccount) | EKS requires an explicit OIDC provider association (`eksctl utils associate-iam-oidc-provider`) and one IAM role per ServiceAccount. Handled by `infrastructure/eks/setup-irsa.sh`. |
| Instance quotas | GCE CPU quota per region | Standard vCPU quota (`L-1216C47A`) + separate G/VT on-demand (`L-DB2E81BA`) + spot (`L-3819A6DF`) + P on-demand (`L-7212CCBC`) | AWS splits quotas by instance family AND pricing model. Default accounts often have 0 G/VT quota; raise before attempting GPU. |
| Teardown blast radius | `gcloud container clusters delete` removes everything | `eksctl delete cluster` removes the cluster + VPC + NAT; EFS, ALB target groups, and CloudWatch logs persist unless explicitly deleted | `ManagedBy=sunk-anywhere` tag on every AWS resource lets `destroy-all.sh` find stragglers after the cluster itself is gone. |

---

## Helm values deltas

EKS-specific overrides live in `helm-values/eks/`. Key settings that override the base:

### `sunk-values.yaml`

- `cert-manager.enabled: false` — cert-manager is installed cluster-scoped by `install-controllers.sh`, not as a SUNK subchart. This avoids double-install conflicts.
- `moco.enabled: false` for the same reason.

### `slurm-values.yaml`

- `global.cks: false` — pulls images from public GHCR, not the CoreWeave private registry.
- StorageClass references: `controller.stateVolume.storageClassName: gp3`, `moco.mysqlCluster.persistence.storageClassName: gp3`, `login.sshKeyVolume.storageClassName: gp3`.
- Node selectors keyed on `eks.amazonaws.com/nodegroup`.
- Lock taint toleration on every component.
- `compute.securityContext.privileged: true` plus the capability list above (cgroup v2 systemd-owned-hierarchy workaround). See [../universal/security-model.md](../universal/security-model.md).
- `compute.pyxis.appArmorProfile: ""` + `compute.pyxis.podSecurityContext: null` — EKS-specific pyxis path that bypasses the seccomp installer DaemonSet.
- `compute.pyxis.plugstackOptions: [container_scope=job]` + `compute.pyxis.enrootConfig` — per-user cache/data under `/var/tmp`, temp under `/enroot`.
- `compute.s6.enroot-dirs` oneshot — creates enroot parent dirs with mode 1777 on pod start.
- `slurmConfig.cgroupConfig` with `IgnoreSystemd: yes` and `Constrain*: no` — Slurm does not enforce per-task limits; k8s pod limits are the boundary.
- `login.service` annotations that opt into the NLB (see table).

---

## See also

- [conventions.md](conventions.md) — naming contract
- [deployment-guide.md](deployment-guide.md) — step-by-step walkthrough
- [cost-table.md](cost-table.md) — spend estimates per profile
- [troubleshooting.md](troubleshooting.md) — EKS-specific issues keyed off these diffs
