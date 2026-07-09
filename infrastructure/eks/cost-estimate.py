#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

"""Cost estimator for SUNK-on-EKS deployments.

Reads an eksctl cluster-config.yaml and a Slurm values.yaml and prints a per-component
daily cost breakdown. Warns if the daily total exceeds the budget ceiling.

Usage:
    python3 cost-estimate.py \
        --cluster-config infrastructure/eks/cluster-config.yaml \
        --slurm-values helm-values/eks/slurm-values.yaml \
        [--region us-east-1] [--spot|--on-demand] [--budget 50]

Exits non-zero if over budget.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml  # PyYAML
except ImportError:
    sys.stderr.write("ERROR: PyYAML required. Install: pip install pyyaml\n")
    sys.exit(2)


# Hardcoded on-demand hourly pricing (as of 2026-04). us-east-1 is the
# anchor; other regions inherit unless a per-region override exists.
# For instance types missing in a region, `price()` falls back to us-east-1
# so we only enumerate known-different regions.
EC2_HOURLY = {
    "us-east-1": {
        "t3.large": 0.0832,
        "t3.xlarge": 0.1664,
        "m5.large": 0.0960,
        "m5.xlarge": 0.1920,
        "m5.2xlarge": 0.3840,
        "m7i-flex.large": 0.0912,
        "m7i.large": 0.1008,
        "g5.xlarge": 1.006,
        "g5.2xlarge": 1.212,
        "g6.xlarge": 0.8052,
        "g6.2xlarge": 0.9776,
        "p4de.24xlarge": 40.9656,
        "p5.48xlarge": 98.32,
    },
    # us-east-2 is the primary GPU-quota fallback region (see create-cluster.sh
    # cross-region snapshot). Prices match us-east-1 for the instance types we
    # ship; listed explicitly so the estimator does not warn + fall back to $1.
    "us-east-2": {
        "m5.large": 0.0960,
        "m5.xlarge": 0.1920,
        "m5.2xlarge": 0.3840,
        "g5.xlarge": 1.006,
        "g6.xlarge": 0.8052,
        "g6.2xlarge": 0.9776,
    },
    # us-west-2 and eu-west-1 pricing matches us-east-1 for these SKUs; if
    # a price drifts, override it here.
    "us-west-2": {},
    "eu-west-1": {},
}

# Spot discount (typical; actual varies by AZ + time)
SPOT_DISCOUNT = {
    "m5.large": 0.30,
    "m5.xlarge": 0.30,
    "m5.2xlarge": 0.35,
    "g5.xlarge": 0.35,  # A10G spot often ~35% of on-demand
    "g6.xlarge": 0.40,
    "p4de.24xlarge": 0.40,
    "p5.48xlarge": 0.50,
}

# Storage (per GiB-month)
STORAGE_MONTHLY = {
    "gp3": 0.08,
    "gp2": 0.10,
    "efs-standard": 0.30,
    "efs-ia": 0.025,
}

# Fixed hourly costs
NLB_HOURLY = 0.0225
NLB_LCU_HOURLY = 0.008  # per LCU, small for SUNK
NAT_GATEWAY_HOURLY = 0.045
EKS_CONTROL_PLANE_HOURLY = 0.10  # managed cluster fee

HOURS_PER_DAY = 24
HOURS_PER_MONTH = 730


def load_yaml(path: Path) -> dict:
    with path.open() as f:
        return yaml.safe_load(f)


def price(instance: str, region: str, spot: bool) -> float:
    # Try the exact region first, then fall back to us-east-1 (which has the
    # full price table). Only warn if even that fails.
    base = EC2_HOURLY.get(region, {}).get(instance)
    if base is None and region != "us-east-1":
        base = EC2_HOURLY.get("us-east-1", {}).get(instance)
    if base is None:
        sys.stderr.write(f"WARN: no price for {instance} in {region}; assuming $1/hr\n")
        base = 1.0
    if spot:
        disc = SPOT_DISCOUNT.get(instance, 0.40)
        return base * disc
    return base


def estimate_nodegroups(ng: list[dict], region: str, force_spot: bool | None) -> list[dict]:
    rows = []
    for n in ng or []:
        name = n.get("name", "?")
        inst = n.get("instanceType", "?")
        desired = int(n.get("desiredCapacity", n.get("minSize", 0)))
        max_ = int(n.get("maxSize", desired))
        ng_spot = n.get("spot", False)
        use_spot = force_spot if force_spot is not None else ng_spot
        hourly = price(inst, region, use_spot)
        rows.append({
            "kind": "nodegroup",
            "name": name,
            "instance": inst,
            "qty_min": desired,
            "qty_max": max_,
            "hourly_per_node": hourly,
            "spot": use_spot,
            "daily_min": hourly * desired * HOURS_PER_DAY,
            "daily_max": hourly * max_ * HOURS_PER_DAY,
            "volume_gib": n.get("volumeSize", 0),
            "volume_type": n.get("volumeType", "gp3"),
        })
    return rows


def estimate_fixed() -> list[dict]:
    return [
        {"kind": "eks-control-plane", "name": "cluster", "hourly": EKS_CONTROL_PLANE_HOURLY,
         "daily": EKS_CONTROL_PLANE_HOURLY * HOURS_PER_DAY, "note": "EKS managed control plane"},
        {"kind": "nat-gateway", "name": "nat", "hourly": NAT_GATEWAY_HOURLY,
         "daily": NAT_GATEWAY_HOURLY * HOURS_PER_DAY, "note": "eksctl default NAT gateway (1 AZ)"},
        {"kind": "nlb", "name": "slurm-login", "hourly": NLB_HOURLY,
         "daily": NLB_HOURLY * HOURS_PER_DAY, "note": "Login service LoadBalancer"},
    ]


def estimate_volumes(nodegroups: list[dict]) -> list[dict]:
    rows = []
    for ng in nodegroups:
        vol = ng.get("volume_gib", 0)
        if vol and ng["qty_min"] > 0:
            vol_type = ng.get("volume_type", "gp3")
            rate = STORAGE_MONTHLY.get(vol_type, 0.10)
            monthly = vol * ng["qty_min"] * rate
            rows.append({
                "kind": "ebs",
                "name": f"{ng['name']} ({ng['qty_min']}x {vol}GiB {vol_type})",
                "daily": monthly / 30,
                "note": f"${rate}/GiB-mo",
            })
    # SUNK PVCs (rough estimate from values: 20Gi state + 20Gi MySQL + 5Gi grafana + 20Gi prom)
    rows.append({
        "kind": "ebs", "name": "sunk/slurm PVCs (state + MySQL + Prom + Grafana)",
        "daily": (20 + 20 + 20 + 5) * STORAGE_MONTHLY["gp3"] / 30,
        "note": "assumes budget profile",
    })
    return rows


def fmt_row(r: dict) -> str:
    name = r.get("name", "?")
    kind = r.get("kind", "?")
    if "daily_min" in r:
        return f"{kind:18s} {name:40s} {r['daily_min']:7.2f}  {r['daily_max']:7.2f}  {'spot' if r.get('spot') else 'ondemand'}"
    return f"{kind:18s} {name:40s} {r['daily']:7.2f}                 {r.get('note','')}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cluster-config", type=Path, required=True)
    ap.add_argument("--slurm-values", type=Path, default=None,
                    help="Optional: read compute nodesets for additional context")
    ap.add_argument("--region", default="us-east-1")
    grp = ap.add_mutually_exclusive_group()
    grp.add_argument("--spot", action="store_true", help="Assume all nodegroups spot")
    grp.add_argument("--on-demand", action="store_true", help="Assume all nodegroups on-demand")
    ap.add_argument("--budget", type=float, default=50.0, help="Daily budget ceiling (default $50)")
    ap.add_argument("--json", action="store_true", help="Emit JSON")
    args = ap.parse_args()

    force_spot = True if args.spot else (False if args.on_demand else None)

    cfg = load_yaml(args.cluster_config)
    # eksctl ClusterConfig stores node groups under managedNodeGroups or nodeGroups
    ng = cfg.get("managedNodeGroups") or cfg.get("nodeGroups") or []
    ng_rows = estimate_nodegroups(ng, args.region, force_spot)
    fixed_rows = estimate_fixed()
    vol_rows = estimate_volumes(ng_rows)

    all_rows = ng_rows + fixed_rows + vol_rows
    total_min = sum(r.get("daily_min", r.get("daily", 0)) for r in all_rows)
    total_max = sum(r.get("daily_max", r.get("daily", 0)) for r in all_rows)

    if args.json:
        print(json.dumps({"rows": all_rows, "daily_min": total_min,
                          "daily_max": total_max, "budget": args.budget}, indent=2))
    else:
        print(f"{'KIND':18s} {'NAME':40s} {'$/day min':>9s}  {'$/day max':>9s}  NOTE")
        print("-" * 100)
        for r in all_rows:
            print(fmt_row(r))
        print("-" * 100)
        print(f"{'TOTAL':18s} {'':40s} {total_min:7.2f}  {total_max:7.2f}")
        print()
        status = "OK" if total_max <= args.budget else "OVER"
        print(f"Budget ceiling: ${args.budget:.2f}/day")
        print(f"Daily cost (max all nodes running): ${total_max:.2f}  [{status}]")
        print(f"Daily cost (min, scale-to-zero): ${total_min:.2f}")

    return 0 if total_max <= args.budget else 1


if __name__ == "__main__":
    sys.exit(main())
