# syntax=docker/dockerfile:1
# Standalone firewalled dev container for AI agents.
# Dependencies grouped by agent so you can see what each needs.

ARG NODE_VERSION=24-bookworm-slim
ARG NODE_DIGEST=sha256:51b1100cc2a83d370c6a60952e3f2989c8a43159d0e38586e090f3b3326efefd

FROM node:${NODE_VERSION}@${NODE_DIGEST}

ARG TZ
ENV TZ="$TZ" \
    DEVCONTAINER=true \
    SHELL=/bin/zsh

# git, zsh, tmux, vim, fzf, ripgrep, fd, jq, python3, pipx, rofi
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
  bubblewrap gh zstd rofi xdg-utils
ln -s "$(command -v fdfind)" /usr/local/bin/fd
rm -rf /var/lib/apt/lists/*
EOT

RUN curl -fsSL https://ollama.com/install.sh | sh

RUN <<EOT
set -eux
curl -fsSL https://gitlab.com/gitlab-org/cli/-/releases/v1.121.0/downloads/glab_1.121.0_linux_amd64.tar.gz \
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

# worktrunk (wt) is pinned here but not installed in the image: this base ships git
# 2.39 and wt needs 2.43+, so the worker guest (Debian 13) installs it from these two
# pins, giving both ends one version that cannot drift.
ARG WORKTRUNK_VERSION=0.77.0
ARG WORKTRUNK_SHA256=8976ae756d31a80a330e134e9140b098818357292b318991a94b7ee53451da02

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

# the tmux helper scripts are mounted from the host at run time (see sandbox.sh)
RUN install -d -o $USERNAME -g $USERNAME /home/$USERNAME/.local/bin

COPY scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY scripts/generate-allowlist.sh /tmp/generate-allowlist.sh
COPY scripts/public-ip.sh /usr/local/lib/public-ip.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /tmp/generate-allowlist.sh \
  && DOMAINS_FILE=/etc/allowlist-domains /tmp/generate-allowlist.sh > /etc/allowlist.sh \
  && rm /tmp/generate-allowlist.sh \
  && echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/init-firewall \
  && chmod 0440 /etc/sudoers.d/init-firewall

# claude: @anthropic-ai/claude-code
# pi:     @earendil-works/pi-coding-agent
# codex:  @openai/codex
ENV PATH=/home/$USERNAME/.local/bin:/home/$USERNAME/.local/pipx/bin:/home/$USERNAME/.npm-global/bin:$PATH \
    PIPX_BIN_DIR=/home/$USERNAME/.local/pipx/bin \
    NPM_CONFIG_PREFIX=/home/$USERNAME/.npm-global \
    AGENT_BROWSER_EXECUTABLE_PATH=/usr/local/bin/chromium-headless-shell \
    AGENT_BROWSER_ARGS=--no-sandbox,--disable-dev-shm-usage

RUN pipx install whisper-ctranslate2
RUN npm install -g @anthropic-ai/claude-code @earendil-works/pi-coding-agent @openai/codex agent-browser@0.39.1

# Browser QA. This base ships neither a browser nor the libraries one needs, and the
# runtime firewall allows no download, so Playwright installs the full Chromium build and
# its matching headless_shell here, where the build has network. Playwright uses the full
# build for its direct test; agent-browser uses headless_shell because the full binary's
# crashpad handler fails at startup in this container.
ARG PLAYWRIGHT_VERSION=1.56.1
ENV PLAYWRIGHT_BROWSERS_PATH=/home/$USERNAME/.cache/ms-playwright
RUN npm install -g playwright@${PLAYWRIGHT_VERSION} \
  && npx --yes playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium \
  && chown -R $USERNAME:$USERNAME /home/$USERNAME/.cache \
  && ln -sf "$(ls -d /home/$USERNAME/.cache/ms-playwright/chromium-*/chrome-linux/chrome | head -1)" /usr/local/bin/chromium \
  && headless_shell="$(find /home/$USERNAME/.cache/ms-playwright -type f -path '*/chromium_headless_shell-*/chrome-linux/headless_shell' -print -quit)" \
  && test -x "$headless_shell" \
  && ln -sf "$headless_shell" /usr/local/bin/chromium-headless-shell \
  && ln -sf /usr/local/bin/chromium /usr/local/bin/chromium-browser \
  && ln -sf /home/$USERNAME/.npm-global/bin/agent-browser /usr/local/bin/agent-browser \
  && ln -sf /home/$USERNAME/.npm-global/bin/playwright /usr/local/bin/playwright

# The hypa CLI ships as a shim over the package tree the agent mounts, never over a host path: the
# host shim execs an absolute path under the operator's home, which does not exist in here.
RUN printf '#!/bin/sh\nexec /home/%s/.pi/agent/npm/node_modules/@hypabolic/hypa-linux-x64/bin/hypa "$@"\n' \
  "$USERNAME" >/usr/local/bin/hypa && chmod 755 /usr/local/bin/hypa

USER $USERNAME
WORKDIR /workspace
ENTRYPOINT ["/bin/bash", "-c", "exec \"$@\"", "bash"]
CMD ["zsh"]
