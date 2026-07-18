# agent-sandbox

Sandbox container for AI agents (Claude, Codex, pi).

## Features

- **Restrict agent to current directory** — only `$PWD` is writable.
- **Dynamic symlink resolution** — symlinks in `$PWD` are resolved and their real
  targets mounted, so files outside `$PWD` (repos, notes, assets) are accessible
  in-container.
- **Baked-in configs** — shell, tmux, aliasrc, claude settings, CLIs (ollama,
  glab, ant, acli) are in the image, not mounted from host.
- **Auth-only mounts** — only claude credentials, pi, codex, gh, glab, git
  config are mounted from host. Everything else is self-contained.
- **Network firewalled** — default-deny egress, allowlisted domains only
  (Anthropic, GitHub, GitLab, npm, PyPI, ollama, …).
- **Works in any directory** — mounts at real host path so Claude `--resume`
  and project keys match between host and container.
- **Startup log** — prints project dir and any resolved symlinks.

## Usage

### Getting started

**Prerequisites:** Docker with BuildKit, Linux with iptables.

```sh
# build image
make build

# one-time setup (installs sandbox.sh to ~/.local/bin)
make setup

# run in any project directory
make shell                 # interactive shell
make claude                # Claude Code
make pi                    # pi coding agent

# or use the script directly
sandbox.sh --new

# start an agent
sandbox.sh claude --dangerously-skip-permissions
sandbox.sh codex
sandbox.sh pi
sandbox.sh ollama launch claude
```

Running `sandbox.sh` again in the same directory reattaches to the existing
container. `--new` forces a fresh one.

### Environment

- `SANDBOX_REPO` — path to agent-sandbox repo (default: `~/repos/dots/agent-sandbox`)

### License

MIT
