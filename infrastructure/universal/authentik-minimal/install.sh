#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# install.sh — deploy authentik (minimal single-replica) for validation.
#
# Ships a throwaway authentik with embedded Postgres/Redis so the
# configure-sunk-authentik-sssd skill can be validated end-to-end on a
# $50/day test cluster. Not for production.

set -euo pipefail

NS="${NS:-authentik}"
RELEASE="${RELEASE:-authentik}"
VALUES_FILE="${VALUES_FILE:-$(dirname "$0")/values.yaml}"
CHART_VERSION="${CHART_VERSION:-2024.10.5}"   # known-good pin
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD:-}"
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v helm >/dev/null || die "helm not on PATH"
command -v kubectl >/dev/null || die "kubectl not on PATH"

# Random passwords if the caller didn't provide them. Printed at the end.
if [[ -z "$BOOTSTRAP_PASSWORD" ]]; then
    BOOTSTRAP_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=')"
fi
if [[ -z "$BOOTSTRAP_TOKEN" ]]; then
    BOOTSTRAP_TOKEN="$(openssl rand -hex 24)"
fi

info "adding authentik helm repo"
helm repo add authentik https://charts.goauthentik.io >/dev/null 2>&1 || true
helm repo update authentik >/dev/null

info "creating namespace $NS (if needed)"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

info "installing authentik (chart version $CHART_VERSION)"
helm upgrade --install "$RELEASE" authentik/authentik \
    --namespace "$NS" \
    --version "$CHART_VERSION" \
    -f "$VALUES_FILE" \
    --set authentik.bootstrap_password="$BOOTSTRAP_PASSWORD" \
    --set authentik.bootstrap_token="$BOOTSTRAP_TOKEN" \
    --wait --timeout 10m

info "waiting for authentik-server to be Ready"
kubectl wait --for=condition=ready pod \
    -n "$NS" -l app.kubernetes.io/component=server \
    --timeout=5m

cat <<EOF

OK: authentik deployed in namespace '$NS'

Bootstrap credentials (SAVE THESE — only shown once):
  admin user:   akadmin
  admin pw:     $BOOTSTRAP_PASSWORD
  admin token:  $BOOTSTRAP_TOKEN

Next steps:
  1. Port-forward the server and browse the admin UI:
         kubectl port-forward -n $NS svc/authentik-server 9000:80
         open http://localhost:9000
         login: akadmin / $BOOTSTRAP_PASSWORD

  2. Create the LDAP outpost (Directory -> Federation & Social login ->
     LDAP Outpost). Give it the default search base (dc=ldap,dc=goauthentik,dc=io).
     Wait ~30 seconds for the outpost pod to spin up:
         kubectl get pod -n $NS -l goauthentik.io/component=ldap

  3. Seed test users via the API:
         AUTHENTIK_TOKEN=$BOOTSTRAP_TOKEN \\
         AUTHENTIK_URL=http://localhost:9000 \\
             ./seed-test-users.sh

  4. Run the configure-sunk-authentik-sssd skill, pointing at:
         ldapUri:   ldap://authentik-outpost-ldap-outpost.$NS.svc.cluster.local
         bindDn:    cn=\$service_account,DC=ldap,DC=goauthentik,DC=io
         searchBase: DC=ldap,DC=goauthentik,DC=io

  5. Tear down when done:
         ./teardown.sh
EOF
