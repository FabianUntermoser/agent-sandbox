# agent-sandbox

Sandbox container for AI agents (Claude, Codex, pi).

## Features

- The project mounts at its real host path and nothing else. A host path arrives only through a
  `.sandbox.conf` grant, and `ro` makes that grant read-only in the container.
- A linked worktree works without the checkout around it: the sandbox mounts the worktree and the
  git directory its `.git` file names. The admin directory of every other worktree mounts
read-only, so a run cannot write another worktree's index, HEAD or branch.
- A symlink at the top of the project resolves and its target mounts in its place, so a checkout
  that links a shared repo, an asset tree or `~/notes/work/<project>` stays reachable. Deeper
symlinks are not followed, and a target in the vault, `~/.ssh` or `~/.gnupg` is refused and
reported.
- Shell, aliasrc, Claude settings and the CLIs (ollama, glab, ant, acli) are in the image, not
  mounted from the host.
- Browser QA is in the image: Playwright with its pinned Chromium and every shared library it
  needs, reachable as `chromium` and `chromium-browser`, so no sandbox needs an egress grant to
  download a browser. `agent-browser` ships alongside it, pointed at the same binary through
  `AGENT_BROWSER_EXECUTABLE_PATH`. `make browser-check` renders a served fixture, clicks it and
  screenshots it in the shipped image, which is the gate.
- `agent-browser` cannot launch a browser in this container yet. It exits before DevTools with
  `chrome_crashpad_handler: --database is required` and `Chrome exited before providing DevTools
  URL`, on 0.27.0 and 0.39.1, with its own downloaded Chrome and with Playwright's, with and
  without `--no-sandbox` and `--disable-dev-shm-usage`, and with `--security-opt seccomp=unconfined`.
  The cause is not established, so none is claimed here. Playwright drives the same binary and
  renders, and `make browser-check` reports the gap without failing until the launcher is fixed.
- Every sandbox runs on its own network, with egress denied by default. [Egress](#egress) covers
  the allowlist, the host services and the ways out of it.
- `config/base.conf` is the catalogue of what a sandbox may inherit, and `BASE=full` grants the
  whole set. See [What a sandbox inherits](#what-a-sandbox-inherits).
- Skills come from `.agents/skills/`: with `pi` in `AGENTS` the sandbox mounts `~/.agents`, so pi
  finds the skills the host finds.
- `HOST_SERVICES=host:<port>` opens one port on the sandbox's own gateway, for a dev server that
  runs on the host, and needs no name to resolve.
- `HOST_SERVICES` opens one named service off the public internet, on a tailnet or on a LAN,
  without host networking. See [Egress](#egress).

## Egress

Every sandbox runs on the `agent-sandbox-net` network, not the shared default bridge, with egress
denied by default and allowlisted in `scripts/init-firewall.sh` (Anthropic, GitHub, GitLab, npm,
PyPI, ollama and more). A sibling container is not reachable. `--network=host` or `NETWORK=host`
opts out of it, and `--offline` is the old name for the default bridge plus firewall.

`HOST_SERVICES` in the manifest grants more than the allowlist carries:

- `ollama` opens the host gateway on port 11434. The host ollama binds `127.0.0.1`, so pi's ollama
  models need `NETWORK=host`.
- `<host>:<port>` opens the addresses that name answers with, on that port alone. The name is
  resolved when the sandbox starts, because the address behind it moves. If it resolves to no IPv4
  address, firewall initialization fails before installing any allow rules and the sandbox command
  does not start.

An answer inside the container's own network or inside any other docker network of the host is
refused, and so are loopback and the link-local metadata address, so a grant cannot be aimed at a
sibling container. A private address outside those networks, the host's own tailnet or LAN address
among them, opens like any other: that is what the grant is for, and it needs no host networking.

The launcher writes the grant, and the networks it may not reach, into a read-only file the
container mounts, never into the arguments: the sandbox user has sudo for the firewall script, so
an argument would let it widen its own egress. A sibling that runs with host networking has no
IPAM subnet, so this refusal does not cover it. Nothing else on the host or the sandbox network is
reachable.

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

Running `sandbox.sh` again in the same directory reattaches to the existing container. `--new`
forces a fresh one, and `--name <container>` names the container instead of `sandbox-<project>`,
which is what a caller that runs several containers for one project needs.

## Resume

Agent sessions live in the mounted config directories, so they outlive the container. `~/.pi` and
`~/.claude/projects` mount only when the manifest grants the matching agent, and the project is
mounted at its real host path, which is the key pi uses to find a directory's session. That is why
Claude `--resume` and pi's project key match between host and container.

```sh
sandbox.sh                    # container still up: reattaches, tmux layout intact
sandbox.sh pi -c              # container gone: continue the last session of this directory
sandbox.sh pi -r              # pick a session
sandbox.sh pi --session <id>  # exact session
sandbox.sh claude --resume <id>
```

tmux is per container: the layout dies with it (`--rm`), the conversation does not. The tmux
helpers in `config/tmux.conf` talk to the sandbox's own tmux server, so they list only what runs
in that container.

## What a sandbox inherits

Nothing, unless the project grants it, and a project without a manifest gets only its own tree and
prints a warning. `config/base.conf` is the catalogue of what a sandbox may inherit: `make setup`
installs it to `~/.config/agent-sandbox/base.conf`, and `sandbox.sh` reads it on every start, so
editing that file needs no rebuild and no edit in this repo. An entry is mounted only when its
grant is on, and every grant defaults to off.

```
# dir|file <path> [ro] [auth] [grant=<KEY>] [exclude=<glob,glob>]
dir   ~/.pi                exclude=agent/npm,agent/git
dir   ~/.agents
dir   ~/.local/bin         ro grant=LOCAL_BIN exclude=*.old
file  ~/.tmux.conf         grant=TMUX
dir   ~/.config/gh         ro auth
```

- `grant=<KEY>` needs `<KEY>=true` in `.sandbox.conf`. The agent config dirs are granted by
  listing the agent in `AGENTS` (`AGENTS="pi claude codex"`).
- `auth` is mounted only with `GIT_AUTH=true` (forge credentials).
- `ro` is read-only inside the container; the worker VM always gets its own copy.
- `exclude` is skipped when the worker VM copies the entry, mounts ignore it.

Symlinks inside a mounted directory are not followed, so granting `~/.local/bin` mounts that
directory alone, not every repo the stow farm points at. A skill mounted under `~/.pi` instead of
coming from `~/.agents` left a root-owned empty directory on the host and dropped that skill from
every later run.

The container and the worker VM read the same file. The container honours the grants; the guest
has no manifest and copies the catalogue.

Deliberately not inherited: the host shell stack (both environments keep their own zsh and
history), `~/.ssh`, and the curated vault layers. Project symlinks into those are refused with a
message; an explicit `MOUNTS` entry overrides.

The rule the catalogue follows: **anything the host pi loads is read-only in here.** That is
`~/.pi/agent/extensions`, `~/.pi/agent/npm` (the packages `settings.json` resolves) and
`~/.pi/agent/git` (the checkouts extension packages are built from). A sandbox that could write to
them would be handing the host code to run at its next start. `scripts/sandbox-agent-mounts.test.sh`
pins each one against the shipped catalogue, so the rule survives the next edit.

The reverse also holds: a tool the sandbox's own extensions call has to exist in here. The image
ships `/usr/local/bin/hypa` as a shim over the mounted package tree, because the host shim execs an
absolute path under the operator's home that this container does not have.

## Tools

A tool is one data file in `config/tools.d/`, installed by `make setup` to
`~/.config/agent-sandbox/tools.d/`. A manifest grants it by name, `TOOLS="linear"`, and the run
mounts what the file names. Nothing in this repo, the image or a launcher knows any tool by name,
so a new tool is a new file plus that key: no edit here, no image rebuild.

```
# The skill directory is mounted read-only.
SKILL_HOST=~/.agents/skills/linear
SKILL_CONTAINER=/home/node/.agents/skills/linear
# A credential is mounted as one file, never a directory.
CRED_HOST=~/.agent-secrets/linear-app.env
CRED_CONTAINER=/home/node/.agent-secrets/linear-app.env
# The CLI is mounted at its resolved host path (not through a stow-farm link).
CLI_HOST=~/.agents/skills/linear/scripts/linear-api.sh
CLI_CONTAINER=/usr/local/bin/linear-api.sh
# Egress is resolved at start.
HOSTS=api.linear.app:443
```

- Every host key needs its `*_CONTAINER`; half a pair stops the run.
- `CRED_HOST` must be a regular file. A directory would hand over every key beside the one named.
- `CLI_HOST` is mounted at its resolved path, so a stow-farm shim arrives as the script and the
  farm stays out of the container.
- `HOSTS` is a `<host>:<port>` pair per entry. The launcher writes them into the read-only grant
  file the firewall reads, so egress is resolved when the container starts, never at build time,
  and a tool that needs a new domain needs no rebuild.
- Naming the tool is the whole of the opt-in. A catalogue entry nobody names grants nothing, and a
  broken one cannot stop a run that does not ask for it.
- A destination another grant already holds, a host path without its destination, a destination that
  is not absolute or that carries a colon or a parent segment, duplicate keys, a key with no value,
  an unknown key, an unknown tool name, a port outside 1..65535 and a name that cannot resolve to an
  IPv4 address all stop the run instead of silently dropping a requested grant.
- A tool naming the same file an agent directory already mounts at that path is granted, not a
  collision: `AGENTS="pi"` with `TOOLS="linear"` is the case, and the mount stays read-only.
- A grant may not reach the vault or a key: the check the base catalogue applies is applied here
  too, so `CRED_HOST=~/.ssh/id_ed25519` is refused rather than mounted.

A tool that needs a system package or a daemon is the exception: that is an image layer plus a
service grant, and it is documented in the tool's own file.

## Permissions inside the sandbox

Docker is the security boundary, so the agent inside does not stop for approval. `make setup` also
installs `config/pi-permission-policy.json` to `~/.config/agent-sandbox/`, and a `pi` run copies it
into the project at `.pi/extensions/pi-permission-system/config.json` when the project has none.
That is the only scope a sandbox can supply: the host policy is a symlink the container never
resolves, and mounting it would hand a sandbox the host's own rule set.

The policy is yolo with the destructive list still asking: `rm -rf`, a volume drop, `git push`,
`gh pr`/`release`/`api`, a publish, a deploy, `docker push`, and a deny on anything that takes a
password or an API key. A project that carries its own policy keeps it, so a repository can narrow
itself and the launcher will not overwrite that file. `PI_POLICY=<file>` names a different template
for one run.

## Steering a running sandbox

`sandbox-panes.sh` talks to the tmux server inside a running container, so an agent on the host
can watch and instruct the agent in there.

```sh
sandbox-panes.sh ls                    # containers, panes, agent state, cwd
sandbox-panes.sh read myproject -n 60  # last 60 lines of its pane
sandbox-panes.sh send myproject "run the test suite"
sandbox-panes.sh wait myproject 300    # blocks until it stops working, prints the pane
sandbox-panes.sh keys myproject Escape # raw keys when send is not enough
```

`<target>` is `<container>[:<session>[.<window>[.<pane>]]]`, and short container names work
(`myproject`). Text goes through the tmux buffer, so dashes, quotes and newlines survive.
Container tmux is a separate server from the host one, and the host sessions are never touched.

## Paseo

Paseo spawns an agent as its own child process and drives it over stdio, so it launches the
sandbox in `--stdio` mode: no tmux, pipes instead of a tty, and the rest of the argv forwarded
into the container. Register the provider once in `~/.paseo/config.json`, then `paseo reload`:

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

Paseo runs the command with the workspace it created as `$PWD`, so the container mounts that
worktree. Three details come from that launch: it writes a merged `mcp.json` and its own
integration extension into `/tmp` and passes them as `--mcp-config` and `--extension`, both
mounted read-only; its probe runs with `$HOME` as the working directory, which is never mounted,
so that run keeps the container's home; and the probe asks for `<command> --version`, answered by
the pi the image carries.

## VM worker

`vm/` boots a full Debian guest with the same tooling when a container is not enough: its own
kernel for docker and devcontainers, real `sudo`, a tailnet node of its own. The worker is
isolated: it gets its own empty synced folder and never a share of the vault. See
[vm/README.md](vm/README.md).

```sh
make vm-create     # boot and provision the worker
make vm-pair       # share the worker's own sandbox folder with it
make vm-status
```

## Per-project manifest

Drop a `.sandbox.conf` in any project to grant what it needs. Every key defaults to off.
`--manifest <path>` sources a file outside the project instead, so one run can use a generated
manifest while the project stays where it is.

The manifest is read on the host and mounted read-only inside the container, so a sandbox cannot
rewrite its own grants for a later run, a `MOUNTS` line included. One passed with `--manifest`
from outside the project is not mounted at all, so a run that exposes the tree holding it
writable is refused instead. A project that carries no manifest has nothing to fence, so a run
there can leave one behind: a project an untrusted agent works in wants a manifest of its own.

```bash
# .sandbox.conf, sourced by sandbox.sh (bash syntax)

AGENTS="pi claude"        # agent config dirs: pi, claude, codex
GIT_AUTH=true             # forge credentials (gh, glab, git)
LOCAL_BIN=true            # ~/.local/bin
TMUX=true                 # ~/.tmux.conf
NETWORK=host              # host networking; default is bridge + firewall
HOST_SERVICES=ollama      # open the host gateway on port 11434
HOST_SERVICES=host:1313   # or any one port on the gateway, for a dev server on the host
HOST_SERVICES=name:443    # or one name the host routes to, on that port
TOOLS="linear"            # tools granted from ~/.config/agent-sandbox/tools.d
MOUNTS=(                  # extra host paths: "src:dest" per line
  # "/host/path:/container/path"
)

BASE=full                 # the whole inherited set, the pre-deny-by-default sandbox
```

`BASE=full` is the migration hatch: it turns on every grant still at its default, so an explicit
grant in the same manifest still narrows it. A project that has not been migrated gets `BASE=full`
first, then its own grants as it is tightened.

## License

MIT
