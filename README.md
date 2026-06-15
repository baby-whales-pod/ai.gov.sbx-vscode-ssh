# ai.gov.sbx-vscode-ssh
How to connect VSCode to sbx with SSH

This repository contains several demonstrations of the integration of VSCode with `sbx`:

- We create an `sbx` sandbox
- VSCode connects to `sbx` over **ssh**
- Claude Code can be used from a VSCode terminal (Claude Code actually runs inside the sandbox)

> The experience is (somewhat) similar to a devcontainer.

**List of demos**:

- [`01-remote-ssh`](#01-remote-ssh-and-02-remote-ssh) and [`02-remote-ssh`](#01-remote-ssh-and-02-remote-ssh) — Start `sbx` and connect VSCode to it via SSH (two instances so you can test in parallel).
- [`03-double-click-remote-ssh`](#03-double-click-remote-ssh) — Same demo, launched with a double-click: a terminal shows the progress and disappears once VSCode is open.
- [`04-mac-app-remote-ssh`](#04-mac-app-remote-ssh) — Same demo, packaged as a macOS `.app` bundle (silent launch, no Terminal window).

## Important

These demos are only proofs of concept:
- They can be improved (for example: I only use kits, maybe creating templates could improve startup speed).
- With `sbx` being updated frequently, the demos can break (double-check before relying on any of them).
- I vibe-coded part of the settings and scripts:
  - all security aspects still need to be reviewed
  - there's definitely some cleanup to do (simplification, better solutions, …)
  - again, this is only a proof of concept
- ✋ **Pay attention to the organization/teams policies**

## Organization and Teams policies
<!--
Policy VSCode-SSH-SBX | Scope (team) vscodeusers
-->
For this demo I creates a team policy with the following rules:

### Rules

| Name | Paths | Type | Action |
| --- | --- | --- | --- |
| VSCODE | `archive.ubuntu.com:80`, `security.ubuntu.com:80`, `ports.ubuntu.com:80`, `update.code.visualstudio.com:443`, `vscode.download.prss.microsoft.com:443`, `*.vo.msecnd.net:443`, `marketplace.visualstudio.com:443`, `*.gallery.vsassets.io:443`, `*.gallerycdn.vsassets.io:443` | TCP | Allow |
| DOCKER | `download.docker.com`, `download.docker.com:443`, `*.docker.com`, `*.docker.com:443` | TCP | Allow |
| api.anthropic.com | `api.anthropic.com:443`, `api.anthropic.com`, `*.anthropic.com:443`, `*.anthropic.com` | TCP | Allow |

## Demos

### `01-remote-ssh` and `02-remote-ssh`

The two demos do the same thing — they exist so you can run tests with two sessions in parallel.

#### What does the demo do?

It shows how to start `sbx` and connect VSCode to it over SSH.

**Video**: [https://drive.google.com/file/d/1hHPvZfqdla4trr77F1H5Lmj52d62nVql/view?usp=sharing](https://drive.google.com/file/d/1hHPvZfqdla4trr77F1H5Lmj52d62nVql/view?usp=sharing)

### `03-double-click-remote-ssh`

Exactly the same demo, but you can launch it with a double-click: a terminal pops up to show the startup and disappears once VSCode is launched.

#### What does the demo do?

It shows how to start `sbx` and connect VSCode to it over SSH.

**Video**: [https://drive.google.com/file/d/1VBpG2G_hlvJ9mQcTpZrOQDh-OqH4dtRr/view?usp=sharing](https://drive.google.com/file/d/1VBpG2G_hlvJ9mQcTpZrOQDh-OqH4dtRr/view?usp=sharing)

### `04-mac-app-remote-ssh`

Still the same demo, but this time it uses a macOS bundle (a `.app` file) to launch the application.

> TODO: needs to be tested on another machine than my machine

**Video**: [https://drive.google.com/file/d/1F0YcMKZdtvaq8ooNR46JVS5QURHgQ5Hu/view?usp=sharing](https://drive.google.com/file/d/1F0YcMKZdtvaq8ooNR46JVS5QURHgQ5Hu/view?usp=sharing)
