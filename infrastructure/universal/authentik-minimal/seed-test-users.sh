#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# seed-test-users.sh — create two POSIX users in authentik via the API.
#
# Uses the authentik REST API (core/users/) to create:
#   test_user_1  uid=10001 gid=10001
#   test_user_2  uid=10002 gid=10002
# Each gets an sshPublicKey attribute and group membership in slurm-users.
#
# Consumed by configure-sunk-authentik-sssd validation. The public keys
# emitted here are throwaway ed25519 keys generated on the fly; the
# corresponding private keys are dropped in ./test-keys/ for SSH tests.

set -euo pipefail

AUTHENTIK_URL="${AUTHENTIK_URL:-http://localhost:9000}"
AUTHENTIK_TOKEN="${AUTHENTIK_TOKEN:-}"
KEY_DIR="${KEY_DIR:-$(dirname "$0")/test-keys}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v curl >/dev/null    || die "curl not on PATH"
command -v jq   >/dev/null    || die "jq not on PATH"
command -v ssh-keygen >/dev/null || die "ssh-keygen not on PATH"

[[ -n "$AUTHENTIK_TOKEN" ]] || die "AUTHENTIK_TOKEN required (set to the bootstrap token from install.sh)"

mkdir -p "$KEY_DIR"

auth() { curl -sS -H "Authorization: Bearer $AUTHENTIK_TOKEN" -H "Content-Type: application/json" "$@"; }

# Sanity ping.
info "verifying authentik is reachable at $AUTHENTIK_URL"
auth "$AUTHENTIK_URL/api/v3/admin/version/" >/dev/null || die "cannot reach authentik — check port-forward and token"

# Ensure the slurm-users group exists.
info "ensuring slurm-users group exists"
GROUP_PK=$(auth "$AUTHENTIK_URL/api/v3/core/groups/?name=slurm-users" | jq -r '.results[0].pk // empty')
if [[ -z "$GROUP_PK" ]]; then
    GROUP_PK=$(auth -X POST "$AUTHENTIK_URL/api/v3/core/groups/" \
        -d '{"name":"slurm-users","is_superuser":false,"attributes":{"gidNumber":10000}}' \
        | jq -r '.pk')
    info "  created slurm-users group (pk=$GROUP_PK)"
else
    info "  slurm-users group already exists (pk=$GROUP_PK)"
fi

create_user() {
    local uname="$1" uid="$2" gid="$3"
    local email="${uname}@example.com"
    local keyfile="$KEY_DIR/${uname}_ed25519"

    # Generate a throwaway key if not already there.
    if [[ ! -f "$keyfile" ]]; then
        ssh-keygen -t ed25519 -N "" -C "$email" -f "$keyfile" >/dev/null
        info "  generated $keyfile"
    fi
    local pubkey
    pubkey="$(cat "${keyfile}.pub")"

    # Does the user exist?
    local pk
    pk=$(auth "$AUTHENTIK_URL/api/v3/core/users/?username=$uname" | jq -r '.results[0].pk // empty')

    if [[ -z "$pk" ]]; then
        info "  creating user $uname (uid=$uid gid=$gid)"
        pk=$(auth -X POST "$AUTHENTIK_URL/api/v3/core/users/" \
            -d "$(jq -n --arg u "$uname" --arg e "$email" --arg k "$pubkey" \
                     --argjson uid "$uid" --argjson gid "$gid" \
                     --argjson group "$GROUP_PK" \
                     '{username:$u,name:$u,email:$e,is_active:true,
                       attributes:{uidNumber:$uid,gidNumber:$gid,
                                   loginShell:"/bin/bash",
                                   homeDirectory:"/home/\($u)",
                                   sshPublicKey:$k},
                       groups:[$group]}')" \
            | jq -r '.pk')
    else
        info "  user $uname already exists (pk=$pk), updating attributes"
        auth -X PATCH "$AUTHENTIK_URL/api/v3/core/users/$pk/" \
            -d "$(jq -n --arg k "$pubkey" --argjson uid "$uid" --argjson gid "$gid" --arg u "$uname" \
                     '{attributes:{uidNumber:$uid,gidNumber:$gid,
                                   loginShell:"/bin/bash",
                                   homeDirectory:"/home/\($u)",
                                   sshPublicKey:$k}}')" >/dev/null
    fi
}

create_user test_user_1 10001 10001
create_user test_user_2 10002 10002

cat <<EOF

OK: seeded test_user_1 + test_user_2

Private keys for SSH tests are in: $KEY_DIR
    $KEY_DIR/test_user_1_ed25519
    $KEY_DIR/test_user_2_ed25519

Verify over LDAP (replace bind DN + password with yours):
    kubectl exec -n tenant-slurm slurm-login-0 -c sssd -- \\
        ldapsearch -H ldap://authentik-outpost-ldap-outpost.authentik.svc.cluster.local \\
        -D cn=<ldapsvc>,DC=ldap,DC=goauthentik,DC=io -w <pw> \\
        -b DC=ldap,DC=goauthentik,DC=io "(cn=test_user_1)" uidNumber sshPublicKey
EOF
