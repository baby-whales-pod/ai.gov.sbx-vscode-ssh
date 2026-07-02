#!/bin/bash
set -euo pipefail

# Usage: ./start.sh [--no-cursor] [WORKSPACE]
#   WORKSPACE:    host directory to mount into the sandbox (default: $PWD).
#                 The workspace is mounted at the same path inside the sandbox
#                 — for example /Users/me/my-project on the host is accessible
#                 at /Users/me/my-project inside the sandbox.
#   --no-cursor:  skip the final `cursor --remote` launch (just print instructions).
#
# Configuration is read from a `.env` file located next to this script.
# Supported variables (with defaults):
#   SANDBOX_NAME    name of the sandbox          (default: cursor-ssh)
#   SSH_HOST_ALIAS  Host alias in ~/.ssh/config  (default: sbx-${SANDBOX_NAME})
#   SSH_PORT        host port mapped to sbx:22   (default: 2223)

LAUNCH_CURSOR=1
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --no-cursor|--no-vscode) LAUNCH_CURSOR=0 ;;
    *)                       POSITIONAL+=("$arg") ;;
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

SANDBOX_NAME="${SANDBOX_NAME:-cursor-ssh}"
SSH_HOST_ALIAS="${SSH_HOST_ALIAS:-sbx-${SANDBOX_NAME}}"
SSH_PORT="${SSH_PORT:-2223}"

# Locate the Cursor CLI. Prefer `cursor` on PATH (installed via Cursor's
# "Shell Command: Install 'cursor' command"), but fall back to the binary
# shipped inside the macOS / Linux app bundle so the kit works even when the
# CLI shim was never installed. Override with CURSOR_BIN in .env if needed.
resolve_cursor_bin() {
  if [ -n "${CURSOR_BIN:-}" ] && [ -x "$CURSOR_BIN" ]; then return 0; fi
  if command -v cursor >/dev/null 2>&1; then CURSOR_BIN="$(command -v cursor)"; return 0; fi
  for c in \
    "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" \
    "$HOME/Applications/Cursor.app/Contents/Resources/app/bin/cursor" \
    "/usr/share/cursor/bin/cursor" \
    "/opt/Cursor/bin/cursor" \
    "$HOME/.local/bin/cursor"; do
    if [ -x "$c" ]; then CURSOR_BIN="$c"; return 0; fi
  done
  CURSOR_BIN=""
  return 1
}
resolve_cursor_bin || true

echo "Sandbox:   $SANDBOX_NAME"
echo "SSH host:  $SSH_HOST_ALIAS (127.0.0.1:$SSH_PORT)"
echo "Workspace: $WORKSPACE"
echo

# --detached sets Spec.Detached=true on the runtime in sandboxd, which
# disables auto-stop on sentinel disconnect. Without this flag, sbx stops
# the sandbox ~30s after the last `sbx exec`/`sbx run`, which kills the
# Cursor Remote-SSH session.
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
  ServerAliveInterval 15
  ServerAliveCountMax 4
  TCPKeepAlive yes
EOF
fi

ssh "$SSH_HOST_ALIAS" hostname
echo
echo "Workspace mounted at: $WORKSPACE (same path inside the sandbox)"

# Pre-seed the Cursor server inside the sandbox.
#
# The first Remote-SSH connection otherwise downloads the Cursor server
# (~150 MB) at connect time. Behind the sandbox's filtering proxy this is slow,
# and if the connection churns the CLI re-resolves and re-downloads it in a
# loop. We fetch the server for the host's exact Cursor commit ahead of time, so
# the editor attaches to an already-installed server instead of downloading.
# Idempotent: it skips the download if the server for that commit is present.
#
# Cursor is a VSCode fork: its CLI is `cursor`, its server lives in
# ~/.cursor-server (not ~/.vscode-server), and the REH tarball comes from
# Cursor's own blob storage instead of update.code.visualstudio.com.
if [ -n "$CURSOR_BIN" ]; then
  echo "Using Cursor CLI: $CURSOR_BIN"
  CURSOR_COMMIT="$("$CURSOR_BIN" --version 2>/dev/null | sed -n '2p' | tr -d '[:space:]')"
  if [ -n "$CURSOR_COMMIT" ]; then
    echo "Pre-seeding Cursor server (commit ${CURSOR_COMMIT})…"
    sbx exec --env COMMIT="$CURSOR_COMMIT" "$SANDBOX_NAME" -- sh -c '
      set -e
      SRV="$HOME/.cursor-server/cli/servers/Stable-$COMMIT/server"
      if [ -x "$SRV/bin/cursor-server" ] || [ -x "$SRV/bin/code-server" ]; then
        echo "  server already present — skipping download"
        exit 0
      fi
      case "$(uname -m)" in
        aarch64|arm64) ARCH=arm64 ;;
        *)             ARCH=x64 ;;
      esac
      # Cursor has shipped the REH server from a few hosts over time; try them
      # in order until one returns the tarball.
      TARBALL="vscode-reh-linux-$ARCH.tar.gz"
      URLS="
        https://cursor.blob.core.windows.net/remote-releases/$COMMIT/$TARBALL
        https://downloads.cursor.com/production/$COMMIT/linux/$ARCH/$TARBALL
      "
      TMP="$(mktemp)"
      OK=0
      for URL in $URLS; do
        echo "  trying $URL"
        if curl -fsSL "$URL" -o "$TMP"; then OK=1; break; fi
      done
      if [ "$OK" -ne 1 ]; then
        echo "  could not download Cursor server for $COMMIT/$ARCH"
        rm -f "$TMP"
        exit 1
      fi
      mkdir -p "$SRV"
      tar -xzf "$TMP" -C "$SRV" --strip-components=1
      rm -f "$TMP"
      echo "  seeded vscode-reh-linux-$ARCH for $COMMIT"
    ' || echo "  (pre-seed failed — Cursor will download on connect)"

    # Pre-install the workspace's recommended extensions into the just-seeded
    # server. Since the sandbox (and therefore ~/.cursor-server/extensions) is
    # recreated from scratch on each run, the editor would otherwise reinstall
    # and re-activate every extension on every connection. Installing them here
    # — using the server's own CLI against Cursor's marketplace — means they are
    # already present when the editor attaches. Idempotent: --install-extension
    # is a no-op for an extension that is already installed.
    EXT_JSON="$WORKSPACE/.vscode/extensions.json"
    [ -f "$EXT_JSON" ] || EXT_JSON="$KIT_DIR/.vscode/extensions.json"
    if [ -f "$EXT_JSON" ]; then
      # Pull "publisher.name" ids out of the recommendations array; tolerant of
      # JSONC trailing commas / comments.
      EXTS="$(grep -oE '"[A-Za-z0-9][A-Za-z0-9_-]+\.[A-Za-z0-9][A-Za-z0-9_-]+"' "$EXT_JSON" | tr -d '"' | sort -u | tr '\n' ' ')"
      if [ -n "$EXTS" ]; then
        echo "Pre-installing extensions:${EXTS:+ }$EXTS"
        sbx exec --env COMMIT="$CURSOR_COMMIT" --env EXTS="$EXTS" "$SANDBOX_NAME" -- sh -c '
          BASE="$HOME/.cursor-server/cli/servers/Stable-$COMMIT/server/bin"
          CODE="$BASE/cursor-server"
          [ -x "$CODE" ] || CODE="$BASE/code-server"
          [ -x "$CODE" ] || { echo "  server CLI not found — skipping extension pre-install"; exit 0; }
          for e in $EXTS; do
            if "$CODE" --install-extension "$e" --force >/dev/null 2>&1; then
              echo "  installed $e"
            else
              echo "  FAILED $e (may be unavailable on Cursor/Open VSX marketplace)"
            fi
          done
        ' || echo "  (extension pre-install failed — Cursor will install on connect)"
      fi
    fi
  fi
fi

if [ "$LAUNCH_CURSOR" -eq 1 ]; then
  if [ -n "$CURSOR_BIN" ]; then
    # Work around a macOS Remote-SSH regression (inherited from VSCode,
    # vscode-remote-release #11672 / #11676): the editor creates its askpass
    # and delay-shutdown IPC sockets under $TMPDIR. The default macOS TMPDIR
    # (/var/folders/…/T, ~49 chars) pushes the socket path past the 104-char
    # sockaddr_un limit, so bind/connect fails with EINVAL → infinite reconnect
    # loop (or, worse, the connection can't be established at all). Launching
    # with a short TMPDIR keeps the socket path within the limit.
    #
    # NOTE: this only helps when Cursor is *not already running* — a running
    # instance keeps the TMPDIR it was started with. Quit Cursor fully first.
    if pgrep -f "Cursor.app/Contents/MacOS" >/dev/null 2>&1; then
      echo "⚠️  Cursor is already running — the short-TMPDIR fix won't apply to it."
      echo "    Quit Cursor completely (Cmd+Q on every window) and re-run this"
      echo "    script, otherwise the macOS socket-path bug may persist."
    fi
    export TMPDIR=/tmp
    echo "Launching Cursor (TMPDIR=$TMPDIR) → ssh-remote+${SSH_HOST_ALIAS}:$WORKSPACE"
    "$CURSOR_BIN" --remote "ssh-remote+${SSH_HOST_ALIAS}" "$WORKSPACE"
  else
    echo "Cursor CLI not found — skipping auto-launch."
    echo "  Install it from Cursor: Cmd+Shift+P → \"Shell Command: Install 'cursor' command\","
    echo "  or set CURSOR_BIN=/path/to/cursor in .env, then re-run."
    echo "In Cursor: Remote-SSH → ${SSH_HOST_ALIAS}, then Open Folder → $WORKSPACE"
  fi
else
  echo "In Cursor: Remote-SSH → ${SSH_HOST_ALIAS}, then Open Folder → $WORKSPACE"
fi
