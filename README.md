# agent-sandbox

<p align="left">
  <img alt="GitHub" src="https://img.shields.io/github/license/FabianUntermoser/agent-sandbox?color=blue&style=flat-square">
  <img alt="GitHub Repo stars" src="https://img.shields.io/github/stars/FabianUntermoser/agent-sandbox?style=flat-square">
  <img alt="GitHub last commit" src="https://img.shields.io/github/last-commit/FabianUntermoser/agent-sandbox?color=blue&style=flat-square">
</p>

Sandbox container for AI agents (Claude, Codex, pi).

### Getting started

**Prerequisites:** Docker with BuildKit, Linux with iptables.

```sh
# one-time setup
./setup.sh

# run in any project directory
sandbox.sh                    # interactive shell
sandbox.sh claude             # Claude Code
sandbox.sh pi                 # pi coding agent
sandbox.sh codex              # OpenAI Codex
sandbox.sh ollama launch claude  # agent on local models
sandbox.sh --new              # force fresh container
sandbox.sh --build            # rebuild image
sandbox.sh -v npm test        # run without tmux
sandbox.sh pytest             # any command
```

Running `sandbox.sh` again in the same directory reattaches to the existing
container. `--new` forces a fresh one.

### Features

- **Default-deny egress firewall** — only allowlisted domains can be reached
  (Anthropic, GitHub, GitLab, npm, PyPI, crates.io, Go proxy, ollama.com).
  Edit `scripts/init-firewall.sh` to change.
- **Auth from host** — mounts `~/.claude`, `~/.pi`, `~/.codex`, `~/.config/gh`,
  `~/.config/glab-cli`, `~/.gitconfig` at runtime. Nothing stored in the image.
- **Works in any directory** — mounts `$PWD` at its real host path so project
  keys match (Claude `--resume` works, memory persists).

### Build

```sh
make build
# or
docker buildx bake --load
```

### License

MIT
