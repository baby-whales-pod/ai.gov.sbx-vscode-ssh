# 06 · better-remote-ssh — template-backed VSCode Remote-SSH

Same result as [`01-remote-ssh`](../01-remote-ssh/) — connect VSCode from the host
to an isolated `sbx` sandbox over SSH — but the OpenSSH layer is baked into a
**custom sandbox template** built on top of a Docker-provided one.

It follows the standard sandbox-template layout (`Dockerfile` + `config.env` +
`build.sh`), like
[`sbx-my-docker-agent`](https://github.com/DockerSolutionsEngineering/ai.gov.sbx-template-kit-docker-agent/tree/main/templates/sbx-my-docker-agent).

## How it works

```
   docker/sandbox-templates:claude-code-docker        (Docker-provided base)
                    │  + OpenSSH layer (Dockerfile)
                    ▼
   build.sh ──┬─ (local)  buildx → OCI tar → sbx template load ─┐
              └─ (push)   buildx --platform … --push ───────────┤→ philippecharriere494/sbx-remote-ssh:0.0.0
                                                                 │   (same tag, local store and/or Docker Hub)
   start.sh ──► sbx run claude -t <tag> --kit ./kit --detached WS ◄┘
            └─► inject key · publish port · ssh-config · launch VSCode
   kit/spec.yaml ──► (each boot) start sshd + sync proxy env
```

The image snapshots only the **filesystem** (OpenSSH pre-installed). Boot
behaviour can't be baked in, so starting `sshd` and syncing the per-create proxy
vars stay in the **kit** (`kit/spec.yaml`, a `kind: mixin`).

### Why the built-in `claude` agent + `-t` (and not a custom agent kit)

`start.sh` runs the **built-in `claude` agent** and only swaps the image with
`-t`:

```bash
sbx run claude -t philippecharriere494/sbx-remote-ssh:0.0.0 --kit ./kit …
```

A custom `kind: agent` kit (declaring its own `agent.image`) would **replace**
the `claude` agent, and with it sbx's Anthropic credential wiring — the sandbox
would seed no `~/.claude/settings.json` apiKeyHelper and Claude Code would prompt
for `/login`. Keeping `claude` as the agent preserves automatic, proxy-managed
auth (verified: `claude -p` works with no login). The template is therefore
selected with `-t` (tag from `config.env`), and the kit stays a thin mixin that
just adds `sshd` + proxy sync. `sbx` uses the local image if present, otherwise
pulls it from Docker Hub.

## Files

| File | Role |
|---|---|
| `Dockerfile` | OpenSSH layer on top of `$BASE_IMAGE` |
| `config.env` | Image identity: `DOCKER_HANDLE`, `NAME`, `TAG`, `BASE_IMAGE` |
| `build.sh` | `./build.sh` (local) / `./build.sh push` (Docker Hub) |
| `kit/spec.yaml` | `kind: mixin` kit — per-boot startup (start `sshd`, sync proxy env) |
| `start.sh` | `sbx run claude -t <tag> --kit ./kit …`, inject key, publish port, launch VSCode |
| `.env` | Runtime/SSH: `SANDBOX_NAME`, `SSH_*`, optional `TEMPLATE_TAG` override |
| `.vscode/` | Minimal workspace settings + recommended extensions |

## Usage

### Local (single machine)

```bash
cd 06-better-remote-ssh
./build.sh                       # build into the sbx store (no push)
./start.sh ~/my-project          # launch + open VSCode (or ./start.sh for $PWD)
```

### Share via Docker Hub

```bash
docker login                     # as $DOCKER_HANDLE (philippecharriere494)
./build.sh push                  # build multi-arch + push the same tag
./start.sh ~/my-project          # sbx pulls the image if not built locally
```

On another machine, no local build is needed — `./start.sh` pulls the template
on first use.

`start.sh` then:

1. `sbx run claude -t <tag> --kit ./kit` — the `claude` agent keeps its auth
   wiring, `-t` selects our template, the workspace is mounted at the same path
   (`--detached` so the session survives), reusing the sandbox if it already runs;
2. injects your public key (`$SSH_PUBKEY`) into `~/.ssh/authorized_keys`;
3. publishes `127.0.0.1:$SSH_PORT` → sandbox `:22` (only if not already published);
4. appends a `Host` block to `~/.ssh/config` (once);
5. launches VSCode in Remote-SSH mode (skip with `--no-vscode`).

Override runtime bits inline:

```bash
SSH_PORT=2255 SANDBOX_NAME=demo ./start.sh ~/code/demo
```

Ship a new version: bump `TAG` in `config.env`, then `./build.sh` / `./build.sh push`.

> First VSCode connection still downloads VSCode-server (~140 MB) into the
> sandbox; subsequent connects are fast. The runtime kit whitelists only the
> VSCode/marketplace domains needed for that.

## Requirements

- `sbx`, `ssh`, `docker` (with `buildx`), and the `code` CLI on `PATH`
- For `./build.sh push`: `docker login` as `$DOCKER_HANDLE`
- An SSH key whose public part is at `$SSH_PUBKEY` (default `~/.ssh/id_ed25519.pub`)
