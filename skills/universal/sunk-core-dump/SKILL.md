---
name: sunk-core-dump
description: >
  Collects a complete diagnostic dump of a SUNK (Slurm on Kubernetes) cluster —
  Kubernetes resources, Slurm state, pod logs, GPU health, cgroup diagnostics,
  network/storage status, and SUNK CRDs. Saves output to a timestamped directory
  for the SUNK support team. Use when asked to "capture cluster state",
  "core dump", "debug dump", "diagnostic dump", "troubleshoot SUNK",
  "collect logs", "support bundle", "what's wrong with my cluster",
  or "gather diagnostics".
---

# SUNK Core Dump

Collect a complete diagnostic dump of a SUNK cluster. Execute every command, save all output to files, and produce a summary at the end.

## Contents
- Error handling rules
- Step 0: Pre-flight and setup
- Parallel execution strategy
- Step 1: Cluster overview (cluster-infra)
- Step 2: SUNK operator namespace (sunk-operator)
- Step 3: Slurm namespace — Kubernetes layer (slurm-state)
- Step 4: Slurm state (slurm-state)
- Step 5: GPU and hardware (compute-health)
- Step 6: Compute system diagnostics (compute-health)
- Step 7: Supporting services (cluster-infra)
- Step 8: Network and DNS (slurm-state)
- Step 9: Syncer metrics (sunk-operator)
- Step 10: Summary and analysis
- Step 11: Package and deliver
- References: [interpreting-results.md](references/interpreting-results.md), [privacy-notes.md](references/privacy-notes.md)

## Progress Checklist

Copy this checklist and update as you go:

```
Dump Progress:
- [ ] Step 0: Pre-flight and setup
- [ ] Step 1: Cluster overview (cluster-infra)
- [ ] Step 2: SUNK operator namespace (sunk-operator)
- [ ] Step 3: Slurm namespace — Kubernetes layer (slurm-state)
- [ ] Step 4: Slurm state (slurm-state)
- [ ] Step 5: GPU and hardware (compute-health)
- [ ] Step 6: Compute system diagnostics (compute-health)
- [ ] Step 7: Supporting services (cluster-infra)
- [ ] Step 8: Network and DNS (slurm-state)
- [ ] Step 9: Syncer metrics (sunk-operator)
- [ ] Step 10: Summary and analysis
- [ ] Step 11: Package and deliver
```

## Error Handling

**A partial dump is infinitely more useful than no dump.**

- Append `2>&1 || true` to every command. Errors are diagnostic data — capture them and move on.
- Never stop the dump because a step fails. Write what you got, proceed to the next command.
- Never retry a failed command unless explicitly instructed.
- If an entire step cannot run (no login pod, no GPU pods), write a skip note and continue.
- Log progress after each step: "Step 2 complete — syncer pod not found, logged error."

## Step 0: Pre-flight and Setup

### 0a. Verify required tools

Check that `kubectl` and `helm` are available. **Stop if either is missing** — the dump cannot run without them.

```bash
echo "=== Tool check ==="
kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null || { echo "FATAL: kubectl not found in PATH"; exit 1; }
helm version --short 2>/dev/null || { echo "FATAL: helm not found in PATH"; exit 1; }
python3 --version 2>/dev/null || echo "WARNING: python3 not found — namespace discovery and GPU node detection will fall back to defaults"
```

### 0b. Identify cluster and confirm with user

Show context, cluster, and server. **Ask the user to confirm before proceeding.**

```bash
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null)
CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CURRENT_CONTEXT')].context.cluster}" 2>/dev/null)
CLUSTER_SERVER=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='$CLUSTER_NAME')].cluster.server}" 2>/dev/null)
CLUSTER_USER=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CURRENT_CONTEXT')].context.user}" 2>/dev/null)
echo "Context: ${CURRENT_CONTEXT:-NOT SET}  Cluster: ${CLUSTER_NAME:-UNKNOWN}  Server: ${CLUSTER_SERVER:-UNKNOWN}  User: ${CLUSTER_USER:-UNKNOWN}"
```

**Stop** if `CURRENT_CONTEXT` is empty — user must set one first (`kubectl config use-context <name>`).

### 0c. Verify cluster connectivity

```bash
kubectl cluster-info 2>&1 || { echo "FATAL: cannot reach cluster at $CLUSTER_SERVER"; exit 1; }
```

**Stop** if unreachable.

### 0d. Auto-discover SUNK namespaces from Helm releases

Discover where SUNK and Slurm are deployed instead of assuming fixed namespace names. Handles e2e/kind clusters where everything lands in `default`.

```bash
HELM_JSON=$(helm list -A -o json 2>/dev/null || true)

SUNK_RELEASE_LINE=$(echo "$HELM_JSON" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    if 'sunk' in r.get('chart', '').lower() and 'slurm' not in r.get('chart', '').lower():
        print(f\"{r['name']}\t{r['namespace']}\"); break
" 2>/dev/null || true)

SLURM_RELEASE_LINE=$(echo "$HELM_JSON" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    if 'slurm' in r.get('chart', '').lower():
        print(f\"{r['name']}\t{r['namespace']}\"); break
" 2>/dev/null || true)

if [ -n "$SUNK_RELEASE_LINE" ]; then
  SUNK_RELEASE=$(echo "$SUNK_RELEASE_LINE" | cut -f1)
  SUNK_NS=$(echo "$SUNK_RELEASE_LINE" | cut -f2)
else
  SUNK_NS="${SUNK_NS:-sunk}"; SUNK_RELEASE=""
fi

if [ -n "$SLURM_RELEASE_LINE" ]; then
  SLURM_RELEASE=$(echo "$SLURM_RELEASE_LINE" | cut -f1)
  SLURM_NS=$(echo "$SLURM_RELEASE_LINE" | cut -f2)
else
  SLURM_NS="${SLURM_NS:-tenant-slurm}"; SLURM_RELEASE=""
fi

MONITORING_NS="${MONITORING_NS:-monitoring}"

GPU_OP_RELEASE_LINE=$(echo "$HELM_JSON" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    if 'gpu-operator' in r.get('chart', '').lower():
        print(f\"{r['name']}\t{r['namespace']}\"); break
" 2>/dev/null || true)

if [ -n "$GPU_OP_RELEASE_LINE" ]; then
  GPU_OP_RELEASE=$(echo "$GPU_OP_RELEASE_LINE" | cut -f1)
  GPU_OP_NS=$(echo "$GPU_OP_RELEASE_LINE" | cut -f2)
else
  GPU_OP_NS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -i gpu-operator | awk '{print $1}' | head -1 || true)
  GPU_OP_RELEASE=""
fi

echo "SUNK: ${SUNK_RELEASE:-NOT FOUND} ($SUNK_NS)  Slurm: ${SLURM_RELEASE:-NOT FOUND} ($SLURM_NS)  Monitoring: $MONITORING_NS"
echo "GPU Operator: ${GPU_OP_RELEASE:-NOT FOUND} (${GPU_OP_NS:-NOT DETECTED})"
```

Falls back to `sunk`/`tenant-slurm` if no Helm releases found. Use `$SUNK_RELEASE`/`$SLURM_RELEASE` in all subsequent `helm get values` commands.

### 0e. Output destination

Ask the user where to save the dump: **local directory** (default: current working directory), **custom path**, or **remote destination** (collect locally, then upload via `scp`/`aws s3 cp`/`gcloud storage cp`/`az storage blob upload`). Default to current directory if unspecified.

```bash
OUTPUT_BASE="${OUTPUT_BASE:-.}"
DUMP_DIR="${OUTPUT_BASE}/sunk-core-dump-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DUMP_DIR"/{cluster,sunk/logs,slurm-k8s/{logs,describe},slurm-state,gpu/logs,system,services,network,metrics}
echo "Dump directory: $DUMP_DIR"
```

### 0f. Discover key pods

Identify the login pod (needed for Slurm commands in later steps). Use `$SLURM_NS` as discovered in step 0d:

```bash
LOGIN_POD=$(kubectl get pods -n $SLURM_NS --no-headers 2>/dev/null | grep slurm-login | awk '{print $1}' | head -1)
echo "Login pod: ${LOGIN_POD:-NOT FOUND}"
```

If no login pod is found, Slurm state commands in Step 4 will be skipped. Note this in the summary but do NOT stop.

Identify all compute pods (needed for Steps 5 and 6):

```bash
ALL_COMPUTE_PODS=$(kubectl get pods -n $SLURM_NS --no-headers 2>/dev/null | grep -vE 'slurm-controller|slurm-login|slurm-accounting|slurm-rest|slurm-syncer|nfs-server|openldap|mysql|moco|secret-job|cleanup' | awk '{print $1}' | tr '\n' ' ' || true)
GPU_PODS=$(kubectl get pods -n $SLURM_NS --no-headers 2>/dev/null | grep gpu-workers | awk '{print $1}' | tr '\n' ' ' || true)
echo "Compute pods: $(echo $ALL_COMPUTE_PODS | wc -w)"
echo "GPU pods: $(echo $GPU_PODS | wc -w)"
```

## Parallel Execution Strategy

After Step 0 completes, Steps 1–9 are **independent** — they share no data between them and only depend on the variables discovered in Step 0 (`DUMP_DIR`, `SLURM_NS`, `SUNK_NS`, `MONITORING_NS`, `LOGIN_POD`, `ALL_COMPUTE_PODS`, `GPU_PODS`, `SUNK_RELEASE`, `SLURM_RELEASE`, `CURRENT_CONTEXT`, `CLUSTER_NAME`, `CLUSTER_SERVER`, `CLUSTER_USER`, `GPU_OP_NS`, `GPU_OP_RELEASE`).

**Launch parallel subagents to collect data concurrently.** Group related steps to reduce overhead while maximizing wall-clock speedup:

| Agent | Steps | Domain | Key dependencies from Step 0 |
|-------|-------|--------|------|
| **cluster-infra** | 1 + 7 | Cluster overview + supporting services | `DUMP_DIR`, `SLURM_NS`, `SUNK_NS`, `MONITORING_NS`, release names |
| **sunk-operator** | 2 + 9 | SUNK operator + syncer metrics | `DUMP_DIR`, `SUNK_NS`, `SLURM_NS` |
| **slurm-state** | 3 + 4 + 8 | Slurm K8s layer + Slurm state + network | `DUMP_DIR`, `SLURM_NS`, `LOGIN_POD`, `ALL_COMPUTE_PODS` |
| **compute-health** | 5 + 6 | GPU/hardware + compute system diagnostics | `DUMP_DIR`, `SLURM_NS`, `MONITORING_NS`, `GPU_PODS`, `ALL_COMPUTE_PODS`, `GPU_OP_NS` |

### How to pass shared state

After Step 0, write an env file with the discovered values. Every subagent sources it at the start of each bash command.

```bash
cat > "$DUMP_DIR/.env.sh" <<EOF
export DUMP_DIR="$DUMP_DIR"
export SLURM_NS="$SLURM_NS"
export SUNK_NS="$SUNK_NS"
export MONITORING_NS="$MONITORING_NS"
export LOGIN_POD="$LOGIN_POD"
export ALL_COMPUTE_PODS="$ALL_COMPUTE_PODS"
export GPU_PODS="$GPU_PODS"
export SUNK_RELEASE="$SUNK_RELEASE"
export SLURM_RELEASE="$SLURM_RELEASE"
export CURRENT_CONTEXT="$CURRENT_CONTEXT"
export CLUSTER_NAME="$CLUSTER_NAME"
export CLUSTER_SERVER="$CLUSTER_SERVER"
export CLUSTER_USER="$CLUSTER_USER"
export GPU_OP_NS="$GPU_OP_NS"
export GPU_OP_RELEASE="$GPU_OP_RELEASE"
EOF
```

Each subagent's prompt must include: the path to `.env.sh`, its assigned steps, and the error handling rules. Every subagent bash command begins with `source "$DUMP_DIR/.env.sh"`.

### Execution flow

```
Step 0 (sequential — pre-flight, setup, write .env.sh)
  │
  ├─► cluster-infra  (Steps 1+7)  ─┐
  ├─► sunk-operator  (Steps 2+9)  ─┤
  ├─► slurm-state    (Steps 3+4+8) ─┤  All run concurrently
  └─► compute-health (Steps 5+6)  ─┘
                                │
                          wait for all
                                │
                    Steps 10 + 11 (sequential — summary, package)
```

### Fallback

If subagents are not available (e.g., running in a restricted environment), execute Steps 1–9 sequentially in the main agent. The commands are identical — only the concurrency changes. Where possible, still batch independent bash commands within a single step using parallel tool calls.

---

## Step 1: Cluster Overview  *(cluster-infra)*

Run each command and save output. Every command gets `2>&1 || true`.

```bash
# Save pre-flight context (from step 0b) so the dump is self-documenting
cat > "$DUMP_DIR/cluster/context.txt" << CTX_EOF
kubeconfig-context: $CURRENT_CONTEXT
cluster-name:      $CLUSTER_NAME
server:            $CLUSTER_SERVER
user:              $CLUSTER_USER
sunk-release:      ${SUNK_RELEASE:-NOT FOUND}
sunk-namespace:    $SUNK_NS
slurm-release:     ${SLURM_RELEASE:-NOT FOUND}
slurm-namespace:   $SLURM_NS
dump-timestamp:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
CTX_EOF

kubectl version > "$DUMP_DIR/cluster/k8s-version.txt" 2>&1 || true
kubectl cluster-info > "$DUMP_DIR/cluster/cluster-info.txt" 2>&1 || true
kubectl get nodes -o wide > "$DUMP_DIR/cluster/nodes-wide.txt" 2>&1 || true
kubectl get nodes -o json > "$DUMP_DIR/cluster/nodes-full.json" 2>&1 || true
kubectl top nodes > "$DUMP_DIR/cluster/node-top.txt" 2>&1 || true
kubectl get storageclasses > "$DUMP_DIR/cluster/storageclasses.txt" 2>&1 || true
kubectl get namespaces > "$DUMP_DIR/cluster/namespaces.txt" 2>&1 || true
helm list -A > "$DUMP_DIR/cluster/helm-releases.txt" 2>&1 || true
# Use discovered release names from step 0d (not hardcoded)
if [ -n "$SLURM_RELEASE" ]; then
  helm get values "$SLURM_RELEASE" -n $SLURM_NS > "$DUMP_DIR/cluster/helm-values-slurm.yaml" 2>&1 || true
  helm list -n $SLURM_NS -o yaml > "$DUMP_DIR/cluster/helm-chart-slurm.txt" 2>&1 || true
fi
if [ -n "$SUNK_RELEASE" ]; then
  helm get values "$SUNK_RELEASE" -n $SUNK_NS > "$DUMP_DIR/cluster/helm-values-sunk.yaml" 2>&1 || true
  helm list -n $SUNK_NS -o yaml > "$DUMP_DIR/cluster/helm-chart-sunk.txt" 2>&1 || true
fi
```

Node taints and labels (critical for lock taint diagnosis):

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key,EFFECTS:.spec.taints[*].effect' > "$DUMP_DIR/cluster/node-taints.txt" 2>&1 || true
```

Node conditions (pressure conditions, provider health checks):

```bash
kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for node in data['items']:
    name = node['metadata']['name']
    print(f'=== {name} ===')
    for c in node['status'].get('conditions', []):
        print(f\"  {c['type']}: {c['status']} ({c.get('reason', '')})\")
    taints = node['spec'].get('taints', [])
    if taints:
        print(f'  Taints: {[t[\"key\"] + \"=\" + t.get(\"value\",\"\") + \":\" + t[\"effect\"] for t in taints]}')
    print()
" > "$DUMP_DIR/cluster/node-conditions-taints.txt" 2>&1 || true
```

## Step 2: SUNK Operator Namespace  *(sunk-operator)*

```bash
kubectl get pods -n $SUNK_NS -o wide > "$DUMP_DIR/sunk/pods.txt" 2>&1 || true
kubectl get pods -n $SUNK_NS -o json > "$DUMP_DIR/sunk/pods-full.json" 2>&1 || true
kubectl get deployments -n $SUNK_NS -o wide > "$DUMP_DIR/sunk/deployments.txt" 2>&1 || true
kubectl get svc -n $SUNK_NS > "$DUMP_DIR/sunk/services.txt" 2>&1 || true
kubectl get events -n $SUNK_NS --sort-by='.lastTimestamp' > "$DUMP_DIR/sunk/events.txt" 2>&1 || true
kubectl get configmaps -n $SUNK_NS > "$DUMP_DIR/sunk/configmaps.txt" 2>&1 || true
kubectl get secrets -n $SUNK_NS > "$DUMP_DIR/sunk/secrets.txt" 2>&1 || true
```

SUNK CRDs — the operator-managed custom resources that define cluster topology. Some of these CRDs may not exist on every cluster — capture the error and move on:

```bash
kubectl get crds -o name 2>/dev/null | grep -i sunk > "$DUMP_DIR/sunk/crds.txt" 2>&1 || true
kubectl api-resources --api-group=sunk.coreweave.com > "$DUMP_DIR/sunk/api-resources.txt" 2>&1 || true
kubectl get sunkclusters -A -o yaml > "$DUMP_DIR/sunk/sunkclusters.yaml" 2>&1 || true
kubectl get slurmclusters -A -o yaml > "$DUMP_DIR/sunk/slurmclusters.yaml" 2>&1 || true
kubectl get nodesets -A -o yaml > "$DUMP_DIR/sunk/nodesets.yaml" 2>&1 || true
kubectl get nodeslices -A -o yaml > "$DUMP_DIR/sunk/nodeslices.yaml" 2>&1 || true
```

SUNK pod logs — capture all pods in the namespace. If a pod has no previous logs, skip that file:

```bash
for pod in $(kubectl get pods -n $SUNK_NS --no-headers -o custom-columns=':metadata.name' 2>/dev/null); do
  for container in $(kubectl get pod -n $SUNK_NS "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
    kubectl logs -n $SUNK_NS "$pod" -c "$container" --tail=1000 --limit-bytes=5242880 > "$DUMP_DIR/sunk/logs/${pod}_${container}.log" 2>&1 || true
    kubectl logs -n $SUNK_NS "$pod" -c "$container" --tail=1000 --limit-bytes=5242880 --previous > "$DUMP_DIR/sunk/logs/${pod}_${container}_previous.log" 2>/dev/null || rm -f "$DUMP_DIR/sunk/logs/${pod}_${container}_previous.log"
  done
done
```

## Step 3: Slurm Namespace — Kubernetes Layer  *(slurm-state)*

```bash
kubectl get pods -n $SLURM_NS -o wide > "$DUMP_DIR/slurm-k8s/pods.txt" 2>&1 || true
kubectl get pods -n $SLURM_NS -o json > "$DUMP_DIR/slurm-k8s/pods-full.json" 2>&1 || true
kubectl get statefulsets -n $SLURM_NS -o wide > "$DUMP_DIR/slurm-k8s/statefulsets.txt" 2>&1 || true
kubectl get deployments -n $SLURM_NS -o wide > "$DUMP_DIR/slurm-k8s/deployments.txt" 2>&1 || true
kubectl get daemonsets -n $SLURM_NS -o wide > "$DUMP_DIR/slurm-k8s/daemonsets.txt" 2>&1 || true
kubectl get svc -n $SLURM_NS > "$DUMP_DIR/slurm-k8s/services.txt" 2>&1 || true
kubectl get pvc -n $SLURM_NS > "$DUMP_DIR/slurm-k8s/pvcs.txt" 2>&1 || true
kubectl get configmaps -n $SLURM_NS > "$DUMP_DIR/slurm-k8s/configmaps.txt" 2>&1 || true
kubectl get secrets -n $SLURM_NS > "$DUMP_DIR/slurm-k8s/secrets.txt" 2>&1 || true
kubectl get jobs -n $SLURM_NS > "$DUMP_DIR/slurm-k8s/jobs.txt" 2>&1 || true
kubectl get endpoints -n $SLURM_NS > "$DUMP_DIR/slurm-k8s/endpoints.txt" 2>&1 || true
kubectl get events -n $SLURM_NS --sort-by='.lastTimestamp' > "$DUMP_DIR/slurm-k8s/events.txt" 2>&1 || true
kubectl top pods -n $SLURM_NS > "$DUMP_DIR/slurm-k8s/pod-top.txt" 2>&1 || true
```

Slurm configuration (gres.conf is the most fragile — overwritten on every Helm upgrade):

```bash
SLURM_CONF_CM="${SLURM_RELEASE:-slurm}-slurm-conf"
kubectl get configmap "$SLURM_CONF_CM" -n $SLURM_NS -o yaml > "$DUMP_DIR/slurm-k8s/gres-conf.yaml" 2>&1 || true
kubectl get configmap "$SLURM_CONF_CM" -n $SLURM_NS -o jsonpath='{.data.slurm\.conf}' > "$DUMP_DIR/slurm-k8s/slurm-conf.txt" 2>&1 || true
kubectl get configmap -n $SLURM_NS -l app.kubernetes.io/component=topology -o yaml > "$DUMP_DIR/slurm-k8s/topology-conf.yaml" 2>&1 || true
```

Drain annotations (reveals SUNK-initiated drains):

```bash
kubectl get pods -n $SLURM_NS -o custom-columns='NAME:.metadata.name,DRAIN:.metadata.annotations.sunk\.coreweave\.com/drain,PHASE:.status.phase' > "$DUMP_DIR/slurm-k8s/drain-annotations.txt" 2>&1 || true
```

Describe unhealthy pods (anything not Running or Completed):

```bash
for pod in $(kubectl get pods -n $SLURM_NS --no-headers 2>/dev/null | grep -vE 'Running|Completed' | awk '{print $1}'); do
  kubectl describe pod -n $SLURM_NS "$pod" > "$DUMP_DIR/slurm-k8s/describe/${pod}.txt" 2>&1 || true
done
```

Logs from key Slurm control plane components — these are bounded (~15 pods) and contain the diagnostic gold, so collect deep (`--tail=5000`, 10 MB hard ceiling per container):

```bash
for pattern in slurm-controller slurm-login slurm-accounting slurm-rest slurm-syncer slurm-scheduler; do
  for pod in $(kubectl get pods -n $SLURM_NS --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep "^${pattern}"); do
    for container in $(kubectl get pod -n $SLURM_NS "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
      kubectl logs -n $SLURM_NS "$pod" -c "$container" --tail=5000 --limit-bytes=10485760 > "$DUMP_DIR/slurm-k8s/logs/${pod}_${container}.log" 2>&1 || true
      kubectl logs -n $SLURM_NS "$pod" -c "$container" --tail=5000 --limit-bytes=10485760 --previous > "$DUMP_DIR/slurm-k8s/logs/${pod}_${container}_previous.log" 2>/dev/null || rm -f "$DUMP_DIR/slurm-k8s/logs/${pod}_${container}_previous.log"
    done
  done
done
```

MOCO MySQL pods — capture the `mysqld`, `agent`, and `slow-log` container logs (Slurm accounting backend):

```bash
for pod in $(kubectl get pods -n $SLURM_NS --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep "^moco-"); do
  for container in $(kubectl get pod -n $SLURM_NS "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
    kubectl logs -n $SLURM_NS "$pod" -c "$container" --tail=5000 --limit-bytes=10485760 > "$DUMP_DIR/slurm-k8s/logs/${pod}_${container}.log" 2>&1 || true
    kubectl logs -n $SLURM_NS "$pod" -c "$container" --tail=5000 --limit-bytes=10485760 --previous > "$DUMP_DIR/slurm-k8s/logs/${pod}_${container}_previous.log" 2>/dev/null || rm -f "$DUMP_DIR/slurm-k8s/logs/${pod}_${container}_previous.log"
  done
done
```

Compute pod logs — all unhealthy pods plus a sample of healthy ones (lighter weight since these can number in the hundreds):

```bash
HEALTHY_COUNT=0
for pod in $ALL_COMPUTE_PODS; do
  STATUS=$(kubectl get pod -n $SLURM_NS "$pod" --no-headers -o custom-columns=':status.phase' 2>/dev/null || echo "Unknown")
  if [ "$STATUS" != "Running" ]; then
    for container in $(kubectl get pod -n $SLURM_NS "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
      kubectl logs -n $SLURM_NS "$pod" -c "$container" --tail=500 --limit-bytes=2097152 > "$DUMP_DIR/slurm-k8s/logs/${pod}_${container}.log" 2>&1 || true
    done
  elif [ "$HEALTHY_COUNT" -lt 3 ]; then
    for container in $(kubectl get pod -n $SLURM_NS "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
      kubectl logs -n $SLURM_NS "$pod" -c "$container" --tail=500 --limit-bytes=2097152 > "$DUMP_DIR/slurm-k8s/logs/${pod}_${container}.log" 2>&1 || true
    done
    HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
  fi
done
```

## Step 4: Slurm State  *(slurm-state)*

All Slurm commands execute via `kubectl exec` to the login pod. **If `LOGIN_POD` is empty, write "SKIPPED: no login pod found" to each file and proceed to Step 5.**

The exec pattern for every command:
```
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- <command> > file 2>&1 || true
```

```bash
if [ -n "$LOGIN_POD" ]; then

# Node states
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sinfo > "$DUMP_DIR/slurm-state/sinfo.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sinfo -N -l > "$DUMP_DIR/slurm-state/sinfo-detail.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sinfo -R > "$DUMP_DIR/slurm-state/sinfo-reasons.txt" 2>&1 || true

# Job queue
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- squeue -l > "$DUMP_DIR/slurm-state/squeue.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- squeue -o "%.18i %.9P %.20j %.8u %.8T %.10M %.6D %.20R %.10m %.5C %.8b" > "$DUMP_DIR/slurm-state/squeue-detail.txt" 2>&1 || true

# Configuration and cluster state
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- scontrol show config > "$DUMP_DIR/slurm-state/scontrol-config.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- scontrol show partitions > "$DUMP_DIR/slurm-state/scontrol-partitions.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- scontrol show nodes > "$DUMP_DIR/slurm-state/scontrol-nodes.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- scontrol show jobs > "$DUMP_DIR/slurm-state/scontrol-jobs.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- scontrol show reservations > "$DUMP_DIR/slurm-state/scontrol-reservations.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- scontrol show frontend > "$DUMP_DIR/slurm-state/scontrol-frontend.txt" 2>&1 || true

# Scheduler diagnostics (RPC counts, backfill stats, cycle times)
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sdiag > "$DUMP_DIR/slurm-state/sdiag.txt" 2>&1 || true

# Accounting
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sacctmgr show cluster -n > "$DUMP_DIR/slurm-state/sacctmgr-cluster.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sacctmgr show account -n > "$DUMP_DIR/slurm-state/sacctmgr-accounts.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sacctmgr show user -n > "$DUMP_DIR/slurm-state/sacctmgr-users.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sacctmgr show association -n > "$DUMP_DIR/slurm-state/sacctmgr-associations.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sacctmgr show qos -n > "$DUMP_DIR/slurm-state/sacctmgr-qos.txt" 2>&1 || true

# Recent job history
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- sacct --starttime now-1hour --format=JobID,JobName,User,Partition,State,ExitCode,Elapsed,MaxRSS,NodeList -n > "$DUMP_DIR/slurm-state/sacct-recent.txt" 2>&1 || true

# Stuck completing jobs (common incident pattern)
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- squeue -h -t completing -o "%.18i %.9P %.20j %.8u %.8T %.10M %.6D %.20R" > "$DUMP_DIR/slurm-state/completing-jobs.txt" 2>&1 || true

# Drained and down nodes with reasons
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- bash -c 'sinfo -t "drain,drained,draining" -N -O "NodeList:25,StateLong:15,Reason:130" 2>/dev/null || sinfo -R' > "$DUMP_DIR/slurm-state/drained-nodes.txt" 2>&1 || true
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- bash -c 'sinfo -t down -N -O "NodeList:25,StateLong:15,Reason:130" 2>/dev/null || true' > "$DUMP_DIR/slurm-state/down-nodes.txt" 2>&1 || true

# Prolog/epilog and KillWait config (common source of config mismatches)
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- bash -c 'scontrol show config 2>/dev/null | grep -iE "killwait|epilog|prolog"' > "$DUMP_DIR/slurm-state/killwait-prolog.txt" 2>&1 || true

# NFS mount and filesystem health
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- bash -c 'echo "=== mounts ==="; mount | grep -E "nfs|home"; echo ""; echo "=== df /home ==="; df -h /home 2>/dev/null || echo "/home not mounted"' > "$DUMP_DIR/slurm-state/mounts.txt" 2>&1 || true

# User resolution (verifies nsscache/LDAP is working)
kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- bash -c 'getent passwd 2>/dev/null | tail -20 || echo "getent not available"' > "$DUMP_DIR/slurm-state/users.txt" 2>&1 || true

else
  for f in sinfo sinfo-detail sinfo-reasons squeue squeue-detail scontrol-config scontrol-partitions scontrol-nodes scontrol-jobs scontrol-reservations scontrol-frontend sdiag sacctmgr-cluster sacctmgr-accounts sacctmgr-users sacctmgr-associations sacctmgr-qos sacct-recent completing-jobs drained-nodes down-nodes killwait-prolog mounts users; do
    echo "SKIPPED: no login pod found" > "$DUMP_DIR/slurm-state/${f}.txt"
  done
fi
```

## Step 5: GPU and Hardware  *(compute-health)*

**If no GPU pods were found in Step 0, write "SKIPPED: no GPU worker pods found" to `$DUMP_DIR/gpu/SKIPPED.txt` and proceed to Step 6.**

For **each GPU pod**, run every command. If any individual command fails on a pod (e.g., `ibstat` not installed), capture the error and continue to the next command on the same pod:

```bash
for pod in $GPU_PODS; do
  # nvidia-smi overview
  kubectl exec -n $SLURM_NS $pod -c slurmd -- nvidia-smi > "$DUMP_DIR/gpu/${pod}_nvidia-smi.txt" 2>&1 || true

  # Detailed GPU query (ECC errors, temperature, power, clocks)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- nvidia-smi -q > "$DUMP_DIR/gpu/${pod}_nvidia-smi-q.txt" 2>&1 || true

  # Orphaned GPU processes (phantom GPU: 100% util, 0 MiB memory)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- fuser /dev/nvidia* > "$DUMP_DIR/gpu/${pod}_gpu-fuser.txt" 2>&1 || true

  # InfiniBand status (not present on all clusters — capture error and move on)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- ibstat > "$DUMP_DIR/gpu/${pod}_ibstat.txt" 2>&1 || true

  # Kernel GPU errors (Xid errors: 31=MMU fault, 43=GPU fault, 145=NVLink)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- bash -c 'dmesg 2>/dev/null | grep -iE "nvidia|xid|nvrm|gpu" | tail -50' > "$DUMP_DIR/gpu/${pod}_dmesg-gpu.txt" 2>&1 || true
done
```

Health conditions on GPU nodes:

```bash
GPU_NODES=$(kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys
nodes = json.load(sys.stdin)
for n in nodes['items']:
    labels = n['metadata'].get('labels', {})
    cap = n['status'].get('capacity', {})
    if any(k for k in labels if 'gpu' in k.lower() or 'accelerator' in k.lower()) or int(cap.get('nvidia.com/gpu', 0)) > 0:
        print(n['metadata']['name'])
" 2>/dev/null || true)
for node in $GPU_NODES; do
  echo "=== $node ==="
  kubectl get node "$node" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data['status']['conditions']:
    print(f\"  {c['type']}: {c['status']} ({c.get('reason', '')})\")
" 2>/dev/null || echo "  (could not parse conditions)"
  echo ""
done > "$DUMP_DIR/gpu/gpu-node-conditions.txt" 2>&1 || true
```

DCGM exporter status:

```bash
kubectl get pods -n $MONITORING_NS -l app.kubernetes.io/name=dcgm-exporter -o wide > "$DUMP_DIR/gpu/dcgm-pods.txt" 2>&1 || true
```

### NVIDIA GPU Operator and Feature Discovery

Detect whether the NVIDIA GPU Operator is deployed (customers may use it instead of or alongside the standalone `nvidia-device-plugin` that SUNK deploys). Capture operator CRDs, ClusterPolicy, NFD rules, and node discovery labels:

```bash
# Operator and NFD CRDs (presence check)
kubectl get crd -o name 2>/dev/null | grep -iE 'nvidia\.com|nfd\.k8s-sigs\.io' > "$DUMP_DIR/gpu/operator-crds.txt" 2>&1 || true

# ClusterPolicy (the top-level GPU Operator config)
kubectl get clusterpolicies.nvidia.com -A -o yaml > "$DUMP_DIR/gpu/clusterpolicy.yaml" 2>&1 || true

# NVIDIADriver CRs (driver management)
kubectl get nvidiadrivers.nvidia.com -A -o yaml > "$DUMP_DIR/gpu/nvidiadrivers.yaml" 2>&1 || true

# NFD node feature rules
kubectl get nodefeaturerules.nfd.k8s-sigs.io -A -o yaml > "$DUMP_DIR/gpu/nfd-rules.yaml" 2>&1 || true

# GPU Operator workloads (pods, daemonsets, deployments)
if [ -n "$GPU_OP_NS" ]; then
  kubectl get pods,daemonsets,deployments -n "$GPU_OP_NS" -o wide > "$DUMP_DIR/gpu/operator-workloads.txt" 2>&1 || true
  # Operator pod logs (bounded — typically 3-5 pods)
  for pod in $(kubectl get pods -n "$GPU_OP_NS" --no-headers -o custom-columns=':metadata.name' 2>/dev/null); do
    for container in $(kubectl get pod -n "$GPU_OP_NS" "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
      kubectl logs -n "$GPU_OP_NS" "$pod" -c "$container" --tail=1000 --limit-bytes=5242880 > "$DUMP_DIR/gpu/logs/${pod}_${container}.log" 2>&1 || true
    done
  done
fi

# Node discovery labels (GPU product, count, memory, MIG capability, NFD PCI detection)
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.memory,nvidia.com/mig.capable,nvidia.com/gpu.deploy.gpu-feature-discovery,feature.node.kubernetes.io/pci-10de.present,node.kubernetes.io/instance-type > "$DUMP_DIR/gpu/node-discovery-labels.txt" 2>&1 || true

# Standalone nvidia-device-plugin fallback (sunk-anywhere default path)
kubectl get daemonset -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin -o yaml > "$DUMP_DIR/gpu/standalone-device-plugin.yaml" 2>&1 || true
```

## Step 6: Compute System Diagnostics  *(compute-health)*

This step runs on a **sample of ALL compute pods** (GPU and CPU), not just GPU workers. Cgroup and resource limit issues affect CPU-only workers equally.

Select a sample: first 5 compute pods + any non-Running compute pods:

```bash
SAMPLE_PODS=""
SAMPLE_COUNT=0
for pod in $ALL_COMPUTE_PODS; do
  STATUS=$(kubectl get pod -n $SLURM_NS "$pod" --no-headers -o custom-columns=':status.phase' 2>/dev/null || echo "Unknown")
  if [ "$STATUS" != "Running" ] || [ "$SAMPLE_COUNT" -lt 5 ]; then
    SAMPLE_PODS="$SAMPLE_PODS $pod"
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
  fi
done
```

**If no compute pods were found, write "SKIPPED: no compute pods found" to `$DUMP_DIR/system/SKIPPED.txt` and proceed to Step 7.**

For **each sampled compute pod**, run every command. Many of these probe cgroup filesystem paths that differ between cgroup v1 and v2 — both paths are attempted, and whichever fails is captured as "not available":

```bash
for pod in $SAMPLE_PODS; do
  # Cgroup version detection (v1 vs v2 — impacts task/cgroup plugin behavior)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- bash -c '
    echo "=== cgroup version ==="
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
      echo "cgroup v2"
    else
      echo "cgroup v1"
    fi
    echo ""
    echo "=== /proc/filesystems (cgroup entries) ==="
    grep cgroup /proc/filesystems 2>/dev/null || echo "not found"
    echo ""
    echo "=== cgroup hierarchy (process 1) ==="
    cat /proc/1/cgroup 2>/dev/null || echo "not available"
  ' > "$DUMP_DIR/system/${pod}_cgroup-version.txt" 2>&1 || true

  # CPU cgroup limits (throttling causes slow jobs)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- bash -c '
    echo "=== CPU limits ==="
    echo "--- cgroup v2 ---"
    cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo "not available (v2)"
    echo ""
    echo "--- cgroup v1 ---"
    echo -n "cpu.cfs_quota_us: "; cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo "not available (v1)"
    echo -n "cpu.cfs_period_us: "; cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo "not available (v1)"
    echo ""
    echo "=== CPU stats ==="
    echo "--- cgroup v2 ---"
    cat /sys/fs/cgroup/cpu.stat 2>/dev/null || echo "not available (v2)"
    echo ""
    echo "--- cgroup v1 ---"
    cat /sys/fs/cgroup/cpu/cpu.stat 2>/dev/null || echo "not available (v1)"
  ' > "$DUMP_DIR/system/${pod}_cpu-cgroup.txt" 2>&1 || true

  # CPU pinning (cpuset — which CPUs the pod can use)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- bash -c '
    echo "=== cpuset ==="
    echo "--- cgroup v2 ---"
    echo -n "cpuset.cpus.effective: "; cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || echo "not available (v2)"
    echo -n "cpuset.mems.effective: "; cat /sys/fs/cgroup/cpuset.mems.effective 2>/dev/null || echo "not available (v2)"
    echo ""
    echo "--- cgroup v1 ---"
    echo -n "cpuset.cpus: "; cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null || echo "not available (v1)"
    echo -n "cpuset.mems: "; cat /sys/fs/cgroup/cpuset/cpuset.mems 2>/dev/null || echo "not available (v1)"
    echo ""
    echo "=== nproc ==="
    nproc 2>/dev/null || echo "not available"
  ' > "$DUMP_DIR/system/${pod}_cpuset.txt" 2>&1 || true

  # Memory cgroup (OOM kills if ceiling too low)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- bash -c '
    echo "=== Memory limits ==="
    echo "--- cgroup v2 ---"
    echo -n "memory.max: "; cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "not available (v2)"
    echo -n "memory.current: "; cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "not available (v2)"
    echo -n "memory.swap.max: "; cat /sys/fs/cgroup/memory.swap.max 2>/dev/null || echo "not available (v2)"
    echo ""
    echo "--- cgroup v1 ---"
    echo -n "memory.limit_in_bytes: "; cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "not available (v1)"
    echo -n "memory.usage_in_bytes: "; cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo "not available (v1)"
    echo -n "memory.memsw.limit_in_bytes: "; cat /sys/fs/cgroup/memory/memory.memsw.limit_in_bytes 2>/dev/null || echo "not available (v1)"
    echo ""
    echo "=== memory.stat (first 20 lines) ==="
    echo "--- cgroup v2 ---"
    head -20 /sys/fs/cgroup/memory.stat 2>/dev/null || echo "not available (v2)"
    echo ""
    echo "--- cgroup v1 ---"
    head -20 /sys/fs/cgroup/memory/memory.stat 2>/dev/null || echo "not available (v1)"
    echo ""
    echo "=== OOM events ==="
    echo "--- cgroup v2 ---"
    cat /sys/fs/cgroup/memory.events 2>/dev/null || echo "not available (v2)"
    echo ""
    echo "--- cgroup v1 ---"
    echo -n "oom_control: "; cat /sys/fs/cgroup/memory/memory.oom_control 2>/dev/null || echo "not available (v1)"
  ' > "$DUMP_DIR/system/${pod}_memory-cgroup.txt" 2>&1 || true

  # PID limits (fork failures in jobs)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- bash -c '
    echo "=== PID limits ==="
    echo "--- cgroup v2 ---"
    echo -n "pids.max: "; cat /sys/fs/cgroup/pids.max 2>/dev/null || echo "not available (v2)"
    echo -n "pids.current: "; cat /sys/fs/cgroup/pids.current 2>/dev/null || echo "not available (v2)"
    echo ""
    echo "--- cgroup v1 ---"
    echo -n "pids.max: "; cat /sys/fs/cgroup/pids/pids.max 2>/dev/null || echo "not available (v1)"
    echo -n "pids.current: "; cat /sys/fs/cgroup/pids/pids.current 2>/dev/null || echo "not available (v1)"
  ' > "$DUMP_DIR/system/${pod}_pids.txt" 2>&1 || true

  # System overview (meminfo, load average, uptime)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- bash -c '
    echo "=== uptime ==="
    uptime 2>/dev/null || echo "not available"
    echo ""
    echo "=== /proc/meminfo (summary) ==="
    head -10 /proc/meminfo 2>/dev/null || echo "not available"
    echo ""
    echo "=== /proc/cpuinfo (count + model) ==="
    echo -n "processor count: "; grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "unknown"
    grep "model name" /proc/cpuinfo 2>/dev/null | head -1 || echo "model unknown"
  ' > "$DUMP_DIR/system/${pod}_system-overview.txt" 2>&1 || true

  # Resource limits (ulimits — open files, stack size, core dumps)
  kubectl exec -n $SLURM_NS $pod -c slurmd -- bash -c '
    echo "=== ulimit -a ==="
    ulimit -a 2>/dev/null || echo "not available"
    echo ""
    echo "=== core dump pattern ==="
    cat /proc/sys/kernel/core_pattern 2>/dev/null || echo "not available"
    echo ""
    echo "=== ptrace scope ==="
    cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo "not available"
  ' > "$DUMP_DIR/system/${pod}_ulimits.txt" 2>&1 || true
done
```

## Step 7: Supporting Services  *(cluster-infra)*

Every command gets `2>&1 || true`:

```bash
# cert-manager (eviction by lock taint causes cascading failures)
kubectl get pods -n cert-manager -o wide > "$DUMP_DIR/services/cert-manager-pods.txt" 2>&1 || true
kubectl get certificates -A > "$DUMP_DIR/services/certificates.txt" 2>&1 || true
kubectl get certificaterequests -A > "$DUMP_DIR/services/certificate-requests.txt" 2>&1 || true

# MOCO / MySQL (Slurm accounting backend)
kubectl get pods -n moco-system -o wide > "$DUMP_DIR/services/moco-pods.txt" 2>&1 || true
kubectl get mysqlclusters -A -o yaml > "$DUMP_DIR/services/mysql-clusters.yaml" 2>&1 || true
kubectl get pods -n $SLURM_NS -l app.kubernetes.io/created-by=moco -o wide > "$DUMP_DIR/services/mysql-pods-slurm.txt" 2>&1 || true

# NFS server
kubectl get pods -n $SLURM_NS -l app=nfs-server -o wide > "$DUMP_DIR/services/nfs-pods.txt" 2>&1 || true

# OpenLDAP
kubectl get pods -n $SLURM_NS -l app=openldap -o wide > "$DUMP_DIR/services/openldap-pods.txt" 2>&1 || true

# kube-system (connectivity agents, DNS, NVIDIA device plugin)
kubectl get pods -n kube-system -o wide > "$DUMP_DIR/services/kube-system-pods.txt" 2>&1 || true

# Monitoring namespace
kubectl get pods -n $MONITORING_NS -o wide > "$DUMP_DIR/services/monitoring-pods.txt" 2>&1 || true
```

## Step 8: Network and DNS  *(slurm-state)*

If `LOGIN_POD` is available, run these (each with `|| true`):

```bash
if [ -n "$LOGIN_POD" ]; then
  kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- nslookup kubernetes.default > "$DUMP_DIR/network/dns-test.txt" 2>&1 || true
  kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- nslookup slurm-controller-0.slurm-controller.$SLURM_NS.svc.cluster.local > "$DUMP_DIR/network/controller-dns.txt" 2>&1 || true
  kubectl exec -n $SLURM_NS $LOGIN_POD -c sshd -- echo "exec connectivity OK" > "$DUMP_DIR/network/exec-test.txt" 2>&1 || true
else
  for f in dns-test controller-dns exec-test; do
    echo "SKIPPED: no login pod found" > "$DUMP_DIR/network/${f}.txt"
  done
fi
```

Then always:

```bash
kubectl get svc -n $SLURM_NS -o wide > "$DUMP_DIR/network/slurm-services.txt" 2>&1 || true
kubectl get svc -n $SUNK_NS -o wide > "$DUMP_DIR/network/sunk-services.txt" 2>&1 || true
kubectl get networkpolicies -A > "$DUMP_DIR/network/network-policies.txt" 2>&1 || true
```

## Step 9: Syncer Metrics Snapshot  *(sunk-operator)*

The syncer exposes Slurm cluster metrics on port 8080. The syncer pod may be in the Slurm or SUNK namespace depending on the deployment:

```bash
SYNCER_POD=$(kubectl get pods -n $SLURM_NS --no-headers -l app.kubernetes.io/name=sunk-syncer -o custom-columns=':metadata.name' 2>/dev/null | head -1)
SYNCER_NS=$SLURM_NS
if [ -z "$SYNCER_POD" ]; then
  SYNCER_POD=$(kubectl get pods -n $SUNK_NS --no-headers 2>/dev/null | grep syncer | awk '{print $1}' | head -1 || true)
  SYNCER_NS=$SUNK_NS
fi

if [ -n "$SYNCER_POD" ]; then
  SYNCER_CONTAINER=$(kubectl get pod -n $SYNCER_NS "$SYNCER_POD" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || echo "syncer")
  kubectl exec -n $SYNCER_NS $SYNCER_POD -c "$SYNCER_CONTAINER" -- wget -qO- http://localhost:8080/metrics 2>/dev/null | grep ^slurm_ > "$DUMP_DIR/metrics/syncer-slurm-metrics.txt" 2>&1 || true
else
  echo "SKIPPED: no syncer pod found" > "$DUMP_DIR/metrics/syncer-slurm-metrics.txt"
fi
```

## Step 10: Summary and Analysis

After all collection steps, produce a summary. Read back key files and generate `$DUMP_DIR/SUMMARY.txt` containing:

1. **Dump location**: Full path to `$DUMP_DIR` and the tarball that will be created in Step 11
2. **Cluster identity**: kubeconfig context, cluster name, server endpoint (from `$DUMP_DIR/cluster/context.txt`)
3. **Cluster info**: Kubernetes version, node count, Helm chart versions (using discovered release names)
4. **Pod health per namespace**: For each of `$SUNK_NS`, `$SLURM_NS`, `kube-system`, `cert-manager`, `moco-system`, `$MONITORING_NS` — count total pods, count unhealthy, list unhealthy pod names and statuses
5. **Slurm node states**: From sinfo — how many idle, alloc, drain, down, INVALID_REG
6. **Lock taint**: Which nodes have `sunk.coreweave.com/lock` tainted
7. **GPU status**: Number of GPU pods, any nvidia-smi errors, any Xid errors found in dmesg
8. **Cgroup/system summary**: cgroup version (v1 or v2), any OOM events, any CPU throttling
9. **Skipped sections**: List anything that was skipped and why
10. **Problems detected**: Flag anything that looks wrong

Present the summary to the user directly in conversation AND save it to `$DUMP_DIR/SUMMARY.txt`.

## Step 11: Package and Deliver

### Redact credentials

Before packaging, scrub values that look like credentials from Helm values and other captured config files:

```bash
find "$DUMP_DIR" -type f \( -name '*.yaml' -o -name '*.txt' -o -name '*.log' \) -exec \
  sed -i -E 's/(password|secret|token|key|credential|client_secret|bind_pw|jwt)(["\x27]?\s*[:=]\s*)[^ \t"]+/\1\2REDACTED/gi' {} + 2>/dev/null || true
```

This catches most `key: value` and `KEY=value` patterns. It is intentionally broad — a false positive (redacting a non-secret) is harmless, but a missed credential in a shared tarball is not.

### Create the tarball

```bash
TARBALL="${DUMP_DIR}.tar.gz"
tar czf "$TARBALL" -C "$(dirname "$DUMP_DIR")" "$(basename "$DUMP_DIR")" 2>&1 || true
echo "Tarball: $TARBALL ($(du -h "$TARBALL" 2>/dev/null | cut -f1))"
```

If tarball creation fails, report the raw directory path instead.

### Deliver

If the user specified a remote destination in Step 0, upload the tarball using the command they provided (`scp`, `aws s3 cp`, `gcloud storage cp`, etc.). Otherwise the local tarball is the deliverable.

**Privacy reminder**: The tarball may still contain hostnames, pod names, user lists, and application-level log messages. See [references/privacy-notes.md](references/privacy-notes.md). Advise the user to review the dump before sharing externally.

Report: tarball path, size, upload status (if applicable), and that it can be sent directly to the SUNK support team.

## Interpreting Results

After producing the dump, read [references/interpreting-results.md](references/interpreting-results.md) for diagnostic patterns covering failure cascades, Slurm node states, drain reasons, GPU health, cgroup issues, CRD health, and storage.

## Privacy Notes

See [references/privacy-notes.md](references/privacy-notes.md). Advise the user to review the tarball before sharing if their cluster has sensitive configuration.
