#!/bin/bash

# SPDX-FileCopyrightText: 2023-2026 CoreWeave, Ltd
# SPDX-License-Identifier: Apache-2.0
# SPDX-PackageName: sunk-anywhere

# VS Code tunnel: install the `code` CLI on a Slurm allocation and exercise
# the tunnel workflow. Two modes:
#
# 1. Default (smoke): submit a job that downloads the code CLI, runs
#    `code --version` and `code tunnel --help`, and reports PASS if both
#    succeed. Proves the allocation can reach code.visualstudio.com and
#    that the binary unpacks correctly on the Slurm compute image.
#
# 2. Interactive (VSCODE_TUNNEL_INTERACTIVE=1): allocate a node, install
#    the CLI, start `code tunnel --accept-server-license-terms --name=$NAME`
#    on that node, and print the GitHub device-code URL plus the
#    vscode.dev connect URL. User connects from their laptop VS Code.
#    Exit with scancel when the user is done.
#
# Prereqs: outbound HTTPS to update.code.visualstudio.com and github.com
# from compute nodes. Interactive mode also needs a GitHub account.
#
# Exit codes: 0 PASS, 1 FAIL, 2 SKIPPED.

PARTITION="${PARTITION:-cpu-workers}"
TIMEOUT="${TIMEOUT:-300}"
TUNNEL_NAME="${VSCODE_TUNNEL_NAME:-sunk-$(date +%s)}"

echo "=== 19-vscode-tunnel (partition=$PARTITION mode=${VSCODE_TUNNEL_INTERACTIVE:+interactive}${VSCODE_TUNNEL_INTERACTIVE:-smoke}) ==="

NODES=$(sinfo -h -N -p "$PARTITION" -o '%N' 2>/dev/null | sort -u | grep -cv '^$')
if [ -z "$NODES" ] || [ "$NODES" -eq 0 ]; then
  echo "SKIPPED: no nodes in partition $PARTITION"
  exit 2
fi

# Body of the install script, reused by both modes.
INSTALL_SCRIPT=$(cat <<'INSTALL_EOF'
set -e
DEST="$HOME/.local/bin"
mkdir -p "$DEST"
cd "$(mktemp -d)"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)   PKG=cli-alpine-x64 ;;
  aarch64)  PKG=cli-alpine-arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac
URL="https://update.code.visualstudio.com/latest/${PKG}/stable"
echo "Fetching $URL"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o code.tgz "$URL"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O code.tgz "$URL"
else
  echo "need curl or wget on the compute node" >&2
  exit 1
fi
tar -xzf code.tgz
mv code "$DEST/code"
chmod +x "$DEST/code"
echo "installed: $("$DEST/code" --version | head -1)"
export PATH="$DEST:$PATH"
echo "$DEST/code"
INSTALL_EOF
)

# --------- smoke mode ---------

if [ -z "$VSCODE_TUNNEL_INTERACTIVE" ]; then
  # Log must land on the shared NFS /home so both the compute node (which
  # writes the sbatch stdout) and this script (which reads it) can see it.
  # A login-pod /tmp or the compute-node /tmp is invisible to the other
  # side.
  LOGDIR="${HOME:-/home/$(id -un)}"
  mkdir -p "$LOGDIR" 2>/dev/null || true
  LOG="$LOGDIR/test19-$$.log"
  : > "$LOG"
  trap 'rm -f "$LOG"' EXIT
  JID=$(sbatch --parsable -p "$PARTITION" --mem=512M --cpus-per-task=1 -t 00:05:00 \
    --output="$LOG" --wrap="
      $INSTALL_SCRIPT
      \$HOME/.local/bin/code --version
      \$HOME/.local/bin/code tunnel --help | head -5
    " 2>&1)
  if ! [[ "$JID" =~ ^[0-9]+$ ]]; then
    echo "FAIL: sbatch returned: $JID"
    exit 1
  fi
  echo "Submitted smoke job $JID"
  trap 'scancel "$JID" 2>/dev/null; rm -f "$LOG"' EXIT

  DEADLINE=$(( $(date +%s) + TIMEOUT ))
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    S=$(squeue -h -j "$JID" -o '%T' 2>/dev/null | tr -d '[:space:]')
    [ -z "$S" ] && break
    sleep 5
  done

  STATE=$(sacct -j "$JID" -X -n -P -o State 2>/dev/null | head -1 | tr -d '[:space:]')
  echo "Final state: $STATE"
  echo "--- job output ---"
  cat "$LOG" 2>/dev/null || true
  echo "--- end output ---"

  if [ "$STATE" != "COMPLETED" ]; then
    echo "FAIL: smoke job did not complete (state=$STATE)"
    exit 1
  fi
  if grep -q '^[0-9][0-9a-f.]*' "$LOG" && grep -q 'code tunnel' "$LOG"; then
    echo "PASS: code CLI installed and tunnel subcommand reachable"
    exit 0
  fi
  echo "FAIL: code CLI did not report version or tunnel help"
  exit 1
fi

# --------- interactive mode ---------

echo "Allocating a node for an interactive tunnel (name=$TUNNEL_NAME)"
ALLOC_OUT=$(salloc --no-shell -p "$PARTITION" --mem=1G --cpus-per-task=1 -t 01:00:00 2>&1)
RC=$?
echo "$ALLOC_OUT"
if [ $RC -ne 0 ]; then
  echo "FAIL: salloc returned $RC"
  exit 1
fi
JID=$(echo "$ALLOC_OUT" | grep -oE 'Granted job allocation [0-9]+' | awk '{print $NF}')
[ -z "$JID" ] && { echo "FAIL: could not parse JobId"; exit 1; }
echo "Allocation JobId=$JID (scancel $JID to release when done)"
trap 'scancel "$JID" 2>/dev/null' EXIT INT TERM

# Install + start tunnel inside the allocation. Stream output live so the
# user sees the GitHub device-code URL as it appears.
srun --overlap --jobid="$JID" --pty bash -lc "
  $INSTALL_SCRIPT
  echo '---'
  echo 'About to start tunnel. Open the GitHub URL printed below, then'
  echo 'connect from your local VS Code to tunnel name: $TUNNEL_NAME'
  echo '---'
  exec \$HOME/.local/bin/code tunnel --accept-server-license-terms --name='$TUNNEL_NAME'
"
