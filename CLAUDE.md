# sunk-anywhere — local work rules

## Critical rules

1. **Do not push git commits to remote.** All work stays local until the user reviews.
2. **Do not create AWS resources without explicit user approval.** Most work in this repo produces files (YAML, scripts, docs); anything that calls `aws`, `eksctl`, or `kubectl apply` against a real cluster needs an in-the-moment green light.
3. **Respect budget ceiling: $50/day combined CPU + GPU.** Budget profile: 2x m5.large control plane + 1x g5.xlarge (A10G) or g6.xlarge (L4) for GPU. Default should be `gpu-workers.replicas: 0` so customers opt in.
4. **Conventions contract:** `docs/eks/conventions.md` is the source of truth for labels, nodegroup names, storageclass names, and namespace layout. Every script, skill, and values file must match it; extensions to conventions go in as a PR against that doc first.

## Repo state

Running `git status` shows the working tree. Do not push.
