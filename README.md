# agent-sandbox

Sandbox container for AI agents (Claude, Codex, pi).

## Features

- **Restrict agent to current directory** — only `$PWD` is writable.
- **Dynamic symlink resolution** — symlinks in `$PWD` are resolved and their real
  targets mounted, so files outside `$PWD` (repos, notes, assets) are accessible
  in-container.
- **Baked-in configs** — shell, tmux, aliasrc, claude settings, CLIs (ollama,
  glab, ant, acli) are in the image, not mounted from host.
- **Auth-only mounts** — only agent configs (claude, pi, codex) and git auth
  are mounted from host. Everything else is self-contained.
- **Manifest-driven** — per-project `.sandbox.conf` controls which agents and
  mounts are enabled. Defaults work for most projects.
- **Skill merge** — `.agents/skills/` skills are merged into pi's skill
  directory so pi discovers all skills (worknotes, blog, etc.).
- **Default network: host** — uses `--network=host` for direct host ollama
  access (already authenticated). No firewall in default mode.
- **`--offline` mode** — restricts network to allowlisted domains only
  (Anthropic, GitHub, GitLab, npm, PyPI, ollama, …). Uses Docker bridge
  network + firewall.
- **Works in any directory** — mounts at real host path so Claude `--resume`
  and project keys match between host and container.

## Usage

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
sandbox.sh claude --dangerously-skip-permissions
sandbox.sh codex
sandbox.sh pi
sandbox.sh ollama launch claude   # ollama-managed agent launch
sandbox.sh --offline pi            # restricted network, no cloud models
```

Running `sandbox.sh` again in the same directory reattaches to the existing
container. `--new` forces a fresh one.

## VM worker

`vm/` boots a full Debian guest with the same tooling when a container is not enough:
its own kernel for docker and devcontainers, real `sudo`, a tailnet node of its own, and
a vault checkout it can write to. See [vm/README.md](vm/README.md).

```sh
make vm-create     # boot and provision the worker
make vm-pair       # share the vault folder with it
make vm-status
```

## Per-project manifest

Drop a `.sandbox.conf` in any project to override defaults:

```bash
# .sandbox.conf — sourced by sandbox.sh (bash syntax)

# Agents to enable (space-separated, empty to disable)
AGENTS="pi claude codex"

# Additional bind mounts: "src:dest" per line
MOUNTS=(
  # "/host/path:/container/path"
)
```

No manifest = all defaults (pi + claude + codex, git auth, skill merge).

## License

MIT
