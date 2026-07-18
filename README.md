# agent-sandbox

Standalone, network-firewalled dev container for AI agents. Everything baked
into the image — no host symlinks, no per-machine setup beyond one-time build.

```sh
./setup.sh              # build image + install sandbox.sh
sandbox.sh claude       # run Claude Code in $PWD
sandbox.sh pi           # run pi coding agent
sandbox.sh codex        # run OpenAI Codex
sandbox.sh npm test     # run any command
```

## Requirements

- Docker with BuildKit (default in modern Docker Engine)
- Linux with iptables

## Usage

| Command | What it does |
|---|---|
| `sandbox.sh` | interactive shell |
| `sandbox.sh claude` | Claude Code (`--dangerously-skip-permissions`) |
| `sandbox.sh pi` | pi coding agent |
| `sandbox.sh codex` | OpenAI Codex |
| `sandbox.sh ollama launch <agent>` | agent on local models (starts ollama serve first) |
| `sandbox.sh <cmd>` | any command (npm test, pytest, git...) |
| `sandbox.sh --new` | force a fresh container |
| `sandbox.sh --build` | rebuild image |
| `sandbox.sh -v <cmd>` | run without tmux (logs to terminal) |

Mounts `$PWD` at its real host path so project keys match between host and
container (Claude `--resume` works, memory persists).

## How it works

The container runs with `--cap-add=NET_ADMIN --cap-add=NET_RAW`. On every start,
the entrypoint applies iptables rules that default-deny all egress, then
allowlists specific domains. The container is `--rm`, so the firewall re-applies
each time.

**Firewall allowlist** (edit `scripts/init-firewall.sh` to change):
Anthropic API, GitHub, GitLab, npm, PyPI, crates.io, Go proxy, ollama.com.

Auth and config are mounted from the host at runtime (`~/.claude`, `~/.pi`,
`~/.codex`, `~/.config/gh`, `~/.config/glab-cli`, `~/.gitconfig`). Nothing is
stored in the image.

## Project structure

```
├── Dockerfile              # baked image with all tools
├── Makefile                # build, setup, shell, claude, pi
├── docker-bake.hcl         # build config
├── config/                 # default shell configs
│   ├── zshrc.local
│   ├── bashrc.local
│   ├── aliasrc
│   ├── tmux.conf
│   └── claude-settings.json
└── scripts/
    ├── init-firewall.sh    # iptables rules
    ├── sandbox-entry.sh    # container entrypoint
    ├── sandbox.sh          # wrapper script (dispatch by arg)
    └── setup.sh            # one-time build + install
```

## License

MIT
