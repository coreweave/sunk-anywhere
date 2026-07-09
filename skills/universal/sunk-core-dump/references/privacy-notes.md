# Privacy Notes

**Review the dump before sharing externally.** Automatic credential redaction runs before the tarball is created (Step 11), but it is pattern-based and may not catch every secret format.

The dump does **NOT** capture:
- Secret resource values (only secret names are listed via `kubectl get secrets`)

It **DOES** capture (and these may contain sensitive data):
- **Helm deployed values** (`helm get values`) — may contain database passwords, LDAP bind credentials, JWT keys, registry auth tokens, or other user-supplied secrets. A redaction pass strips common patterns, but custom key names may survive.
- **Pod logs** — may contain application-level error messages that include credentials, tokens, or internal URLs
- **User identity data** — `getent passwd` output and `sacctmgr show user` list real usernames
- **Slurm configuration** (slurm.conf, gres.conf) — may contain hostnames, partition names, and scheduling parameters
- **Node names and labels** — reveals cluster topology and naming conventions
- **System info** (meminfo, cpuinfo, cgroup limits, ulimits) from compute pods

Advise the user to review the tarball before sharing if their cluster has sensitive configuration.
