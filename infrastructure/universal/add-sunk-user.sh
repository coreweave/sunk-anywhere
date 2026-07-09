#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# add-sunk-user.sh — single-user provisioning for SUNK without LDAP/SCIM.
#
# One user per invocation. Idempotent: re-runs update the SSH key but don't
# re-add the Linux user or re-insert the Slurm association.
#
# Scope: user is created on the login pod + home dir on shared NFS +
# association in Slurm's accounting DB. Cross-pod identity on compute pods is
# NOT handled by this script (documented limitation). For that you need
# `compute.extraUsers` in your provider values (Option A in the skill) or
# `configure-sunk-authentik-sssd` for LDAP-backed identity.
#
# Usage:
#   add-sunk-user.sh add --username alice --uid 1001 --gid 1001 \
#       --email alice@example.com --ssh-key "ssh-ed25519 AAA..."
#   add-sunk-user.sh update-key --username alice --ssh-key "ssh-ed25519 BBB..."
#   add-sunk-user.sh remove --username alice --confirm
#
# See skills/universal/bootstrap-sunk-local-user/SKILL.md for the full flow.

set -euo pipefail

NS="${NS:-tenant-slurm}"
LOGIN_POD="${LOGIN_POD:-slurm-login-0}"
LOGIN_CTR="${LOGIN_CTR:-sshd}"
SLURM_ACCOUNT="${SLURM_ACCOUNT:-users}"
KUBECONFIG_FLAG=""
CONTEXT_FLAG=""

SUBCMD=""
USERNAME=""
UID_NUM=""
GID_NUM=""
EMAIL=""
SSH_KEY=""
SHELL_="/bin/bash"
HOME_=""
CONFIRM=""

die() { echo "ERROR: $*" >&2; exit 1; }
kex()  { kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG exec -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- "$@"; }
kexb() { kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG exec -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- bash -c "$1"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <subcommand> [flags]

Subcommands:
  add         Create user, drop key, add Slurm association. Idempotent.
  update-key  Rotate SSH authorized_keys for an existing user.
  remove      Disable user (preserves Slurm accounting history). Requires --confirm.

Flags:
  --username NAME      (required)
  --uid N              (required for add)
  --gid N              (required for add; defaults to same as uid)
  --email STR          (goes into GECOS; required for add)
  --ssh-key STR        Full openssh public key line (required for add + update-key)
  --shell PATH         default /bin/bash
  --home PATH          default /home/<username>
  --slurm-account NAME default "users" (auto-created if absent)
  --namespace NS       default tenant-slurm
  --login-pod POD      default slurm-login-0
  --login-ctr CTR      default sshd
  --kubeconfig FILE    pass --kubeconfig=FILE to kubectl
  --context NAME       pass --context=NAME to kubectl
  --confirm            required by the 'remove' subcommand
  -h, --help
EOF
}

parse_args() {
    [[ $# -gt 0 ]] || { usage; exit 1; }
    SUBCMD="$1"; shift
    case "$SUBCMD" in
        add|update-key|remove|-h|--help) ;;
        *) usage; die "unknown subcommand: $SUBCMD" ;;
    esac
    if [[ "$SUBCMD" == "-h" || "$SUBCMD" == "--help" ]]; then usage; exit 0; fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --username)       USERNAME="$2"; shift 2 ;;
            --uid)            UID_NUM="$2"; shift 2 ;;
            --gid)            GID_NUM="$2"; shift 2 ;;
            --email)          EMAIL="$2"; shift 2 ;;
            --ssh-key)        SSH_KEY="$2"; shift 2 ;;
            --shell)          SHELL_="$2"; shift 2 ;;
            --home)           HOME_="$2"; shift 2 ;;
            --slurm-account)  SLURM_ACCOUNT="$2"; shift 2 ;;
            --namespace)      NS="$2"; shift 2 ;;
            --login-pod)      LOGIN_POD="$2"; shift 2 ;;
            --login-ctr)      LOGIN_CTR="$2"; shift 2 ;;
            --kubeconfig)     KUBECONFIG_FLAG="--kubeconfig=$2"; shift 2 ;;
            --context)        CONTEXT_FLAG="--context=$2"; shift 2 ;;
            --confirm)        CONFIRM="1"; shift ;;
            -h|--help)        usage; exit 0 ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    [[ -n "$USERNAME" ]] || die "--username required"
    [[ -n "$HOME_" ]] || HOME_="/home/$USERNAME"
    [[ -n "$GID_NUM" ]] || GID_NUM="$UID_NUM"
}

preflight() {
    kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG get pod -n "$NS" "$LOGIN_POD" >/dev/null 2>&1 \
        || die "login pod $NS/$LOGIN_POD not found"
}

# Return 0 if user exists with matching UID, 1 if absent, 2 if UID mismatch.
probe_user() {
    local existing_uid
    existing_uid=$(kexb "id -u $USERNAME 2>/dev/null || true" | tr -d '[:space:]')
    if [[ -z "$existing_uid" ]]; then return 1; fi
    if [[ "$existing_uid" == "$UID_NUM" ]]; then return 0; fi
    echo "ERROR: user $USERNAME already exists with UID=$existing_uid, requested UID=$UID_NUM" >&2
    return 2
}

ensure_slurm_account() {
    local out
    out=$(kexb "sacctmgr -nP show account $SLURM_ACCOUNT 2>/dev/null" 2>/dev/null || true)
    if [[ -n "$out" ]]; then
        echo "  slurm account '$SLURM_ACCOUNT' already present"
        return
    fi
    echo "  creating slurm account '$SLURM_ACCOUNT'"
    kexb "sacctmgr -i add account $SLURM_ACCOUNT Description='sunk-anywhere default user account' >/dev/null"
}

ensure_linux_user() {
    echo "  ensuring Linux user $USERNAME ($UID_NUM:$GID_NUM)"
    kexb "
set -e
getent group $GID_NUM >/dev/null 2>&1 || groupadd -g $GID_NUM $USERNAME
if id $USERNAME >/dev/null 2>&1; then
    # Idempotent: update email in GECOS, leave UID/GID/shell/home alone
    usermod -c '$EMAIL' $USERNAME
else
    useradd -u $UID_NUM -g $GID_NUM -m -d '$HOME_' -s '$SHELL_' -c '$EMAIL' $USERNAME
fi
"
}

drop_key() {
    echo "  dropping SSH key into $HOME_/.ssh/authorized_keys"
    # Use a heredoc via kubectl-exec stdin to avoid quoting problems with the key contents.
    kubectl $KUBECONFIG_FLAG $CONTEXT_FLAG exec -i -n "$NS" "$LOGIN_POD" -c "$LOGIN_CTR" -- \
        bash -c "
set -e
install -d -o $USERNAME -g $GID_NUM -m 0700 $HOME_/.ssh
cat > $HOME_/.ssh/authorized_keys.new
chown $USERNAME:$GID_NUM $HOME_/.ssh/authorized_keys.new
chmod 0600 $HOME_/.ssh/authorized_keys.new
mv $HOME_/.ssh/authorized_keys.new $HOME_/.ssh/authorized_keys
" <<< "$SSH_KEY"
}

ensure_slurm_user() {
    local out
    out=$(kexb "sacctmgr -nP show user $USERNAME 2>/dev/null" 2>/dev/null || true)
    if [[ -n "$out" ]]; then
        echo "  slurm user '$USERNAME' already associated"
        return
    fi
    echo "  adding slurm user '$USERNAME' with DefaultAccount=$SLURM_ACCOUNT"
    kexb "sacctmgr -i add user $USERNAME DefaultAccount=$SLURM_ACCOUNT >/dev/null"
}

readback() {
    echo "  read-back:"
    kexb "id $USERNAME"
    kexb "stat -c '%n %a %U:%G' $HOME_/.ssh/authorized_keys"
    kexb "sacctmgr -nP show user $USERNAME" || die "slurm assoc missing after add"
}

do_add() {
    [[ -n "$UID_NUM" ]] || die "--uid required for add"
    [[ -n "$EMAIL" ]] || die "--email required for add"
    [[ -n "$SSH_KEY" ]] || die "--ssh-key required for add"
    preflight
    probe_user || { rc=$?; [[ $rc -eq 1 ]] || exit $rc; }
    ensure_slurm_account
    ensure_linux_user
    drop_key
    ensure_slurm_user
    readback
    echo "OK: user $USERNAME provisioned (login-pod identity only; see skill for compute-pod identity options)"
}

do_update_key() {
    [[ -n "$SSH_KEY" ]] || die "--ssh-key required for update-key"
    preflight
    probe_user || die "user $USERNAME not found on login pod; use 'add' first"
    # Use existing UID/GID + home from the pod for correct ownership.
    local pod_uid pod_gid pod_home
    pod_uid=$(kexb "id -u $USERNAME" | tr -d '[:space:]')
    pod_gid=$(kexb "id -g $USERNAME" | tr -d '[:space:]')
    pod_home=$(kexb "getent passwd $USERNAME | cut -d: -f6" | tr -d '[:space:]')
    UID_NUM="$pod_uid"; GID_NUM="$pod_gid"; HOME_="$pod_home"
    drop_key
    echo "OK: SSH key rotated for $USERNAME"
}

do_remove() {
    [[ "$CONFIRM" == "1" ]] || die "--confirm required for remove"
    preflight
    # Slurm side first: remove association but preserve history.
    local out
    out=$(kexb "sacctmgr -nP show user $USERNAME 2>/dev/null" 2>/dev/null || true)
    if [[ -n "$out" ]]; then
        echo "  removing slurm user '$USERNAME' (history preserved in sacct)"
        kexb "sacctmgr -i remove user where name=$USERNAME >/dev/null" || true
    fi
    # Linux side: userdel -r to remove home + mail spool (keeps NFS clean).
    if kexb "id $USERNAME >/dev/null 2>&1" ; then
        echo "  userdel -r $USERNAME on login pod"
        kexb "userdel -r $USERNAME" || true
    fi
    echo "OK: user $USERNAME removed (sacct history retained)"
}

main() {
    parse_args "$@"
    case "$SUBCMD" in
        add)        do_add ;;
        update-key) do_update_key ;;
        remove)     do_remove ;;
    esac
}

main "$@"
