# Pulling SUNK images on a non-CoreWeave cluster

## Problem

SUNK's container images are published to public GHCR. On CoreWeave Cloud the
charts pull them from CoreWeave's internal registry; on your own cluster you
point them at the public GHCR repositories instead, and on an air-gapped cluster
you mirror them into a registry your nodes can reach. This page shows how.

## Prerequisites

- A working `kubectl` context for your cluster.
- Outbound network access to `ghcr.io` from your nodes, or a private registry
  you can mirror into (see [Air-gapped clusters](#air-gapped-clusters)).
- The base values file from this repo,
  `helm-values/base/slurm-values.yaml`, which you layer under your provider
  overlay on every `helm install`.

## Use public GHCR

The base values already set the switch that selects the public registry
(`helm-values/base/slurm-values.yaml`):

```yaml
global:
  # REQUIRED: pull from public GHCR, not CoreWeave internal registry
  cks: false
```

Keep `global.cks: false`. As long as you layer the base values, no further
change is needed. The **base** Slurm images are pinned in the same file to
public GHCR repositories:

| Image repository | Used by (base defaults) | Tag |
|------------------|-------------------------|-----|
| `ghcr.io/coreweave/slurm-containers/controller` | controller (slurmctld), rest, accounting | `v25.05.3-coreweave.5-ubuntu22.04` |
| `ghcr.io/coreweave/slurm-containers/controller-extras` | login, compute (cpu/gpu workers) | `v25.05.3-coreweave.5-ubuntu22.04` |

Provider overlays can pin different or additional images (for example the EKS
GPU worker path uses a CUDA-specific compute image), so treat this table as the
base default, not the complete set. To see the exact images your configuration
references, render the chart (see [Verify it worked](#verify-it-worked)).

Because these are public, no `imagePullSecret` is required for them on a
connected cluster. Chart dependencies you install separately (MOCO, cert-manager)
pull from their own public registries and are not affected by `global.cks`.

## Verify it worked

Before installing, confirm your environment can actually pull the image:

```bash
docker pull ghcr.io/coreweave/slurm-containers/controller:v25.05.3-coreweave.5-ubuntu22.04
```

If you cannot run Docker locally, render the chart and confirm the image
references resolve to GHCR rather than an internal host:

```bash
helm template slurm <chart> \
  -f helm-values/base/slurm-values.yaml \
  -f helm-values/<provider>/slurm-values.yaml \
  | grep 'image:'
# Every line should read ghcr.io/coreweave/... ; none should point at an
# internal CoreWeave registry hostname.
```

After `helm install`, the definitive check is that no pod is stuck pulling:

```bash
kubectl get pods -n tenant-slurm
# Any ImagePullBackOff / ErrImagePull means the node could not pull the image.
kubectl describe pod -n tenant-slurm <pod> | grep -A3 Events
```

## Air-gapped clusters

If your nodes cannot reach `ghcr.io`, mirror the images into a registry they can
reach, then point the chart at it. This repo does not ship a mirroring tool; the
steps are yours to run.

1. Enumerate the images your configuration actually references (so you do not
   miss provider-specific ones), then pull and re-push each to your registry,
   preserving the tag:

   ```bash
   # List every CoreWeave image the rendered chart references:
   helm template slurm <chart> \
     -f helm-values/base/slurm-values.yaml \
     -f helm-values/<provider>/slurm-values.yaml \
     | grep -oE 'ghcr\.io/coreweave/[^"]+' | sort -u

   # Mirror each one, preserving the tag, e.g.:
   TAG=v25.05.3-coreweave.5-ubuntu22.04
   for img in controller controller-extras; do
     docker pull  ghcr.io/coreweave/slurm-containers/$img:$TAG
     docker tag   ghcr.io/coreweave/slurm-containers/$img:$TAG \
                  registry.internal.example.com/sunk/$img:$TAG
     docker push  registry.internal.example.com/sunk/$img:$TAG
   done
   ```

2. Override the image repositories in your provider overlay so every component
   points at your mirror. The components and their default repositories are in
   the table above; for example:

   ```yaml
   controller:
     image:
       repository: registry.internal.example.com/sunk/controller
   login:
     image:
       repository: registry.internal.example.com/sunk/controller-extras
   compute:
     nodes:
       cpu-workers:
         image:
           repository: registry.internal.example.com/sunk/controller-extras
       gpu-workers:
         image:
           repository: registry.internal.example.com/sunk/controller-extras
   ```

   Repeat for `rest` and `accounting` (both use `controller`).

3. If your mirror requires authentication, create an image pull secret in
   `tenant-slurm` and wire it in per the chart's image-pull-secret handling.
   Confirm the exact values key in
   [helm-values-reference.md](helm-values-reference.md) before relying on it.

## Troubleshooting

- **`ErrImagePull` / `ImagePullBackOff` on a connected cluster.** Confirm the
  node, not just your laptop, has egress to `ghcr.io:443`. Network policy or a
  private subnet without a NAT path is the usual cause.
- **Image references point at an internal CoreWeave host.** You did not layer
  the base values, or an overlay set `global.cks: true`. Re-check the
  `helm template ... | grep image:` output above.
- **Pull works for `controller` but not a dependency** (MOCO, cert-manager).
  Those are separate charts with their own images; treat their registries
  independently of `global.cks`.

## See also

- [adapting-sunk-to-your-cluster.md](adapting-sunk-to-your-cluster.md): the full list of off-CoreWeave adaptations.
- [helm-values-reference.md](helm-values-reference.md): annotated values for all charts.
- [README.md](../README.md): provider tracks and the base-plus-overlay install pattern.
