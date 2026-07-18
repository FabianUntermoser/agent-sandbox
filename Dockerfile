# syntax=docker/dockerfile:1
# Standalone firewalled dev container for AI agents.
# Dependencies grouped by agent so you can see what each needs.

ARG NODE_VERSION=22-bookworm
ARG NODE_DIGEST=sha256:5647be709086c696ff32edaaf1c70cd26d1da6ab2b39c32f3c7b4c4a31957e37

FROM node:${NODE_VERSION}@${NODE_DIGEST}

ARG TZ
ENV TZ="$TZ" \
    DEVCONTAINER=true \
    SHELL=/bin/zsh

# git, zsh, tmux, vim, fzf, ripgrep, fd, jq, python3, pipx
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
<<EOT
set -eux
apt-get update
apt-get install -y --no-install-recommends \
  less git procps sudo fzf zsh man-db unzip gnupg2 \
  ripgrep fd-find jq nano vim ffmpeg tmux \
  python3 python3-pip python3-venv pipx \
  iptables ipset iproute2 dnsutils ca-certificates curl \
  bubblewrap gh zstd
ln -s "$(command -v fdfind)" /usr/local/bin/fd
rm -rf /var/lib/apt/lists/*
EOT

RUN curl -fsSL https://ollama.com/install.sh | sh

RUN <<EOT
set -eux
curl -fsSL https://gitlab.com/gitlab-org/cli/-/releases/v1.50.0/downloads/glab_1.50.0_linux_amd64.tar.gz \
  -o /tmp/glab.tar.gz
tar -xzf /tmp/glab.tar.gz -C /usr/local/bin bin/glab
rm /tmp/glab.tar.gz
EOT

RUN <<EOT
set -eux
curl -fsSL https://github.com/anthropics/anthropic-cli/releases/download/v1.16.0/ant_1.16.0_linux_amd64.tar.gz \
  -o /tmp/ant.tar.gz
tar -xzf /tmp/ant.tar.gz -C /usr/local/bin ant
rm /tmp/ant.tar.gz
EOT

RUN curl -fsSL https://acli.atlassian.com/linux/latest/acli_linux_amd64/acli -o /usr/local/bin/acli \
  && chmod +x /usr/local/bin/acli

ARG USERNAME=node

COPY config/zshrc.local /home/$USERNAME/.zshrc.local
COPY config/bashrc.local /home/$USERNAME/.bashrc.local
COPY config/aliasrc /home/$USERNAME/.config/aliasrc
COPY config/tmux.conf /home/$USERNAME/.tmux.conf
RUN chown $USERNAME:$USERNAME /home/$USERNAME/.zshrc.local /home/$USERNAME/.bashrc.local \
  /home/$USERNAME/.config/aliasrc /home/$USERNAME/.tmux.conf \
  && echo '[ -f ~/.zshrc.local ] && source ~/.zshrc.local' >> /home/$USERNAME/.zshrc \
  && echo '[ -f ~/.bashrc.local ] && . ~/.bashrc.local' >> /home/$USERNAME/.bashrc

COPY config/claude-settings.json /home/$USERNAME/.claude/settings.json
RUN chown -R $USERNAME:$USERNAME /home/$USERNAME/.claude

COPY scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY scripts/generate-allowlist.sh /tmp/generate-allowlist.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /tmp/generate-allowlist.sh \
  && /tmp/generate-allowlist.sh > /etc/allowlist.sh \
  && rm /tmp/generate-allowlist.sh \
  && echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/init-firewall \
  && chmod 0440 /etc/sudoers.d/init-firewall

# claude: @anthropic-ai/claude-code
# pi:     @earendil-works/pi-coding-agent
# codex:  @openai/codex
ENV PATH=/home/$USERNAME/.local/bin:/home/$USERNAME/.local/pipx/bin:/home/$USERNAME/.npm-global/bin:$PATH \
    PIPX_BIN_DIR=/home/$USERNAME/.local/pipx/bin \
    NPM_CONFIG_PREFIX=/home/$USERNAME/.npm-global

RUN pipx install whisper-ctranslate2
RUN npm install -g @anthropic-ai/claude-code @earendil-works/pi-coding-agent @openai/codex

USER $USERNAME
WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "-c", "sudo /usr/local/bin/init-firewall.sh && exec \"$@\"", "bash"]
CMD ["zsh"]
