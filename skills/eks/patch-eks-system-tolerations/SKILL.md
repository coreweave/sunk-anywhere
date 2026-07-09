---
name: patch-eks-system-tolerations
description: >
  Patch EKS system DaemonSets and infrastructure pods to tolerate the SUNK lock
  taint (sunk.coreweave.com/lock=true:NoExecute). Run after initial SUNK deployment,
  after EKS upgrades, or when networking/storage breaks on compute nodes.
  Use when asked to "patch EKS tolerations", "fix evicted system pods on EKS",
  "fix aws-node on SUNK EKS", "fix kube-proxy on SUNK", or
  "re-run toleration patches after EKS upgrade".
---

# Patch EKS System Tolerations for SUNK Lock Taint

Patch EKS system DaemonSets and infrastructure pods so they survive the non-configurable `sunk.coreweave.com/lock=true:NoExecute` taint that the SUNK operator applies to every node running compute pods.

## Background

The SUNK operator hardcodes a `NoExecute` taint on any Kubernetes node running compute (NodeSet) pods:

```
sunk.coreweave.com/lock=true:NoExecute
```

On EKS with shared node groups, this taint evicts all pods that do not tolerate it, including critical AWS system components.

### What breaks when this taint hits

| Component | Namespace | Impact |
|-----------|-----------|--------|
| aws-node (VPC CNI) | kube-system | ALL pod networking breaks. New pods cannot get IPs. This is the most critical failure on EKS. |
| kube-proxy | kube-system | Service routing and ClusterIP access breaks |
| ebs-csi-node | kube-system | EBS volume attachment for new pods breaks |
| cert-manager | cert-manager | Certificate renewal and issuance stops, breaking MOCO |
| moco-controller | moco-system | MySQL operator cannot manage databases |

## When to Run This

1. **After initial SUNK deployment** -- once compute nodes join and get tainted.
2. **After EKS cluster upgrades** -- managed add-ons may be re-deployed, stripping custom tolerations.
3. **When pod networking breaks on compute nodes** -- pods cannot reach Services or the internet.
4. **When EBS volumes fail to attach** -- new pods stuck in `ContainerCreating`.

## The Patch Script

Create `infrastructure/eks/patch-eks-tolerations.sh`:

```bash
#!/bin/bash
set -euo pipefail

LOCK_TOLERATION='{"key":"sunk.coreweave.com/lock","operator":"Exists","effect":"NoExecute"}'
PATCH="[{\"op\":\"add\",\"path\":\"/spec/template/spec/tolerations/-\",\"value\":$LOCK_TOLERATION}]"

patched=0
skipped=0
failed=0

patch_resource() {
  local kind="$1"
  local name="$2"
  local namespace="$3"

  if ! kubectl get "$kind" "$name" -n "$namespace" &>/dev/null; then
    echo "  $kind/$name -n $namespace: not found, skipping"
    ((skipped++))
    return
  fi

  existing=$(kubectl get "$kind" "$name" -n "$namespace" \
    -o jsonpath='{.spec.template.spec.tolerations[?(@.key=="sunk.coreweave.com/lock")].key}' 2>/dev/null)
  if [ -n "$existing" ]; then
    echo "  $kind/$name -n $namespace: already has toleration, skipping"
    ((skipped++))
    return
  fi

  if kubectl patch "$kind" "$name" -n "$namespace" --type=json -p "$PATCH" &>/dev/null; then
    echo "  $kind/$name -n $namespace: patched"
    ((patched++))
  else
    echo "  $kind/$name -n $namespace: FAILED to patch"
    ((failed++))
  fi
}

echo "=== Patching EKS system pods for SUNK lock taint toleration ==="
echo ""

# --- kube-system DaemonSets (EKS-specific) ---
echo "kube-system DaemonSets:"
for ds in aws-node kube-proxy ebs-csi-node; do
  patch_resource daemonset "$ds" kube-system
done
echo ""

# --- kube-system Deployments ---
echo "kube-system Deployments:"
for deploy in coredns; do
  patch_resource deployment "$deploy" kube-system
done
echo ""

# --- cert-manager ---
echo "cert-manager namespace:"
for deploy in cert-manager cert-manager-cainjector cert-manager-webhook; do
  patch_resource deployment "$deploy" cert-manager
done
echo ""

# --- moco-system ---
echo "moco-system namespace:"
patch_resource deployment moco-controller moco-system
echo ""

# --- monitoring (if deployed) ---
if kubectl get namespace monitoring &>/dev/null; then
  echo "monitoring namespace:"
  patch_resource daemonset dcgm-exporter monitoring
  echo ""
else
  echo "monitoring namespace: does not exist, skipping"
  echo ""
fi

echo "=== Summary ==="
echo "  Patched: $patched"
echo "  Skipped: $skipped"
echo "  Failed:  $failed"

if [ "$failed" -gt 0 ]; then
  echo ""
  echo "WARNING: Some patches failed. Check the output above."
  exit 1
fi
```

Run it:

```bash
chmod +x infrastructure/eks/patch-eks-tolerations.sh
bash infrastructure/eks/patch-eks-tolerations.sh
```

## DaemonSets and Deployments to Patch

### kube-system namespace

| Resource | Kind | Notes |
|----------|------|-------|
| aws-node | DaemonSet | VPC CNI plugin. Most critical on EKS. |
| kube-proxy | DaemonSet | Service routing. |
| ebs-csi-node | DaemonSet | EBS volume attachment. |
| coredns | Deployment | DNS resolution (EKS uses CoreDNS, not kube-dns). |

### cert-manager namespace

| Resource | Kind |
|----------|------|
| cert-manager | Deployment |
| cert-manager-cainjector | Deployment |
| cert-manager-webhook | Deployment |

### moco-system namespace

| Resource | Kind |
|----------|------|
| moco-controller | Deployment |

## Verification

```bash
# 1. Check aws-node is running on all nodes (including compute nodes)
kubectl get pods -n kube-system -l k8s-app=aws-node -o wide

# 2. Check kube-proxy is running
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide

# 3. Test pod networking from a compute node pod
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- nslookup kubernetes.default

# 4. Verify kubectl exec works
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- echo "exec works"

# 5. Check for evicted pods
kubectl get pods --all-namespaces --field-selector=status.phase=Failed | grep Evict
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pods stuck in `ContainerCreating` with no IP | aws-node evicted from compute nodes | Patch aws-node DaemonSet and wait for pods to restart |
| Service ClusterIP not reachable | kube-proxy evicted | Patch kube-proxy DaemonSet |
| New PVCs stuck in `Pending` | ebs-csi-node evicted | Patch ebs-csi-node DaemonSet |
| DNS resolution fails | CoreDNS evicted or not running on compute nodes | Patch coredns Deployment |
| Patches revert after EKS upgrade | Managed add-ons re-deployed during upgrade | Re-run the patch script after every EKS upgrade |
