# agent-sandbox

Sandbox container for AI agents (Claude, Codex, pi).

## Features

- The sandbox mounts the project at its host path and nothing else. A host path arrives
  only through a `.sandbox.conf` grant, and `ro` makes that grant read-only in the
  container. A project without a manifest gets only its own tree, and prints a warning.
- A linked worktree works without the checkout it belongs to: the sandbox mounts the worktree
  and the git directory its `.git` file names, never the working tree around that directory.
- Sibling worktrees stay out of each other's way: the admin directory git keeps for every other
  worktree mounts read-only, so a run cannot write another worktree's index, HEAD or branch.
- A symlink at the top of the project is resolved and its target mounted in its place,
  so a checkout that links a shared repo, an asset tree, or `~/notes/work/<project>`
  stays reachable. Symlinks nested deeper are not followed, and a target in the vault,
  `~/.ssh`, or `~/.gnupg` is refused and reported.
- Shell, aliasrc, Claude settings, and the CLIs (ollama, glab, ant, acli) are in the
  image, not mounted from the host.
- `config/base.conf` is the catalogue of what a sandbox may inherit. Every entry needs a
  grant in the project's `.sandbox.conf`: agent configs, forge auth, `~/.local/bin`, and
  the tmux config. `BASE=full` is the one-line grant for the whole set.
- Skills come from `.agents/skills/`. With `pi` in `AGENTS` the sandbox mounts `~/.agents`,
  so pi finds the skills the host finds. Mounting one skill under `~/.pi` instead left a
  root-owned empty directory on the host and dropped that skill from every later run.
- Every sandbox runs on the `agent-sandbox-net` network, not the shared default bridge,
  with default-deny egress allowlisted in `scripts/init-firewall.sh` (Anthropic, GitHub,
  GitLab, npm, PyPI, ollama, and more). A sibling container is not reachable.
  `--network=host` or `NETWORK=host` opts out.
- `HOST_SERVICES=ollama` opens the host gateway on port 11434, and nothing else on the
  host or the sandbox network. The host ollama binds `127.0.0.1`, so pi's ollama models
  need `NETWORK=host`. `--offline` is the old name for the default bridge plus firewall.
- The project mounts at its real host path, so Claude `--resume` and the project key pi
  uses match between the host and the container.

## Usage

**Prerequisites:** Docker with BuildKit, Linux with iptables.

```sh
# build image
make build

# one-time setup (installs sandbox.sh and base.conf)
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

Agent sessions live in the mounted config directories, so they outlive the container. `~/.pi`
and `~/.claude/projects` mount only when the manifest grants the matching agent, and the
project is mounted at its real host path, which is the key `pi` uses to find the session for
a directory.

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
mounts that directory alone, not every repo the stow farm points at. A symlink at
the top of the project resolves and its target mounts in its place, so
`~/notes/work/<project>` stays reachable.

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
sandbox-panes.sh read myproject -n 60  # last 60 lines of its pane
sandbox-panes.sh send myproject "run the test suite"
sandbox-panes.sh wait myproject 300    # blocks until it stops working, prints the pane
sandbox-panes.sh keys myproject Escape # raw keys when send is not enough
```

`<target>` is `<container>[:<session>[.<window>[.<pane>]]]`, short container names
work (`myproject`). Text goes through the tmux buffer, so dashes, quotes and newlines
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
to off, and a project with no manifest gets only its own tree. `--manifest <path>`
sources a file outside the project instead, so one run can use a generated
manifest while the project stays where it is.

```bash
# .sandbox.conf, sourced by sandbox.sh (bash syntax)

AGENTS="pi claude"        # agent config dirs: pi, claude, codex
GIT_AUTH=true             # forge credentials (gh, glab, git)
LOCAL_BIN=true            # ~/.local/bin
TMUX=true                 # ~/.tmux.conf
NETWORK=host              # host networking; default is bridge + firewall
HOST_SERVICES=ollama      # open the host gateway on port 11434
MOUNTS=(                  # extra host paths: "src:dest" per line
  # "/host/path:/container/path"
)

BASE=full                 # the whole inherited set, the pre-deny-by-default sandbox
```

`BASE=full` is the migration hatch: it turns on every grant still at its default,
so an explicit grant in the same manifest still narrows it. A project that has not
been migrated gets `BASE=full` first, then its own grants as it is tightened.

## Security

Every image this repository builds or pins is scanned, and a fixable high-severity finding fails
the run. See [SECURITY.md](SECURITY.md).

## License

MIT
