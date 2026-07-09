#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# Patch GKE system components with sunk.coreweave.com/lock NoExecute toleration.
#
# The SUNK operator applies this taint to any node running NodeSet pods.
# On GKE with shared nodepools (default), the taint evicts every pod that
# does not tolerate it, including critical system components:
#
#   - konnectivity-agent   => kubectl exec/logs break (HIGH IMPACT, most common)
#   - kube-dns             => in-cluster DNS breaks
#   - cert-manager-*       => MOCO MySQL webhook breaks
#   - moco-controller      => MySQL reconcile breaks
#   - metrics-server       => HPA and `kubectl top` break
#   - gmp-operator         => Google Managed Prometheus scraping breaks
#
# This script is MANDATORY on every GKE deployment, not optional. Run it
# once after compute nodes join the cluster, and re-run after any GKE
# upgrade (GKE re-deploys managed Deployments during upgrade and wipes
# our custom tolerations).
#
# Idempotent: re-running is safe. Strategic merge is attempted first, then
# verified. Some GKE-managed workloads accepted the strategic patch without
# retaining the toleration, so we fall back to explicit JSON patching when the
# lock key is still absent after the first patch.

set -euo pipefail

LOCK_TOLERATION_JSON='{"key":"sunk.coreweave.com/lock","operator":"Exists","effect":"NoExecute"}'

# Strategic merge patch body for native resources that support it (the
# Kubernetes PodSpec registers `key` as the patchMergeKey on tolerations,
# so this appends cleanly when the lock key is absent and is a no-op when
# it is already present).
SMP_BODY=$(cat <<EOF
{"spec":{"template":{"spec":{"tolerations":[${LOCK_TOLERATION_JSON}]}}}}
EOF
)

patch_deploy() {
    local name="$1" ns="$2"
    if ! kubectl get deployment "$name" -n "$ns" >/dev/null 2>&1; then
        echo "  $ns/$name: not found, skipped"
        return
    fi
    kubectl patch deployment "$name" -n "$ns" --type=strategic -p "$SMP_BODY" >/dev/null 2>&1 || true
    if ensure_template_toleration deployment "$name" "$ns"; then
        echo "  $ns/$name: patched"
    else
        echo "  $ns/$name: FAILED to patch (investigate manually)" >&2
        return 1
    fi
}

patch_statefulset() {
    local name="$1" ns="$2"
    if ! kubectl get statefulset "$name" -n "$ns" >/dev/null 2>&1; then
        echo "  $ns/$name: not found, skipped"
        return
    fi
    kubectl patch statefulset "$name" -n "$ns" --type=strategic -p "$SMP_BODY" >/dev/null 2>&1 || true
    if ensure_template_toleration statefulset "$name" "$ns"; then
        echo "  $ns/$name: patched"
    else
        echo "  $ns/$name: FAILED to patch (investigate manually)" >&2
        return 1
    fi
}

ensure_template_toleration() {
    local kind="$1" name="$2" ns="$3"
    local current path
    current=$(kubectl get "$kind" "$name" -n "$ns" \
        -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null || echo "")
    if echo "$current" | grep -q 'sunk.coreweave.com/lock'; then
        return 0
    fi
    if [[ -z "$current" || "$current" == "[]" ]]; then
        path="/spec/template/spec/tolerations"
        kubectl patch "$kind" "$name" -n "$ns" --type=json \
            -p "[{\"op\":\"add\",\"path\":\"${path}\",\"value\":[${LOCK_TOLERATION_JSON}]}]" >/dev/null
    else
        path="/spec/template/spec/tolerations/-"
        kubectl patch "$kind" "$name" -n "$ns" --type=json \
            -p "[{\"op\":\"add\",\"path\":\"${path}\",\"value\":${LOCK_TOLERATION_JSON}}]" >/dev/null
    fi
    current=$(kubectl get "$kind" "$name" -n "$ns" \
        -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null || echo "")
    echo "$current" | grep -q 'sunk.coreweave.com/lock'
}

echo "Patching kube-system deployments..."
for deploy in konnectivity-agent konnectivity-agent-autoscaler kube-dns kube-dns-autoscaler event-exporter-gke l7-default-backend; do
    patch_deploy "$deploy" kube-system
done

# metrics-server name includes a version suffix on GKE
METRICS_SERVER=$(kubectl get deploy -n kube-system -o name 2>/dev/null | grep metrics-server | head -1 | sed 's|deployment.apps/||')
if [ -n "$METRICS_SERVER" ]; then
    patch_deploy "$METRICS_SERVER" kube-system
fi

echo ""
echo "Patching cert-manager deployments..."
for deploy in cert-manager cert-manager-cainjector cert-manager-webhook; do
    patch_deploy "$deploy" cert-manager
done

echo ""
echo "Patching MOCO control plane..."
patch_deploy moco-controller moco-system

echo ""
echo "Patching GMP operator..."
patch_deploy gmp-operator gmp-system

echo ""
echo "Patching GKE managed kube-state-metrics..."
patch_statefulset kube-state-metrics gke-managed-cim

# MOCO MySQLCluster CR -- strategic merge is NOT registered on this CRD's
# podTemplate, so we read-merge-write via a JSON merge patch. Any
# pre-existing tolerations on the CR are preserved.
echo ""
echo "Patching MOCO MySQLCluster resources in tenant-slurm..."
MC_RESOURCES=$(kubectl get mysqlcluster -n tenant-slurm -o name 2>/dev/null || true)
if [ -z "$MC_RESOURCES" ]; then
    echo "  no MySQLCluster resources in tenant-slurm, skipped"
else
    for mc in $MC_RESOURCES; do
        short="${mc#mysqlcluster.moco.cybozu.com/}"
        current=$(kubectl get "$mc" -n tenant-slurm \
            -o jsonpath='{.spec.podTemplate.spec.tolerations}' 2>/dev/null || echo "")
        if echo "$current" | grep -q 'sunk.coreweave.com/lock'; then
            echo "  tenant-slurm/$short: already tolerates lock, skipped"
            continue
        fi
        if [[ -z "$current" || "$current" == "[]" ]]; then
            merged="[${LOCK_TOLERATION_JSON}]"
        else
            merged=$(printf '%s' "$current" | \
                python3 -c "import sys, json; t = json.load(sys.stdin); t.append(${LOCK_TOLERATION_JSON}); print(json.dumps(t))")
        fi
        if kubectl patch "$mc" -n tenant-slurm --type=merge \
            -p "{\"spec\":{\"podTemplate\":{\"spec\":{\"tolerations\":${merged}}}}}" >/dev/null 2>&1; then
            echo "  tenant-slurm/$short: patched"
        else
            echo "  tenant-slurm/$short: FAILED to patch (investigate manually)" >&2
        fi
    done
fi

echo ""
echo "Done."
echo "Verify:  kubectl get pods -A --no-headers | grep -vE 'Running|Completed'"
echo "         kubectl get nodes -l cloud.google.com/gke-nodepool -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints"
