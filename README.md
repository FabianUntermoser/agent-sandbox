# agent-sandbox

Standalone, network-firewalled dev container for running AI agents (Claude, pi,
codex) or any command against `$PWD`. Everything is baked into the image — no
host symlinks, no per-machine setup beyond one-time auth provisioning.

## Quick start

```sh
# One-time: build image + provision auth
./setup.sh

# Run in any project directory
sandbox.sh              # interactive shell
sandbox.sh claude       # Claude Code
sandbox.sh pi           # pi coding agent
sandbox.sh npm test     # any command
```

## Features

- **Default-deny egress firewall** — only allowlisted domains (Anthropic, GitHub,
  npm, PyPI, etc.) can be reached. Applied on every container start.
- **All tools baked in** — ollama, gh, glab, acli, Claude Code, pi, codex, fzf,
  ripgrep, fd, jq, vim, tmux, zsh, python3, pipx.
- **Agent-agnostic** — dispatch by first arg. Claude, pi, codex, ollama all work.
- **Persistent auth** — credentials live in a named Docker volume, not the image.
- **Works in any dir** — mounts `$PWD` at its real host path so project keys match.

## Requirements

- Docker with BuildKit (default in modern Docker Engine)
- Linux (iptables-based firewall)

## Setup

Run `./setup.sh` once. It will:

1. Prompt for your git name/email
2. Copy auth from your host (`~/.claude`, `~/.pi`, `~/.codex`, `~/.config/gh`,
   `~/.config/glab-cli`) into a persistent Docker volume
3. Build the image
4. Install `sandbox.sh` to `~/.local/bin`

## How it works

The container runs with `--cap-add=NET_ADMIN --cap-add=NET_RAW`. On every start,
the entrypoint applies iptables rules that default-deny all egress traffic, then
allowlists specific domains. The container is `--rm` (ephemeral), so the firewall
must re-apply each time — the entrypoint handles this.

Auth and config live in a named Docker volume (`agent-sandbox-config`), not the
image, so you can rebuild without losing login state.

## Firewall allowlist

Edit `ALLOWED_DOMAINS` in `init-firewall.sh` and rebuild to add/remove domains.

Default allowlist: Anthropic API, GitHub, GitLab, npm, PyPI, crates.io, Go
proxy, ollama.com.

## License

MIT
