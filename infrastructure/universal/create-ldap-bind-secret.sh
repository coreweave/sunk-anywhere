#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# create-ldap-bind-secret.sh — create/rotate the LDAP bind-password Secret
# that configure-sunk-authentik-sssd references.
#
# Idempotent: deletes the existing Secret (if any) and recreates, so the
# same command handles first-install and password rotation.
#
# Usage:
#   create-ldap-bind-secret.sh --password <pw> [--namespace NS] [--name NAME]

set -euo pipefail

NS="tenant-slurm"
NAME="slurm-bind-authtok"
PASSWORD=""
KUBECONFIG_FLAG=""
CONTEXT_FLAG=""

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") --password PW [--namespace NS] [--name NAME] [--kubeconfig FILE] [--context NAME]

Creates (or replaces) a Kubernetes Secret holding the LDAP bind password
that sssd uses to authenticate to an authentik outpost.

Flags:
  --password PW        (required) The bind password.
  --namespace NS       default tenant-slurm
  --name NAME          default slurm-bind-authtok
  --kubeconfig FILE    pass --kubeconfig=FILE to kubectl
  --context NAME       pass --context=NAME to kubectl
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --password)   PASSWORD="$2"; shift 2 ;;
        --namespace)  NS="$2"; shift 2 ;;
        --name)       NAME="$2"; shift 2 ;;
        --kubeconfig) KUBECONFIG_FLAG="--kubeconfig=$2"; shift 2 ;;
        --context)    CONTEXT_FLAG="--context=$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

[[ -n "$PASSWORD" ]] || die "--password is required"

kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG get ns "$NS" >/dev/null 2>&1 \
    || die "namespace $NS not found"

# Delete existing, if any, so we don't hit "AlreadyExists".
kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG delete secret -n "$NS" "$NAME" \
    --ignore-not-found=true >/dev/null

kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG create secret generic \
    -n "$NS" "$NAME" \
    --from-literal=bind-password="$PASSWORD"

echo "OK: secret $NS/$NAME created with key 'bind-password'"
echo "Reference in your values overlay as:"
echo "    existingSecret: $NAME"
