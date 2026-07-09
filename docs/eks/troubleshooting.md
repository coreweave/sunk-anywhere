# EKS Troubleshooting

EKS-specific issues keyed off the diffs in [eks-adaptations.md](eks-adaptations.md). For cloud-agnostic Slurm issues, see [../universal/troubleshooting.md](../universal/troubleshooting.md).

---

## Symptom / cause / fix

| Symptom | Cause | Fix |
|---------|-------|-----|
| PVC stuck `Pending`, events say `no persistent volumes available for this claim and no storage class is set` | EKS ships `gp2` as default; `gp3` was never patched as the new default | Re-run `infrastructure/eks/create-cluster.sh` (idempotent on the StorageClass step) or manually apply `infrastructure/eks/storage/gp3-default.yaml` and `kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'` |
| Login service `LoadBalancer` stuck `Pending`, no NLB materializes | AWS Load Balancer Controller not Ready, or IRSA role missing permissions | `kubectl get deploy -n kube-system aws-load-balancer-controller` should be Available. If missing, re-run `install-controllers.sh`. If Available but still Pending, check `kubectl logs -n kube-system deploy/aws-load-balancer-controller` for IRSA errors; re-run `setup-irsa.sh` |
| Compute pod events show `mount.nfs4: access denied by server` on EFS | EFS security group missing inbound TCP/2049 from the cluster node SG | `aws ec2 describe-security-groups --filters Name=group-name,Values=sunk-efs-<CLUSTER_NAME>` and confirm the inbound rule exists. If absent, `setup-efs.sh` will re-add it on re-run |
| Compute pod events show `mount.nfs4: connection refused` on EFS | Mount target missing in the pod's AZ | `aws efs describe-mount-targets --file-system-id <FS_ID>` should list one mount target per subnet. If any subnet is missing, re-run `setup-efs.sh` |
| GPU node joins but `kubectl describe node <gpu-node>` shows no `nvidia.com/gpu` capacity | Using the standard EKS AMI instead of the GPU-optimized AMI | Delete the nodegroup and recreate with `amiFamily: AmazonLinux2` + `instanceType: g5.xlarge` so eksctl auto-selects the GPU AMI, or explicitly set `image: ami-XXX` to the `AmazonLinux2-EKS-1.30-GPU` AMI ID |
| Syncer and scheduler pods show `CreateContainerConfigError` right after `helm install` | Normal state for 2-3 minutes while `slurm-secret-job` generates JWT and auth secrets | Wait. `kubectl get job -n slurm slurm-secret-job -w` until Completed; do NOT delete or restart the failing pods — that resets the timer |
| `kubectl exec` into any compute pod fails with `unable to upgrade connection` after a Slurm job runs | Lock taint evicted `kube-proxy` (and often `aws-node`) from the compute node | Run the skill at `skills/eks/patch-eks-system-tolerations` (or directly `bash infrastructure/eks/patch-eks-tolerations.sh`). Re-run after every EKS upgrade; managed add-ons are re-deployed during upgrade and lose custom tolerations |
| `helm install sunk` fails with `no matches for kind "Certificate"` or MOCO CRD not found | cert-manager webhook not ready yet | `kubectl wait --for=condition=Available -n cert-manager deployment/cert-manager-webhook --timeout=5m`, then retry `helm install`. `install-controllers.sh` waits on this but a manual install path can skip it |
| Compute pod crashes with `permission denied` writing to `/sys/fs/cgroup/...` | Pod-scoped `slurmd` trying to enforce cgroup constraints against a hierarchy owned by host systemd | Ensure `helm-values/eks/slurm-values.yaml` has `compute.securityContext.privileged: true` with capabilities `SYS_NICE`, `SYS_ADMIN`, `SYS_PTRACE`, `SYSLOG` AND `slurmConfig.cgroupConfig` has `IgnoreSystemd: yes` with `ConstrainCores/Devices/RAMSpace: no`. Re-run `helm upgrade slurm`. Full reasoning: [../universal/security-model.md](../universal/security-model.md) |
| `srun --container-image=...` fails with `ERROR: failed to mount /proc` or similar enroot mount errors | Pyxis config missing the EKS overrides; chart is trying to load a non-existent seccomp or AppArmor profile | Confirm `helm-values/eks/slurm-values.yaml` has `compute.pyxis.appArmorProfile: ""` and `compute.pyxis.podSecurityContext: null`. Do NOT apply `infrastructure/universal/seccomp-installer-daemonset.yaml` on EKS — it's only for GKE. See [../universal/security-model.md](../universal/security-model.md) for why |
| `srun --container-image=...` fails with `No such file or directory: /enroot` or `/var/tmp/enroot-cache` | `compute.s6.enroot-dirs` oneshot missing or the pod predates it | Check `helm-values/eks/slurm-values.yaml` has the `compute.s6.enroot-dirs` block, run `helm upgrade slurm`, and restart any pre-existing compute pods (`kubectl delete pod -n tenant-slurm -l app.kubernetes.io/component=compute`). The oneshot runs on pod start, not on helm upgrade |
| Job requests `--mem=1G` but uses all RAM on the node | Expected. `slurmConfig.cgroupConfig.ConstrainRAMSpace: no` disables per-task memory enforcement; k8s pod limits are the boundary | If per-task enforcement matters, run one slurmd per node (dedicated nodegroup) or set pod `resources.limits.memory` to a smaller value. See the "cgroup v2 on EKS" section of [../universal/security-model.md](../universal/security-model.md) for why we can't turn this on inside a pod |
| IRSA-annotated pod logs show `WebIdentityErr: An error occurred (InvalidIdentityToken)` | OIDC provider not associated with the cluster | `aws iam list-open-id-connect-providers` should contain the cluster's issuer. If absent, re-run `setup-irsa.sh` (the step is idempotent and just associates OIDC) |
| EFS PVC stuck `Pending`, events from the `efs-csi-controller` mention `AccessDenied` creating an access point | `efs-csi-controller-sa` missing or IRSA role not attached | `kubectl get sa -n kube-system efs-csi-controller-sa -o yaml` should have the `eks.amazonaws.com/role-arn` annotation. If missing, re-run `setup-irsa.sh` |
| `slurmd` CrashLoopBackOff on EKS AL2023 with `unable to create cgroup '/sys/fs/cgroup/system' : Read-only file system` | `compute.securityContext.privileged: false` on a stock EKS AL2023 nodegroup. AL2023 kubelet runs pods with `cgroup-namespace=host`, so `/sys/fs/cgroup` is read-only inside the container; slurmd writes that path unconditionally at startup. Adding capabilities does not help — the mount is read-only by namespace, not by capability | Keep `privileged: true` on EKS (chart-default for the EKS overlay). The capabilities-only path requires a kubelet config patch (`--cgroup-namespace-mode=pod`) on the managed nodegroup, tracked as a follow-up; see [../universal/security-model.md](../universal/security-model.md) for the full evidence (cells 3a-3g) |
| Pod stuck `Pending` with kubelet event `Cannot enforce AppArmor: AppArmor is not enabled on the host` | `compute.pyxis.appArmorProfile: localhost/...` set on a node where AppArmor is not loaded. EKS AL2023 does not ship AppArmor at all; the admission gate fires before the runtime, regardless of `privileged: true` | Either deploy an AppArmor loader DaemonSet that vendors `infrastructure/universal/apparmor-profiles/enroot.profile` to `/etc/apparmor.d/` and reloads on each node before the slurmd pod schedules, OR unset `appArmorProfile` (chart-default for the EKS overlay sets it to `""`). See [../universal/security-model.md](../universal/security-model.md) |

---

## Diagnostic commands cheat sheet

```bash
# All controllers healthy?
kubectl get deploy -n kube-system | grep -E 'ebs-csi-controller|efs-csi-controller|aws-load-balancer-controller'
kubectl get deploy -n cert-manager
kubectl get deploy -n moco-system

# IRSA service accounts have role ARNs?
kubectl get sa -n kube-system ebs-csi-controller-sa efs-csi-controller-sa aws-load-balancer-controller \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}{end}'

# Lock taint present on compute nodes?
kubectl get nodes -l eks.amazonaws.com/nodegroup=cpu-workers \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{.spec.taints}{"\n\n"}{end}'

# System pods evicted from compute nodes?
kubectl get pods --all-namespaces --field-selector=status.phase=Failed | grep Evict

# Pod networking from a compute node
kubectl exec -n slurm slurm-login-0 -c sshd -- nslookup kubernetes.default

# EFS mount targets available in every cluster AZ?
FS_ID=$(cat /tmp/sunk-efs-id 2>/dev/null)
[ -n "$FS_ID" ] && aws efs describe-mount-targets --file-system-id "$FS_ID" \
  --query 'MountTargets[].{AZ:AvailabilityZoneName,State:LifeCycleState,Subnet:SubnetId}'

# NLB backend targets healthy?
aws elbv2 describe-target-health \
  --target-group-arn "$(aws elbv2 describe-target-groups --query 'TargetGroups[?contains(TargetGroupName, `sunk`) == `true`].TargetGroupArn' --output text)"

# Unused AWS resources after teardown?
aws ec2 describe-volumes --filters Name=tag:ManagedBy,Values=sunk-anywhere \
  --query 'Volumes[].{ID:VolumeId,State:State,Size:Size}'
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?contains(LoadBalancerName, `sunk`) == `true`].LoadBalancerArn'
```

---

## See also

- [deployment-guide.md](deployment-guide.md) — step-by-step, each step lists its success criteria
- [eks-adaptations.md](eks-adaptations.md) — the diffs that drive most of these issues
- `skills/eks/patch-eks-system-tolerations/SKILL.md` — authoritative lock-taint patching
- [../universal/troubleshooting.md](../universal/troubleshooting.md) — cloud-agnostic Slurm issues
