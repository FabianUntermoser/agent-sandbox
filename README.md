# agent-sandbox

A standalone, network-firewalled dev container for running AI agents (Claude,
pi, codex) or any command against `$PWD` — everything baked into the image, no
host symlinks.

```sh
# one-time setup
./setup.sh

# run in any project directory
sandbox.sh
sandbox.sh claude
sandbox.sh pi
sandbox.sh codex
sandbox.sh ollama launch claude
sandbox.sh --new          # force fresh container
sandbox.sh --build        # rebuild image
sandbox.sh -v npm test    # run without tmux
sandbox.sh pytest         # any command
```

Mounts `$PWD` at its real host path so project keys match host (Claude
`--resume` works, memory persists). Auth mounted from host at runtime
(`~/.claude`, `~/.pi`, `~/.codex`, `~/.config/gh`, `~/.config/glab-cli`,
`~/.gitconfig`). Nothing stored in the image.

## How it works

Default-deny egress firewall via iptables. Allowlist: Anthropic API, GitHub,
GitLab, npm, PyPI, crates.io, Go proxy, ollama.com. Edit
`scripts/init-firewall.sh` to change. Re-applied on every container start
(`--rm` means fresh netns each time).

## Project structure

```
├── Dockerfile
├── Makefile
├── docker-bake.hcl
├── config/                 # default shell configs
└── scripts/
    ├── init-firewall.sh
    ├── sandbox-entry.sh
    ├── sandbox.sh
    └── setup.sh
```

## License

MIT
