# Gemini Style Guide for SUNK Anywhere

Read `AGENTS.md` in the repository root for full project context, deployment flow, and directory layout.

## Guidelines

- Always ask the user which cloud provider they are targeting before selecting a skill or running commands.
- Never create clusters, install Helm charts, or provision infrastructure without explicit user confirmation. These actions create billable cloud resources.
- Use the provider-specific skills in `skills/<provider>/` for deployment and patching.
- Use the universal skills in `skills/universal/` for post-deployment tasks (monitoring, auth, upgrades, SkyPilot).
- Helm values are layered: `helm-values/base/` contains universal defaults, `helm-values/<provider>/` contains overrides. Apply both.
- GKE and EKS are validated providers. Generic is in validation and may need provider-specific adaptation.
- When troubleshooting, start with `docs/universal/troubleshooting.md`, then check provider-specific docs.
