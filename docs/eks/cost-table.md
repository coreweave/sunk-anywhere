# EKS Cost Table

Spend estimates for SUNK on EKS at the budget profile defined in [conventions.md](conventions.md). All prices are `us-east-1` on-demand unless marked otherwise; regional variance is typically 5-20%.

---

## Budget profile (default, sub-$50/day)

| Component | $/day | Notes |
|-----------|-------|-------|
| EKS managed control plane | $2.40 | Flat $0.10/hr, no scale-to-zero |
| 2x m5.large control plane (on-demand) | $4.61 | `cpu-control` nodegroup, always on |
| 1x m5.large CPU worker (spot, always-on by default) | $0.79 | `cpu-workers` desiredCapacity=1 so a fresh deploy runs jobs out of the box. Scale to 0 with `eksctl scale nodegroup --nodes=0` when idle. |
| NAT Gateway (1 AZ) | $1.08 | Fixed hourly + data processing |
| NLB (login service) | $0.54 | $0.0225/hr + LCU, small for SUNK |
| EBS gp3 (SUNK + MySQL + Grafana + Prometheus PVCs) | $0.50 | ~65 GiB total at $0.08/GB-mo |
| 0-1x g5.xlarge GPU (scale-to-zero, spot) | $0 to $14 | $0.30-0.35/hr spot |
| 0-1x g5.xlarge GPU (scale-to-zero, on-demand) | $0 to $24 | $1.006/hr on-demand |
| +1 m5.large CPU worker (spot, opt-in) | $0 to $0.80 | Bump `replicas` + `maxSize` for multi-node examples |
| **Total (idle, 1 CPU worker, no GPU)** | **~$9.90** | Default post-deploy state; sinfo shows 1 idle worker |
| **Total (1 GPU, 24h spot)** | **~$17** | Budget-friendly interactive dev |
| **Total (1 GPU, 24h on-demand)** | **~$33** | Safer for long-running jobs |

The cost estimator (`infrastructure/eks/cost-estimate.py`) enforces the $50/day ceiling based on `maxSize` of every nodegroup. Exits non-zero if over budget.

---

## Production profile (opt-in, blows the budget)

| Instance | GPU | $/hr | $/day (single node) | Use when |
|----------|-----|------|---------------------|----------|
| `g5.2xlarge` | 1x A10G 24GB | $1.212 | ~$29 | Soft upgrade; more CPU/RAM per A10G |
| `p4de.24xlarge` | 8x A100 80GB | $32.77 | **~$786** | Real multi-GPU training |
| `p5.48xlarge` | 8x H100 80GB | $98.32 | **~$2,360** | Frontier-scale training |

**Warning:** a single p4de node running 24/7 costs ~$800/day. A single p5 node is ~$2,360/day. The budget ceiling in `cost-estimate.py` blocks these by default; override with `--budget 1000` or higher only after confirming the spend with a stakeholder. Always prefer spot + scale-to-zero for production GPUs when the workload tolerates preemption.

---

## Spot vs on-demand

Spot instances are typically 30-65% of on-demand price in `us-east-1`. SUNK tolerates spot for compute (`cpu-workers`, `gpu-workers`) because Slurm re-queues jobs when a node is preempted. The `cpu-control` nodegroup must stay on-demand: losing the controller mid-job corrupts state.

| Instance | On-demand $/hr | Typical spot $/hr | Spot discount |
|----------|----------------|-------------------|---------------|
| `m5.large` | $0.096 | ~$0.029-0.034 | ~65% off |
| `g5.xlarge` | $1.006 | ~$0.30-0.40 | ~60-70% off |
| `g6.xlarge` | $0.805 | ~$0.32 | ~60% off |
| `p4de.24xlarge` | $32.77 | ~$13-20 | ~40-60% off |

Spot availability varies by AZ and time. `eksctl create nodegroup --spot` picks the cheapest pool available; fall back to on-demand if a request stays pending > 5 minutes.

---

## Using the cost estimator

```bash
python3 infrastructure/eks/cost-estimate.py \
  --cluster-config infrastructure/eks/cluster-config.yaml \
  --slurm-values helm-values/eks/slurm-values.yaml \
  --region us-east-1
```

Flags:

- `--spot` / `--on-demand`: force all nodegroups to spot or on-demand (overrides per-nodegroup `spot:` setting).
- `--budget <N>`: daily ceiling in USD (default 50). Non-zero exit when exceeded.
- `--json`: emit machine-readable output.

Example output excerpt:

```
KIND               NAME                                     $/day min  $/day max  NOTE
----------------------------------------------------------------------------------------------------
nodegroup          cpu-control                                 4.61       4.61    ondemand
nodegroup          cpu-workers                                 0.00       1.58    spot
nodegroup          gpu-workers                                 0.00      14.17    spot
eks-control-plane  cluster                                     2.40                EKS managed control plane
nat-gateway        nat                                         1.08                eksctl default NAT gateway (1 AZ)
nlb                slurm-login                                 0.54                Login service LoadBalancer
ebs                sunk/slurm PVCs (state + MySQL + Prom + Grafana)   0.17         assumes budget profile
----------------------------------------------------------------------------------------------------
TOTAL                                                          8.80      22.55
Daily cost (max all nodes running): $22.55  [OK]
Daily cost (min, scale-to-zero): $8.80
```

---

## (Optional) AWS Budget alerts

Create a $50/day budget alert that emails at 80% and 100% of the threshold:

```bash
aws budgets create-budget \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget '{
    "BudgetName": "sunk-anywhere-daily",
    "BudgetLimit": {"Amount": "50", "Unit": "USD"},
    "TimeUnit": "DAILY",
    "BudgetType": "COST",
    "CostFilters": {"TagKeyValue": ["user:ManagedBy$sunk-anywhere"]}
  }' \
  --notifications-with-subscribers '[{
    "Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 80},
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "you@example.com"}]
  }]' \
  --profile your-profile
```

The budget filter relies on the `ManagedBy=sunk-anywhere` tag that `create-cluster.sh` and `setup-efs.sh` apply to every resource. Tag-based filtering requires enabling user-defined cost allocation tags in the Billing console first (one-time setup, takes 24h to activate).

---

## See also

- [conventions.md](conventions.md) — budget constants table (source of truth for per-component prices)
- [deployment-guide.md](deployment-guide.md) — Step 11 wires the estimator into the deploy flow
- `infrastructure/eks/cost-estimate.py` — the estimator itself
