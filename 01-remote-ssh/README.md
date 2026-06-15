# VSCode Remote-SSH inside a Docker sandbox

## 1. Solution overview

This kit (`01-remote-ssh`) lets you **connect VSCode** (from the host) to an isolated **Docker sandbox** over **SSH** — i.e. using VSCode's built-in **Remote-SSH** feature.

The sandbox bundles:

- an **OpenSSH server** (`sshd`) listening on port `22` inside the container;
- **public-key only** authentication (passwords disabled, only the `agent` user may log in);
- automatic propagation of `sandboxd`'s **proxy variables** to SSH sessions, so tools invoked from VSCode (e.g. `claude`, `npm`, `pip`) traverse the sandbox proxy correctly;
- a host workspace **mounted at the same path** inside the sandbox (e.g. `/Users/me/project` on the host ⇒ `/Users/me/project` inside).

End result: the user opens VSCode on their machine, the **VSCode Server** (Microsoft's official component — not to be confused with the open-source `code-server` project by Coder, which serves VSCode in a browser) is automatically installed into `~/.vscode-server/` inside the sandbox, and all execution (terminal, extensions, debugger, AI) happens **inside the isolated environment** instead of on the host.

### Kit components

| File | Role |
|---|---|
| `spec.yaml` | Sandbox *mixin* spec: OpenSSH install, `sshd` config, startup steps |
| `start.sh` | Host-side script: creates the sandbox, injects the public key, publishes the port, updates `~/.ssh/config`, launches VSCode |
| `.env` | Variables: sandbox name, SSH alias, host-side port |
| `.vscode/` | Workspace VSCode preferences (theme, formatting, etc.) |

---

## 2. Architecture

```
┌────────────────────────────┐           ┌──────────────────────────────────────┐
│        HOST MACHINE        │           │   DOCKER SANDBOX (vscode-ssh)        │
│                            │           │                                      │
│   ┌──────────────┐         │           │   ┌────────────────────────────┐     │
│   │   VSCode     │         │           │   │  sshd  0.0.0.0:22          │     │
│   │ (Remote-SSH) │         │           │   └─────────────┬──────────────┘     │
│   └──────┬───────┘         │           │                 │ PubkeyAuth         │
│          │                 │           │                 │ (agent only)       │
│          ▼                 │           │                 ▼                    │
│   ┌──────────────┐ tcp:2222│    :22    │   ┌────────────────────────────┐     │
│   │  SSH client  │─────────┼──────────►│   │  'agent' shell session     │     │
│   │ ssh/config   │         │           │   │  PATH + proxy vars         │     │
│   └──────────────┘         │           │   └─────────────┬──────────────┘     │
│                            │           │                 ▼                    │
│   ┌──────────────┐         │           │   ┌────────────────────────────┐     │
│   │   sbx CLI    │─────────┼──────────►│   │  VSCode Server             │     │
│   └──────────────┘  run/exec/ports     │   │  (~/.vscode-server/)       │     │
│                            │           │   │  → workspace (same path)   │     │
│                            │           │   └────────────────────────────┘     │
│                            │           │                                      │
│                            │           │   ┌────────────────────────────┐     │
│                            │           │   │ sandboxd proxy → Internet  │     │
│                            │           │   └────────────────────────────┘     │
└────────────────────────────┘           └──────────────────────────────────────┘
```

### Authentication flow

```
    User       Host       sbx CLI       Sandbox        VSCode
     │           │            │             │             │
     │ start.sh  │            │             │             │
     ├──────────►│            │             │             │
     │           │  sbx run   │             │             │
     │           ├───────────►├────────────►│             │
     │           │            │             │ install sshd│
     │           │            │             │ gen host keys│
     │           │            │             │ start sshd  │
     │           │            │             │             │
     │           │  sbx exec  │             │             │
     │           ├───────────►├────────────►│ write       │
     │           │            │             │ authorized_keys
     │           │            │             │             │
     │           │  sbx ports │             │             │
     │           ├───────────►├────────────►│ publish :2222
     │           │            │             │             │
     │           │ append ~/.ssh/config     │             │
     │           │◄──┐        │             │             │
     │           │   │        │             │             │
     │           │ code --remote ssh-remote+sbx-vscode-ssh
     │           ├───────────────────────────────────────►│
     │           │            │             │ SSH connect │
     │           │            │             │◄────────────┤
     │           │            │             │ DL VSCode   │
     │           │            │             │ Server      │
     │           │            │             ├────────────►│
     │◄──────────┼────────────┼─────────────┼─────────────┤
     │ editor ready                                       │
```

---

## 3. How the solution was built

### 3.1 Sandbox mixin (`spec.yaml`)

`spec.yaml` declares a **mixin** (`kind: mixin`) — a module grafted onto the base `claude` image via `sbx run --kit`. It defines:

#### Allowed domains (`network.allowedDomains`)

The sandbox sits behind a default-deny proxy, so each required domain is explicitly whitelisted:

- **Ubuntu repos** (`archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com`) — for `apt-get install openssh-server`;
- **VSCode** (`update.code.visualstudio.com`, `vscode.download.prss.microsoft.com`, `*.vo.msecnd.net`) — to download the VSCode Server;
- **VSCode Marketplace** (`marketplace.visualstudio.com`, `*.gallery.vsassets.io`, `*.gallerycdn.vsassets.io`) — to install extensions.

#### `install` commands (run when the sandbox is created)

1. **Install OpenSSH**: `apt-get install openssh-server`, then create `/run/sshd`.
2. **Prepare `~/.ssh`**: directory `0700`, file `authorized_keys` `0600`, owner `agent:agent` (otherwise `sshd` refuses to read the key).
3. **PATH for SSH sessions**: append `/home/agent/.local/bin` and `/usr/local/share/npm-global/bin` to `/etc/sandbox-persistent.sh` — without this, `claude`, global `npm` packages, etc. wouldn't be found from an SSH session (non-login `bash`).
4. **`sshd` configuration**: a drop-in at `/etc/ssh/sshd_config.d/10-sandbox.conf` that:
   - listens on `0.0.0.0:22` (required so `sbx ports` can publish — `127.0.0.1` alone wouldn't work);
   - disables password / root / X11;
   - enables public-key auth **only**;
   - restricts logins to user `agent`;
   - then `ssh-keygen -A` generates host keys.

#### `startup` commands (run on every container boot)

```
    ┌───────────────────────────┐
    │     Container start       │
    └────────────┬──────────────┘
                 ▼
    ┌───────────────────────────┐
    │   mkdir -p /run/sshd      │
    └────────────┬──────────────┘
                 ▼
    ┌─────────────────────────────────────────────┐
    │  Sync proxy env vars                        │
    │  HTTP_PROXY, HTTPS_PROXY, NO_PROXY,         │
    │  PROXY_CA_CERT_B64, NODE_EXTRA_CA_CERTS     │
    │      → /etc/sandbox-persistent.sh           │
    └────────────┬────────────────────────────────┘
                 ▼
    ┌───────────────────────────┐
    │     sshd -D -e            │
    │     (background)          │
    └────────────┬──────────────┘
                 ▼
    ┌─────────────────────────────────┐
    │  Wait: sshd bound to :22        │
    │  (40 attempts × 250 ms)         │
    └────────────┬────────────────────┘
                 ▼
    ┌───────────────────────────┐
    │      Sandbox ready        │
    └───────────────────────────┘
```

The **proxy propagation** step is critical: `sshd` does **not** propagate the container's runtime environment variables to user sessions (PAM reads `/etc/environment`). Without this rewrite, `claude` would hit `api.anthropic.com` directly, the proxy wouldn't inject the API key, and the user would get `Invalid API key`. The block is delimited by `# >>> sbx-proxy >>>` / `# <<< sbx-proxy <<<` so it stays **idempotent**: proxy ports and certificates change at every container creation, hence the rewrite on each boot.

#### `memory` block

The `memory:` field adds instructions to Claude's memory when it operates from inside the sandbox: usage commands (`pgrep sshd`, `ss -ltnp`, etc.) and host-side procedure.

### 3.2 Host-side startup script (`start.sh`)

```
   ┌───────────────────────────────────┐
   │   ./start.sh [WORKSPACE]          │
   └────────────────┬──────────────────┘
                    ▼
   ┌───────────────────────────────────┐
   │   Load .env                       │
   │   SANDBOX_NAME, SSH_HOST_ALIAS,   │
   │   SSH_PORT                        │
   └────────────────┬──────────────────┘
                    ▼
   ┌──────────────────────────────────────┐
   │  sbx run claude --kit ./remote-ssh/  │
   │  --name vscode-ssh --detached WS     │
   └────────────────┬─────────────────────┘
                    ▼
   ┌───────────────────────────────────┐
   │  sbx exec: write public key       │
   │  → ~/.ssh/authorized_keys         │
   └────────────────┬──────────────────┘
                    ▼
   ┌───────────────────────────────────┐
   │  sbx ports --publish 2222:22/tcp  │
   └────────────────┬──────────────────┘
                    ▼
         ┌──────────┴──────────┐
         │  ~/.ssh/config      │
         │  already contains   │
         │  Host sbx-vscode-ssh│
         └────┬───────────┬────┘
          Yes │           │ No
              ▼           ▼
       ┌──────────┐  ┌──────────────────┐
       │   skip   │  │ Append the block │
       └────┬─────┘  └────────┬─────────┘
            └────────┬────────┘
                     ▼
   ┌───────────────────────────────────┐
   │  ssh sbx-vscode-ssh hostname      │
   │  (connectivity test)              │
   └────────────────┬──────────────────┘
                    ▼
         ┌──────────┴──────────┐
         │   --no-vscode ?     │
         └────┬───────────┬────┘
          No  │           │ Yes
              ▼           ▼
   ┌──────────────────┐  ┌─────────────────────┐
   │  code --remote   │  │  Manual             │
   │  ssh-remote+...  │  │  instructions       │
   └──────────────────┘  └─────────────────────┘
```

Key points:

- **`--detached`** on `sbx run`: without this flag, `sandboxd` stops the sandbox ~30s after the last `sbx exec` / `sbx run`. But VSCode Remote-SSH keeps a long-lived SSH connection that **doesn't** use `sbx exec`, so the sandbox would be killed and the VSCode session severed. `--detached` disables that auto-stop.
- **Same-path workspace mount**: `WORKSPACE` (defaulting to `$PWD`) is passed as the last argument to `sbx run`, which mounts the host folder at the **same absolute path** inside the sandbox. File links, `.git`, `node_modules`, etc. stay consistent across host and sandbox.
- **Idempotent `~/.ssh/config`**: the `Host sbx-vscode-ssh` block is appended only once; re-running the script doesn't duplicate it.
- **`StrictHostKeyChecking no` + `UserKnownHostsFile /dev/null`**: sandbox host keys are regenerated on every creation (`ssh-keygen -A` in `install`), so strict checking would yield "man-in-the-middle" warnings for every throw-away sandbox. Acceptable trade-off since the connection never leaves loopback (`127.0.0.1`).

### 3.3 Why this architecture?

| Decision | Rationale |
|---|---|
| **OpenSSH** instead of a custom tunnel | VSCode Remote-SSH natively uses SSH; no custom extension to install on the host. |
| **Public-key only authentication** | The sandbox is disposable and its port `22` is exposed on `127.0.0.1`; no default password to leak. |
| **`AllowUsers agent` restriction** | Blocks any attempt to log in as another account (e.g. `root`) even if a key were injected for them. |
| **Workspace mounted at the same path** | Avoids relative/absolute path surprises in tools (`go build`, `node`, debuggers) that inspect `cwd`. |
| **Proxy propagation via `/etc/sandbox-persistent.sh`** | Non-login SSH sessions don't source `/etc/environment`; `CLAUDE_ENV_FILE` (sourced by every Bash invocation) is the only reliable spot. |
| **`--detached`** | Without it, the sandbox would shut down mid-coding-session. |

---

## 4. Usage

### First use

```bash
cd 01-remote-ssh
./start.sh ~/my-project
```

The script:
1. creates the `vscode-ssh` sandbox with the workspace mounted;
2. injects the `~/.ssh/id_ed25519.pub` public key;
3. publishes `127.0.0.1:2222` → sandbox `:22`;
4. configures `~/.ssh/config`;
5. launches VSCode in Remote-SSH mode on `sbx-vscode-ssh`.
