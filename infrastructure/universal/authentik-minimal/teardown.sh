#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# teardown.sh — remove the authentik-minimal validation deployment.
#
# Does NOT touch the SUNK cluster. Run this when you're done validating
# the configure-sunk-authentik-sssd skill.

set -euo pipefail

NS="${NS:-authentik}"
RELEASE="${RELEASE:-authentik}"
KEY_DIR="${KEY_DIR:-$(dirname "$0")/test-keys}"

info() { echo "==> $*"; }

command -v helm >/dev/null    || { echo "helm not on PATH" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not on PATH" >&2; exit 1; }

info "uninstalling release $RELEASE in $NS"
helm uninstall "$RELEASE" -n "$NS" --ignore-not-found || true

info "deleting namespace $NS"
kubectl delete namespace "$NS" --ignore-not-found --wait=false || true

if [[ -d "$KEY_DIR" ]]; then
    info "removing generated test keys in $KEY_DIR"
    rm -rf "$KEY_DIR"
fi

echo "OK: authentik-minimal torn down"
