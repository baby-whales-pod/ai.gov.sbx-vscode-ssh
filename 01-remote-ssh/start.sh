#!/bin/bash
set -euo pipefail

# Usage: ./start.sh [--no-vscode] [WORKSPACE]
#   WORKSPACE:    host directory to mount into the sandbox (default: $PWD).
#                 The workspace is mounted at the same path inside the sandbox
#                 — for example /Users/me/my-project on the host is accessible
#                 at /Users/me/my-project inside the sandbox.
#   --no-vscode:  skip the final `code --remote` launch (just print instructions).
#
# Configuration is read from a `.env` file located next to this script.
# Supported variables (with defaults):
#   SANDBOX_NAME    name of the sandbox          (default: vscode-ssh)
#   SSH_HOST_ALIAS  Host alias in ~/.ssh/config  (default: sbx-${SANDBOX_NAME})
#   SSH_PORT        host port mapped to sbx:22   (default: 2222)

LAUNCH_VSCODE=1
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --no-vscode) LAUNCH_VSCODE=0 ;;
    *)           POSITIONAL+=("$arg") ;;
  esac
done

WORKSPACE="${POSITIONAL[0]:-$PWD}"
WORKSPACE="$(cd "$WORKSPACE" && pwd)"            # absolute path, resolves symlinks
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if present (variables already in the environment win).
ENV_FILE="$KIT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

SANDBOX_NAME="${SANDBOX_NAME:-vscode-ssh}"
SSH_HOST_ALIAS="${SSH_HOST_ALIAS:-sbx-${SANDBOX_NAME}}"
SSH_PORT="${SSH_PORT:-2222}"

echo "Sandbox:   $SANDBOX_NAME"
echo "SSH host:  $SSH_HOST_ALIAS (127.0.0.1:$SSH_PORT)"
echo "Workspace: $WORKSPACE"
echo

# --detached sets Spec.Detached=true on the runtime in sandboxd, which
# disables auto-stop on sentinel disconnect. Without this flag, sbx stops
# the sandbox ~30s after the last `sbx exec`/`sbx run`, which kills the
# VSCode Remote-SSH session.
sbx run claude --kit "$KIT_DIR" --name "$SANDBOX_NAME" --detached "$WORKSPACE"

sbx exec --env KEY="$(cat ~/.ssh/id_ed25519.pub)" "$SANDBOX_NAME" -- \
  sh -c 'printf "%s\n" "$KEY" > /home/agent/.ssh/authorized_keys && chmod 600 /home/agent/.ssh/authorized_keys'

sbx ports "$SANDBOX_NAME" --publish "${SSH_PORT}:22/tcp"

# Idempotent: only append the Host block if it isn't already there.
if ! grep -q "^Host ${SSH_HOST_ALIAS}$" ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config <<EOF

Host ${SSH_HOST_ALIAS}
  HostName 127.0.0.1
  Port ${SSH_PORT}
  User agent
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
fi

ssh "$SSH_HOST_ALIAS" hostname
echo
echo "Workspace mounted at: $WORKSPACE (same path inside the sandbox)"

if [ "$LAUNCH_VSCODE" -eq 1 ]; then
  if command -v code >/dev/null 2>&1; then
    echo "Launching VSCode → ssh-remote+${SSH_HOST_ALIAS}:$WORKSPACE"
    code --remote "ssh-remote+${SSH_HOST_ALIAS}" "$WORKSPACE"
  else
    echo "VSCode CLI ('code') not found in PATH — skipping auto-launch."
    echo "In VSCode: Remote-SSH → ${SSH_HOST_ALIAS}, then Open Folder → $WORKSPACE"
  fi
else
  echo "In VSCode: Remote-SSH → ${SSH_HOST_ALIAS}, then Open Folder → $WORKSPACE"
fi
