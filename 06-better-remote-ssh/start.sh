#!/bin/bash
set -euo pipefail

# Launch VSCode Remote-SSH against a sandbox built from the template.
#
# Prerequisite: ./build.sh (local) or ./build.sh push (Docker Hub).
#
# Usage: ./start.sh [--no-vscode] [WORKSPACE]
#   WORKSPACE    host dir to mount at the same path inside the sandbox (default: $PWD)
#   --no-vscode  set up everything but don't launch the editor
#
# Runs the built-in `claude` agent (so its Anthropic credential wiring is kept)
# with our pre-baked OpenSSH image via -t, plus the kit/ mixin for sshd + proxy.
# A custom `kind: agent` kit would REPLACE the claude agent and lose the
# automatic credential injection, so the template is selected with -t here.

LAUNCH_VSCODE=1
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --no-vscode) LAUNCH_VSCODE=0 ;;
    *)           POSITIONAL+=("$arg") ;;
  esac
done

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${POSITIONAL[0]:-$PWD}"
WORKSPACE="$(cd "$WORKSPACE" && pwd)"

set -a
[ -f "$KIT_DIR/config.env" ] && . "$KIT_DIR/config.env"
[ -f "$KIT_DIR/.env" ]       && . "$KIT_DIR/.env"
set +a

SANDBOX_NAME="${SANDBOX_NAME:-better-ssh}"
SSH_HOST_ALIAS="${SSH_HOST_ALIAS:-sbx-${SANDBOX_NAME}}"
SSH_USER="${SSH_USER:-agent}"
SSH_PORT="${SSH_PORT:-2244}"
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
SSH_PUBKEY="${SSH_PUBKEY/#\~/$HOME}"   # expand a leading ~
TEMPLATE_TAG="${TEMPLATE_TAG:-${DOCKER_HANDLE}/${NAME}:${TAG}}"

echo "Template:  $TEMPLATE_TAG"
echo "Sandbox:   $SANDBOX_NAME"
echo "SSH host:  $SSH_HOST_ALIAS (127.0.0.1:$SSH_PORT, user $SSH_USER)"
echo "Workspace: $WORKSPACE"
echo

[ -f "$SSH_PUBKEY" ] || { echo "Public key not found: $SSH_PUBKEY" >&2; exit 1; }

# Inspect current state once (here-strings below avoid the pipefail/SIGPIPE race).
LS="$(sbx ls 2>/dev/null || true)"
# Columns: SANDBOX  AGENT  STATUS  PORTS  WORKSPACE
STATUS="$(awk -v n="$SANDBOX_NAME" '$1==n {print $3; exit}' <<<"$LS")"

case "$STATUS" in
  "")
    # claude agent (keeps Anthropic credential wiring) + our pre-baked image via
    # -t + the mixin kit. --detached keeps the sandbox alive so the long-lived
    # Remote-SSH connection isn't auto-stopped. sbx uses the local image if
    # present, else pulls it from Docker Hub.
    sbx run claude -t "$TEMPLATE_TAG" --kit "$KIT_DIR/kit" --name "$SANDBOX_NAME" --detached "$WORKSPACE"
    ;;
  running)
    echo "Sandbox '$SANDBOX_NAME' already running — reusing it."
    ;;
  *)
    echo "Sandbox '$SANDBOX_NAME' is $STATUS. Start or remove it first:" >&2
    echo "  sbx run $SANDBOX_NAME          # start + attach" >&2
    echo "  sbx rm --force $SANDBOX_NAME   # remove, then re-run ./start.sh" >&2
    exit 1
    ;;
esac

# sshd reads authorized_keys per-connection, so no restart is needed.
sbx exec --env KEY="$(cat "$SSH_PUBKEY")" "$SANDBOX_NAME" -- \
  sh -c 'printf "%s\n" "$KEY" > /home/agent/.ssh/authorized_keys && chmod 600 /home/agent/.ssh/authorized_keys'

# Publishing the same port twice is a 409, so only publish if it isn't already.
SANDBOX_LINE="$(awk -v n="$SANDBOX_NAME" '$1==n' <<<"$(sbx ls 2>/dev/null || true)")"
if ! grep -q "${SSH_PORT}->22" <<<"$SANDBOX_LINE"; then
  sbx ports "$SANDBOX_NAME" --publish "${SSH_PORT}:22/tcp"
fi

# Append the Host block once. Host keys are regenerated per sandbox, so strict
# checking is disabled — safe here because the link never leaves 127.0.0.1.
if ! grep -q "^Host ${SSH_HOST_ALIAS}$" ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config <<EOF

Host ${SSH_HOST_ALIAS}
  HostName 127.0.0.1
  Port ${SSH_PORT}
  User ${SSH_USER}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ServerAliveInterval 15
  ServerAliveCountMax 4
  TCPKeepAlive yes
EOF
  echo "Added '$SSH_HOST_ALIAS' to ~/.ssh/config"
fi

ssh "$SSH_HOST_ALIAS" hostname
echo

if [ "$LAUNCH_VSCODE" -eq 1 ] && command -v code >/dev/null 2>&1; then
  # macOS Remote-SSH bug: the default long TMPDIR overflows the 104-char unix
  # socket path → reconnect loop. A short TMPDIR avoids it. Only applies to a
  # freshly launched editor, so quit VSCode fully first if it's already open.
  export TMPDIR=/tmp
  echo "Launching VSCode → ssh-remote+${SSH_HOST_ALIAS}:$WORKSPACE"
  code --remote "ssh-remote+${SSH_HOST_ALIAS}" "$WORKSPACE"
else
  echo "In VSCode: Remote-SSH → ${SSH_HOST_ALIAS}, then Open Folder → $WORKSPACE"
fi
