# agent-sandbox

Sandbox container for AI agents (Claude, Codex, pi).

## Features

- **Restrict agent to current directory** — only `$PWD` is writable.
- **Dynamic symlink resolution** — symlinks in `$PWD` are resolved and their real
  targets mounted, so files outside `$PWD` (repos, notes, assets) are accessible
  in-container.
- **Baked-in configs** — shell, aliasrc, claude settings and the CLIs (ollama,
  glab, ant, acli) are in the image, not mounted from host.
- **One inherited base** — `config/base.conf` lists everything else a sandbox gets
  from the host: agent configs, `~/.local/bin`, forge auth, tmux config. Add a
  script or skill to your dotfiles and the next sandbox has it, no edit here.
- **Knowledge stays out** — a project symlink into the vault's PARA layers,
  `~/.ssh` or `~/.gnupg` is refused and reported. `~/notes/work/<project>` is
  allowed, agent notes live there.
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

## Resume

Agent sessions live in the mounted config (`~/.pi`, `~/.claude/projects`), so they outlive
the container, and the project is mounted at its real host path, which is the key `pi` uses
to find the session for a directory.

```sh
sandbox.sh                    # container still up: reattaches, tmux layout intact
sandbox.sh pi -c              # container gone: continue the last session of this directory
sandbox.sh pi -r              # pick a session
sandbox.sh pi --session <id>  # exact session
sandbox.sh claude --resume <id>
```

tmux is per container: the layout dies with it (`--rm`), the conversation does not. The tmux
helpers in `config/tmux.conf` talk to the sandbox's own tmux server, so they list only what
runs in that container.

## What a sandbox inherits

`config/base.conf` is the single list. `make setup` installs it to
`~/.config/agent-sandbox/base.conf`, `sandbox.sh` reads it on every start, so
editing that file needs no rebuild and no edit in this repo.

```
# dir|file <path> [ro] [auth] [exclude=<glob,glob>]
dir   ~/.local/bin         ro exclude=*.old
file  ~/.tmux.conf
dir   ~/.pi                exclude=agent/npm,agent/git
```

Paths are `$HOME`-relative and symlinks are followed, so the stow farm in `$HOME`
is the manifest: a new script or skill appears in the sandbox by itself.

- `ro` is read-only inside the container; the worker VM always gets its own copy.
- `auth` is mounted only when the project manifest keeps credentials (`GIT_AUTH=true`).
- `exclude` is skipped when the worker VM copies the entry, mounts ignore it.

The container and the worker VM read the same file, so both see the same set.
`AGENTS` in `.sandbox.conf` still narrows it per project.

Deliberately not inherited: the host shell stack (both environments keep their own
zsh and history), `~/.ssh`, and the curated vault layers. Project symlinks into
those are refused with a message; an explicit `MOUNTS` entry overrides.

## Steering a running sandbox

`sandbox-panes.sh` talks to the tmux server inside a running container, so an agent
on the host can watch and instruct the agent in there.

```sh
sandbox-panes.sh ls                    # containers, panes, agent state, cwd
sandbox-panes.sh read stockis -n 60    # last 60 lines of its pane
sandbox-panes.sh send stockis "run the test suite"
sandbox-panes.sh wait stockis 300      # blocks until it stops working, prints the pane
sandbox-panes.sh keys stockis Escape   # raw keys when send is not enough
```

`<target>` is `<container>[:<session>[.<window>[.<pane>]]]`, short container names
work (`stockis`). Text goes through the tmux buffer, so dashes, quotes and newlines
survive. Container tmux is a separate server from the host one, the host sessions
are never touched.

## Paseo

Paseo spawns an agent as its own child process and drives it over stdio, so it
launches the sandbox in `--stdio` mode: no tmux, pipes instead of a tty, and the
rest of the argv forwarded into the container. Register the provider once in
`~/.paseo/config.json`, then `paseo reload`:

```json
{
  "agents": {
    "providers": {
      "pi-sandbox": {
        "extends": "pi",
        "label": "Pi (sandbox)",
        "command": ["/home/you/.local/bin/sandbox.sh", "--stdio", "--", "pi"]
      }
    }
  }
}
```

Paseo runs the command with the workspace it created as `$PWD`, so the container
mounts that worktree. Three details come from how paseo launches an agent: it
writes a merged `mcp.json` and its own integration extension into `/tmp` and
passes them as `--mcp-config` and `--extension`, both mounted read-only; a probe
runs with `$HOME` as the working directory, which is never mounted, so that run
keeps the container's own home; and the probe asks for `<command> --version`,
which is answered with the pi the image carries.

## VM worker

`vm/` boots a full Debian guest with the same tooling when a container is not enough:
its own kernel for docker and devcontainers, real `sudo`, a tailnet node of its own. The
worker is isolated: it gets its own empty synced folder and never a share of the vault. See
[vm/README.md](vm/README.md).

```sh
make vm-create     # boot and provision the worker
make vm-pair       # share the worker's own sandbox folder with it
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
