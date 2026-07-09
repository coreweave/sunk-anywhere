---
name: patch-gke-system-tolerations
description: >
  Patch GKE system and infrastructure pods to tolerate the SUNK lock taint
  (sunk.coreweave.com/lock=true:NoExecute). Run after initial SUNK deployment,
  after GKE upgrades, or when kubectl exec/logs fails with "No agent available".
  Use when asked to "patch GKE tolerations", "fix evicted system pods",
  "fix konnectivity", "fix kubectl exec not working on SUNK GKE", or
  "re-run toleration patches after GKE upgrade".
---

# Patch GKE System Tolerations for SUNK Lock Taint

Patch GKE system and infrastructure pods so they survive the non-configurable `sunk.coreweave.com/lock=true:NoExecute` taint that the SUNK operator applies to every node running compute pods. This is a cross-cutting concern that must be run after initial deployment and potentially re-run after GKE upgrades.

## Background

The SUNK operator hardcodes a `NoExecute` taint on any Kubernetes node running compute (NodeSet) pods:

```
sunk.coreweave.com/lock=true:NoExecute
```

This is not configurable. On CoreWeave infrastructure, compute nodes are dedicated, so this is harmless. On GKE with shared node pools, this taint evicts all pods that do not tolerate it, including critical system components.

### What breaks when this taint hits

| Component | Namespace | Kind | Impact |
|-----------|-----------|------|--------|
| konnectivity-agent | kube-system | Deployment / DaemonSet | ALL `kubectl exec`, `kubectl logs`, and webhook calls fail with "No agent available" |
| kube-dns | kube-system | Deployment | DNS resolution stops for all pods on affected nodes |
| cert-manager | cert-manager | Deployment | Certificate renewal and issuance stops, breaking MOCO and other TLS-dependent services |
| moco-controller | moco-system | Deployment | MySQL operator cannot manage databases |
| metrics-server | kube-system | Deployment | HPA scaling and `kubectl top` break |
| event-exporter-gke | kube-system | Deployment | Events stop being exported to Cloud Logging |
| l7-default-backend | kube-system | Deployment | Default backend for GKE Ingress stops responding |
| gmp-operator | gmp-system | Deployment | Google Managed Prometheus stops working |
| kube-state-metrics | gke-managed-cim | StatefulSet | GMP-managed kube-state metrics drop, breaking dashboards that read them |
| dcgm-exporter | monitoring | DaemonSet | GPU metrics collection stops |

## When to Run This

1. **After initial SUNK deployment** -- once compute nodes join and get tainted.
2. **After GKE cluster upgrades** -- GKE may revert managed deployment specs, stripping the toleration.
3. **When pods are evicted from nodes running SUNK compute pods.**
4. **When `kubectl exec` or `kubectl logs` suddenly fails with "No agent available."**
5. **When DNS resolution stops working inside pods on compute nodes.**

## The Patch Script

The script ships in this repo at `infrastructure/gke/patch-gke-tolerations.sh`.
It is the source of truth — read it directly to see what gets patched.
High-level behavior:

1. For each managed Deployment or StatefulSet, attempt a strategic merge
   patch that appends the lock toleration. The Pod spec registers `key` as
   the patchMergeKey on tolerations, so this is correct whether the target
   currently has zero, one, or many tolerations.
2. **Verify the patch took effect** by re-reading
   `.spec.template.spec.tolerations` and grepping for
   `sunk.coreweave.com/lock`. Some GKE-managed workloads accept the
   strategic patch silently without retaining the toleration.
3. If the toleration is still missing, fall back to an explicit JSON patch
   (`add /spec/template/spec/tolerations` when the array is empty;
   `add /spec/template/spec/tolerations/-` when it has entries).
4. The script supports both Deployments (`patch_deploy`) and StatefulSets
   (`patch_statefulset`). The kube-state-metrics workload in
   `gke-managed-cim` is a StatefulSet — Deployment-only patchers miss it.
5. The MOCO MySQLCluster CR uses a separate read-merge-write JSON merge
   patch because strategic merge is not registered on its `podTemplate`.

Run it:

```bash
bash infrastructure/gke/patch-gke-tolerations.sh
```

## JSON Patch Details

The script uses two patch strategies depending on whether the resource already has a `tolerations` array.

**Appending to an existing array** (most GKE system pods have default tolerations):

```json
[{
  "op": "add",
  "path": "/spec/template/spec/tolerations/-",
  "value": {
    "key": "sunk.coreweave.com/lock",
    "operator": "Exists",
    "effect": "NoExecute"
  }
}]
```

**Creating the array from scratch** (for resources with no tolerations defined):

```json
[{
  "op": "add",
  "path": "/spec/template/spec/tolerations",
  "value": [{
    "key": "sunk.coreweave.com/lock",
    "operator": "Exists",
    "effect": "NoExecute"
  }]
}]
```

The `operator: Exists` means the toleration matches the taint key regardless of the taint value, which is more resilient than matching a specific value.

## Deployments and DaemonSets to Patch

### kube-system namespace

| Resource | Kind | Notes |
|----------|------|-------|
| konnectivity-agent | Deployment or DaemonSet | Kind depends on GKE version. Script tries both. |
| konnectivity-agent-autoscaler | Deployment | Only exists when konnectivity-agent is a Deployment |
| kube-dns | Deployment | |
| kube-dns-autoscaler | Deployment | |
| event-exporter-gke | Deployment | |
| l7-default-backend | Deployment | |
| metrics-server-v0.7.x | Deployment | Name includes version number. Script discovers it dynamically. |

### cert-manager namespace

| Resource | Kind | Notes |
|----------|------|-------|
| cert-manager | Deployment | |
| cert-manager-cainjector | Deployment | |
| cert-manager-webhook | Deployment | |

### moco-system namespace

| Resource | Kind | Notes |
|----------|------|-------|
| moco-controller | Deployment | |

### gmp-system namespace

| Resource | Kind | Notes |
|----------|------|-------|
| gmp-operator | Deployment | |

### gke-managed-cim namespace

| Resource | Kind | Notes |
|----------|------|-------|
| kube-state-metrics | StatefulSet | GMP-managed kube-state metrics. Strategic merge alone has been observed to silently no-op here, which is why the script verifies and falls back to JSON patch. |

### monitoring namespace (if observability is deployed)

| Resource | Kind | Notes |
|----------|------|-------|
| dcgm-exporter | DaemonSet | GPU metrics, only present with GPU monitoring |
| gmp-frontend | Deployment | Prometheus query frontend |
| grafana | Deployment | Dashboard UI |

## Verification

After running the patch script, verify that the toleration was actually
persisted on each managed workload, then wait for rollout and confirm the
critical user-visible signals still work.

```bash
# 1. Toleration is present on every patched workload (the script's own check).
for d in konnectivity-agent kube-dns; do
  kubectl get deploy "$d" -n kube-system \
    -o jsonpath='{.spec.template.spec.tolerations}' | grep -q sunk.coreweave.com/lock \
    && echo "  kube-system/$d: ok" || echo "  kube-system/$d: MISSING toleration"
done
kubectl get sts kube-state-metrics -n gke-managed-cim \
  -o jsonpath='{.spec.template.spec.tolerations}' | grep -q sunk.coreweave.com/lock \
  && echo "  gke-managed-cim/kube-state-metrics: ok" \
  || echo "  gke-managed-cim/kube-state-metrics: MISSING toleration"

# 2. Wait for the rollouts to settle so the new tolerations are actually live.
kubectl rollout status deploy/konnectivity-agent -n kube-system --timeout=180s
kubectl rollout status deploy/kube-dns -n kube-system --timeout=180s
kubectl rollout status sts/kube-state-metrics -n gke-managed-cim --timeout=180s

# 3. kubectl exec works end-to-end through konnectivity (this is the canary).
kubectl exec -n tenant-slurm slurm-login-0 -c sshd -- hostname

# 4. Check for evicted pods across all namespaces.
kubectl get pods --all-namespaces --field-selector=status.phase=Failed | grep Evict || echo "  none"

# 5. Clean up evicted pod remnants (safe to run).
kubectl get pods --all-namespaces --field-selector=status.phase=Failed -o json \
  | jq -r '.items[] | select(.status.reason=="Evicted") | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read ns name; do kubectl delete pod -n "$ns" "$name"; done

# 6. cert-manager and MOCO are healthy.
kubectl get pods -n cert-manager
kubectl get pods -n moco-system
```

## Important Notes

- **GKE reconciliation**: GKE periodically reconciles managed deployments (konnectivity-agent, kube-dns, metrics-server, etc.) and MAY strip the toleration. Monitor for evicted pods and re-run the script as needed.
- **metrics-server versioning**: The deployment name includes a version number (e.g., `metrics-server-v0.7.4`) that changes with GKE upgrades. The script discovers the name dynamically via label/name matching.
- **konnectivity-agent kind**: In newer GKE versions, `konnectivity-agent` may be a DaemonSet instead of a Deployment. The script attempts to patch both kinds and skips whichever does not exist.
- **Idempotency**: The script checks for an existing toleration before patching. It is safe to run multiple times.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `kubectl exec` returns "No agent available" | konnectivity-agent evicted from compute nodes | Run `infrastructure/gke/patch-gke-tolerations.sh`, verify konnectivity-agent pods are Running |
| DNS resolution fails inside pods | kube-dns evicted from compute nodes | Run `infrastructure/gke/patch-gke-tolerations.sh`, verify kube-dns pods are Running |
| Certificate errors from MOCO or webhooks | cert-manager evicted, certs expired or not issued | Run `infrastructure/gke/patch-gke-tolerations.sh`, then `kubectl rollout restart -n cert-manager deployment/cert-manager` |
| `kubectl top nodes` returns "metrics not available" | metrics-server evicted | Run `infrastructure/gke/patch-gke-tolerations.sh` |
| Script says "not found" for metrics-server | Deployment name changed after GKE upgrade | Check `kubectl get deploy -n kube-system` for the current metrics-server name. The script handles this automatically. |
| Script says "FAILED to patch" | Resource spec may have changed, or RBAC issue | Verify you have cluster-admin. Try the patch manually with `kubectl patch` to see the full error. |
| Patches work but revert after a few hours | GKE control plane reconciliation | Re-run the script. Consider a CronJob or monitoring alert for evicted system pods. |
| konnectivity-agent patch fails on both Deployment and DaemonSet | GKE version uses a different resource kind | Check `kubectl get all -n kube-system` for the actual konnectivity resource type |
| System pods Running but still failing | Pod was patched but not restarted | Force a rollout: `kubectl rollout restart deployment/<name> -n <namespace>` |
| GPU metrics missing after patching | dcgm-exporter DaemonSet not patched or monitoring namespace missing | Verify monitoring namespace exists, then re-run the script |
