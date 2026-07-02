# Remote-SSH template — adds an OpenSSH server on top of a Docker-provided
# sandbox template so VSCode Remote-SSH can connect to the sandbox.
#
# Built by ./build.sh (image identity lives in config.env). The per-boot bits
# (start sshd, sync proxy env) are NOT baked here — a saved image can't carry
# startup behaviour, so they stay in kit/spec.yaml.
ARG BASE_IMAGE=docker/sandbox-templates:claude-code-docker
FROM ${BASE_IMAGE}

LABEL maintainer="@philippecharriere494"

ARG USER_NAME=agent
ENV TERM=xterm-256color
ENV COLORTERM=truecolor
ENV SHELL=/bin/bash

USER root
RUN <<'EOF'
set -eux
apt-get -o DPkg::Lock::Timeout=600 update
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -yy --no-install-recommends openssh-server
apt-get clean
rm -rf /var/lib/apt/lists/*
mkdir -p /run/sshd && chmod 0755 /run/sshd

# ~/.ssh with the ownership/modes sshd insists on.
install -d -m 0700 -o "${USER_NAME}" -g "${USER_NAME}" /home/${USER_NAME}/.ssh
touch /home/${USER_NAME}/.ssh/authorized_keys
chown "${USER_NAME}:${USER_NAME}" /home/${USER_NAME}/.ssh/authorized_keys
chmod 0600 /home/${USER_NAME}/.ssh/authorized_keys

# Expose user-local bins (claude, npm-global) to non-login SSH sessions.
touch /etc/sandbox-persistent.sh
grep -qF '/home/'"${USER_NAME}"'/.local/bin' /etc/sandbox-persistent.sh || \
  printf '\n# remote-ssh: expose user-local bins to SSH sessions\nexport PATH="/home/%s/.local/bin:/usr/local/share/npm-global/bin:$PATH"\n' "${USER_NAME}" >> /etc/sandbox-persistent.sh

# Key-only sshd, this user only.
cat > /etc/ssh/sshd_config.d/10-sandbox.conf <<CONF
Port 22
ListenAddress 0.0.0.0
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile %h/.ssh/authorized_keys
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
AcceptEnv LANG LC_*
ClientAliveInterval 60
ClientAliveCountMax 3
AllowUsers ${USER_NAME}
CONF
chmod 0644 /etc/ssh/sshd_config.d/10-sandbox.conf
ssh-keygen -A
EOF

USER ${USER_NAME}
