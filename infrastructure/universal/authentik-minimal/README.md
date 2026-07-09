# authentik-minimal

Throwaway single-replica authentik deployment for validating the
`configure-sunk-authentik-sssd` skill. **Not for production.**

## When to use this

You want to prove the authentik-path SKILL works end-to-end on a cheap
test cluster (2-node `e2-standard-4` GKE or `m5.large` EKS, within the
$50/day budget), and you don't already have authentik running somewhere.

If you already run authentik, ignore this directory — point the skill
at your existing outpost.

## What's in here

| File                    | What it does                                                                                          |
|-------------------------|-------------------------------------------------------------------------------------------------------|
| `values.yaml`           | Helm values sized for ~2 GiB RAM total (server + worker + embedded Postgres + Redis).                |
| `install.sh`            | `helm upgrade --install` against the authentik public helm repo. Prints a bootstrap token.           |
| `seed-test-users.sh`    | Creates `test_user_1` + `test_user_2` via the authentik REST API with `uidNumber`/`gidNumber`/`sshPublicKey` attributes and `slurm-users` group membership. Generates throwaway ed25519 keys in `./test-keys/`. |
| `teardown.sh`           | `helm uninstall` + namespace delete + wipes generated test keys.                                      |

## Production difference

Customer-production authentik (e.g. the `charts/authentik-ha` in
`solutions-architecture-services`) wants:
- Multiple server replicas behind a proper Service
- External PostgreSQL (not embedded)
- Redis cluster (not single-replica)
- 4-8 GiB RAM per server replica, 2+ GiB per worker
- Persistent TLS certs, DNS, ingress, SSO, RBAC

None of that fits our budget or is needed to validate the skill. This
profile accepts HA/perf compromises explicitly.

## Quickstart

```bash
# 1. Install.
./install.sh
# -> Prints akadmin password + bootstrap token. Save them.

# 2. Port-forward to the admin UI and create the LDAP outpost via GUI.
kubectl port-forward -n authentik svc/authentik-server 9000:80
open http://localhost:9000
# Login -> Directory -> Federation & Social -> LDAP Outpost
# Accept defaults (DC=ldap,DC=goauthentik,DC=io search base).

# 3. Wait for the outpost pod.
kubectl wait --for=condition=ready pod \
    -n authentik -l goauthentik.io/component=ldap --timeout=3m

# 4. Seed test users via the API.
AUTHENTIK_TOKEN=<bootstrap-token-from-step-1> \
AUTHENTIK_URL=http://localhost:9000 \
    ./seed-test-users.sh

# 5. Run the configure-sunk-authentik-sssd skill pointing at the
#    in-cluster outpost URI. See the skill doc for the full flow.

# 6. When done.
./teardown.sh
```

## Known caveats

- The `bootstrap_password` + `bootstrap_token` in `install.sh` are
  generated with `openssl rand` each invocation. Re-installing replaces
  them; any existing clients holding the old token break.
- Embedded Postgres uses a PVC sized 2 GiB. Restarting the pod loses
  data if the storage class isn't persistent in your cluster.
- The LDAP outpost on authentik needs a service account (bind DN) for
  sssd to authenticate with. Create it in the authentik admin UI
  (Directory -> Users) and grant LDAP read access before running the
  sssd skill.
- `AUTHENTIK_URL=http://localhost:9000` assumes you're port-forwarded.
  The skill's values overlay points sssd at the **in-cluster** outpost
  URI (`ldap://authentik-outpost-ldap-outpost.authentik.svc.cluster.local`),
  not the port-forwarded URL.
