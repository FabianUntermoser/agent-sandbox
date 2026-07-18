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

# ── Base ──────────────────────────────────────
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
  iptables ipset iproute2 dnsutils ca-certificates curl
ln -s "$(command -v fdfind)" /usr/local/bin/fd
rm -rf /var/lib/apt/lists/*
EOT

# ── codex ─────────────────────────────────────
# bubblewrap: sandbox for codex subprocesses
RUN apt-get install -y --no-install-recommends bubblewrap && rm -rf /var/lib/apt/lists/*

# ── ollama ────────────────────────────────────
RUN curl -fsSL https://ollama.com/install.sh | sh

# ── gh (GitHub CLI) ───────────────────────────
RUN apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/*

# ── glab (GitLab CLI) ─────────────────────────
RUN <<EOT
set -eux
curl -fsSL https://gitlab.com/gitlab-org/cli/-/releases/v1.50.0/downloads/glab_1.50.0_linux_amd64.tar.gz \
  -o /tmp/glab.tar.gz
tar -xzf /tmp/glab.tar.gz -C /usr/local/bin bin/glab
rm /tmp/glab.tar.gz
EOT

# ── acli (Anthropic CLI) ───────────────────────
RUN <<EOT
set -eux
curl -fsSL https://github.com/anthropics/cli/releases/download/v0.1.0/acli-linux-amd64.tar.gz \
  -o /tmp/acli.tar.gz
tar -xzf /tmp/acli.tar.gz -C /usr/local/bin acli
rm /tmp/acli.tar.gz
EOT

ARG USERNAME=node

# ── Shell configs ─────────────────────────────
COPY config/zshrc.local /home/$USERNAME/.zshrc.local
COPY config/bashrc.local /home/$USERNAME/.bashrc.local
COPY config/aliasrc /home/$USERNAME/.config/aliasrc
COPY config/tmux.conf /home/$USERNAME/.tmux.conf
RUN chown $USERNAME:$USERNAME /home/$USERNAME/.zshrc.local /home/$USERNAME/.bashrc.local \
  /home/$USERNAME/.config/aliasrc /home/$USERNAME/.tmux.conf \
  && echo '[ -f ~/.zshrc.local ] && source ~/.zshrc.local' >> /home/$USERNAME/.zshrc \
  && echo '[ -f ~/.bashrc.local ] && . ~/.bashrc.local' >> /home/$USERNAME/.bashrc

# ── Claude settings ───────────────────────────
COPY config/claude-settings.json /home/$USERNAME/.claude/settings.json
RUN chown -R $USERNAME:$USERNAME /home/$USERNAME/.claude

# ── Firewall + entrypoint ─────────────────────
COPY scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY scripts/sandbox-entry.sh /usr/local/bin/sandbox-entry.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/sandbox-entry.sh \
  && echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/init-firewall \
  && chmod 0440 /etc/sudoers.d/init-firewall

# ── Agent CLIs ────────────────────────────────
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
ENTRYPOINT ["/usr/local/bin/sandbox-entry.sh"]
CMD ["zsh"]
