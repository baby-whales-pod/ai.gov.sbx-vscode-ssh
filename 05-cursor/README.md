# Cursor Remote-SSH inside a Docker sandbox

> Full documentation: [`../DOCUMENTATION.md`](../DOCUMENTATION.md)

This kit is the [`01-remote-ssh`](../01-remote-ssh/) solution adapted for the
[Cursor](https://cursor.com) IDE. It runs an OpenSSH server inside an `sbx`
sandbox so Cursor can attach to it from the host with **Remote-SSH**, exactly
like VSCode — the editor UI stays on your machine while terminals, language
servers and `claude` run inside the sandbox.

## 1. Solution overview

Cursor is a fork of VSCode, so it reuses the same Remote-SSH machinery and the
same `~/.ssh/config`. Only three things differ from the VSCode kit:

| | VSCode (`01-remote-ssh`) | Cursor (`05-cursor`) |
|---|---|---|
| CLI binary | `code` | `cursor` |
| Remote server dir | `~/.vscode-server/` | `~/.cursor-server/` |
| Server / extension hosts | `update.code.visualstudio.com`, `marketplace.visualstudio.com` | `cursor.blob.core.windows.net`, `marketplace.cursorapi.com`, `open-vsx.org` |

The SSH server itself (key-only auth, `agent`-only login, proxy env propagation)
is identical to the VSCode kit.

### Kit components

- **`spec.yaml`** — the sandbox mixin: installs `openssh-server`, writes a
  hardened `sshd` drop-in config, generates host keys, propagates the sandboxd
  proxy variables into SSH sessions, and starts `sshd`. The `network.allowedDomains`
  list is tuned for Cursor's server/extension download hosts.
- **`start.sh`** — the host-side launcher: creates the sandbox, injects your
  public key, publishes the SSH port, updates `~/.ssh/config`, pre-seeds the
  Cursor server + recommended extensions, then launches `cursor --remote`.
- **`.env`** — configuration (sandbox name, SSH host alias, host port).
- **`.vscode/`** — `settings.json` and `extensions.json` applied to the workspace
  (Cursor reads `.vscode/` like VSCode does).

## 2. Configuration (`.env`)

```bash
SANDBOX_NAME=cursor-ssh        # name of the sandbox
SSH_HOST_ALIAS=sbx-cursor-ssh  # Host alias added to ~/.ssh/config
SSH_PORT=2223                  # host port mapped to sandbox :22
```

> The port defaults to **2223** (the VSCode kit uses 2222), so both sandboxes
> can run side by side without colliding.

## 3. Usage

### First use

```bash
cd 05-cursor
./start.sh ~/my-project
```

The script:
1. creates the `cursor-ssh` sandbox with the workspace mounted at the same path;
2. injects the `~/.ssh/id_ed25519.pub` public key into `~/.ssh/authorized_keys`;
3. publishes `127.0.0.1:2223` → sandbox `:22`;
4. adds an `sbx-cursor-ssh` block to `~/.ssh/config`;
5. pre-seeds the Cursor server (matching your local `cursor --version` commit)
   and the workspace's recommended extensions;
6. launches Cursor in Remote-SSH mode on `sbx-cursor-ssh`.

Pass `--no-cursor` to skip the final launch and just print the connection
instructions:

```bash
./start.sh --no-cursor ~/my-project
```

### Connecting manually

```bash
cursor --remote ssh-remote+sbx-cursor-ssh /path/to/workspace
```

…or, inside Cursor, `Remote-SSH: Connect to Host…` → `sbx-cursor-ssh`, then
**Open Folder**.

## 4. Notes & caveats

- **Server pre-seeding is best-effort.** Cursor has shipped the REH server from a
  couple of hosts over time; `start.sh` tries `cursor.blob.core.windows.net`
  first, then `downloads.cursor.com`. If both fail (e.g. a commit/arch that was
  never published — a known Cursor issue, especially on arm64), Cursor falls
  back to downloading the server itself on first connect.
- **Extensions come from Cursor's marketplace / Open VSX.** Some Microsoft
  marketplace-only extensions may be unavailable there; those simply report
  `FAILED` during pre-install and are skipped.
- **macOS short-`TMPDIR` workaround.** Like VSCode, Cursor hits the macOS
  104-char `sockaddr_un` limit for its IPC sockets. `start.sh` launches Cursor
  with `TMPDIR=/tmp`; this only applies if Cursor is **not already running**, so
  quit it fully (`Cmd+Q`) before re-running the script.

### Diagnostics inside the sandbox

```bash
pgrep -a sshd                      # is sshd running?
ss -ltnp '( sport = :22 )'         # listening on 0.0.0.0:22?
cat ~/.ssh/authorized_keys         # was the key injected?
ls ~/.cursor-server/cli/servers/   # is the Cursor server installed?
```
