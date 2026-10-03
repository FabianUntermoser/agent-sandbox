# agent-sandbox

Sandbox container for AI agents (Claude, Codex, pi).

## Features

- **Restrict agent to current directory** — only `$PWD` is writable.
- **Dynamic symlink resolution** — symlinks in `$PWD` are resolved and their real
  targets mounted, so files outside `$PWD` (repos, notes, assets) are accessible
  in-container.
- **Baked-in configs** — shell, aliasrc, claude settings and the CLIs (ollama,
  glab, ant, acli) are in the image, not mounted from host.
- **Deny by default**: a sandbox gets the project and nothing else. `config/base.conf`
  is the catalogue of what it may inherit, and every entry needs a grant in the
  project's `.sandbox.conf`: agent configs, forge auth, `~/.local/bin`, tmux config.
- **Knowledge stays out** — a project symlink into the vault's PARA layers,
  `~/.ssh` or `~/.gnupg` is refused and reported. `~/notes/work/<project>` is
  allowed, agent notes live there.
- **Manifest-driven**: per-project `.sandbox.conf` grants what the project needs.
  `BASE=full` restores the old inherited set for a project that has no manifest.
- **Skills come from `.agents/skills/`** — pi discovers them there, the same set
  the host loads. No mount per skill: mounting one at the same path under `~/.pi`
  left a root-owned empty directory on the host and dropped that skill from every
  run after the first.
- **Default network: own bridge + firewall**: every sandbox runs on the dedicated
  `agent-sandbox-net` network, not the shared default bridge, with default-deny
  egress allowlisted in `scripts/init-firewall.sh` (Anthropic, GitHub, GitLab, npm,
  PyPI, ollama, …). A sibling container is not reachable. `--network=host` or
  `NETWORK=host` opts out for host services.
- **`--offline`**: the old name for the default bridge plus firewall.
- **Host services**: `HOST_SERVICES=ollama` is the one grant that opens the host
  gateway, for port 11434 only. Nothing else on the host or the sandbox network is
  reachable. The host ollama binds `127.0.0.1`, so pi's ollama models need
  `NETWORK=host`.
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
sandbox.sh --network=host pi       # host network, for the host ollama
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

Nothing, unless the project grants it. `config/base.conf` is the catalogue of what
a sandbox may inherit. `make setup` installs it to
`~/.config/agent-sandbox/base.conf` and `sandbox.sh` reads it on every start, so
editing that file needs no rebuild and no edit in this repo. An entry is mounted
only when its grant is on, and every grant defaults to off.

```
# dir|file <path> [ro] [auth] [grant=<KEY>] [exclude=<glob,glob>]
dir   ~/.pi                exclude=agent/npm,agent/git
dir   ~/.agents
dir   ~/.local/bin         ro grant=LOCAL_BIN exclude=*.old
file  ~/.tmux.conf         grant=TMUX
dir   ~/.config/gh         ro auth
```

- `grant=<KEY>` needs `<KEY>=true` in `.sandbox.conf`. The agent config dirs are
  granted by listing the agent in `AGENTS` (`AGENTS="pi claude codex"`).
- `auth` is mounted only with `GIT_AUTH=true` (forge credentials).
- `ro` is read-only inside the container; the worker VM always gets its own copy.
- `exclude` is skipped when the worker VM copies the entry, mounts ignore it.

Symlinks inside a mounted directory are not followed, so granting `~/.local/bin`
no longer drags in every repo the stow farm points at. A project symlink at the
top of the project is still resolved, so `~/notes/work/<project>` keeps working.

The container and the worker VM read the same file. The container honours the
grants; the guest has no manifest and copies the catalogue.

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

Drop a `.sandbox.conf` in any project to grant what it needs. Every key defaults
to off, and a project with no manifest gets only its own tree.

```bash
# .sandbox.conf, sourced by sandbox.sh (bash syntax)

AGENTS="pi claude"        # agent config dirs: pi, claude, codex
GIT_AUTH=true             # forge credentials (gh, glab, git)
LOCAL_BIN=true            # ~/.local/bin
TMUX=true                 # ~/.tmux.conf
NETWORK=host              # host networking; default is bridge + firewall
HOST_SERVICES=ollama      # reach a host service on the docker gateway
MOUNTS=(                  # extra host paths: "src:dest" per line
  # "/host/path:/container/path"
)

BASE=full                 # the whole inherited set, the pre-deny-by-default sandbox
```

`BASE=full` is the migration hatch: it turns on every grant still at its default,
so an explicit grant in the same manifest still narrows it. A project that has not
been migrated gets `BASE=full` first, then its own grants as it is tightened.

## License

MIT
