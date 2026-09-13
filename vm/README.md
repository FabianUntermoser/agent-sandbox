# vworker

A QEMU VM that boots a Debian 13 guest preloaded like the host machine: pi, docker,
devcontainers, gh/glab, syncthing, tailscale.

The worker is an isolated sandbox. It shares exactly one folder with the host, an empty
one made for it. It has no share of the vault and no path to the host filesystem. A
sendreceive peer can delete what it sees, so nothing worth keeping goes in that folder.

Use it when a sandbox container is not enough: the worker owns its kernel, so docker runs
natively, `sudo` is real, and it can join the tailnet as its own node.

## Host prerequisites

`qemu-system-x86_64`, `qemu-img`, `mkfs.vfat` (dosfstools), `mcopy` (mtools), `rsync`, `curl`.

## Quick start

```sh
vm/vworker.sh create
vm/vworker.sh pair-sandbox
```

`create` downloads the Debian genericcloud image into `~/.local/share/vworker/base.qcow2`
(kept across `destroy`), makes an overlay disk, boots it with a cloud-init seed, waits for
first-boot provisioning, then pushes host state. `pair-sandbox` creates the worker's own
folder in the host syncthing config and shares it with that one worker.

## Commands

| Command | Effect |
| --- | --- |
| `create` | base image, disk, boot, provision, push host state |
| `start` / `stop` / `restart` | power control |
| `status` | running state plus guest summary |
| `ssh [cmd]` | shell or one-off command in the guest |
| `sync` | re-push pi/gh/glab/git config and re-run user provisioning |
| `pair-sandbox [addr]` | pair syncthing with the host, share the worker's sandbox folder |
| `logs [n]` | serial console tail |
| `destroy --yes` | delete the VM directory and drop its syncthing device from the host |

Config lives in `~/.config/vworker/config` (`VM_RAM`, `VM_DISK`, `VM_CPUS`, `OLLAMA_BASE`,
`VM_NAME`, `SANDBOX_HOST_PATH`, `SANDBOX_FOLDER_ID`, ...), secrets in
`~/.config/vworker/secrets.env` (`TS_AUTHKEY`, `TS_HOSTNAME`).

## How it fits together

- `cloud-init/user-data` is the NoCloud seed: creates the user, installs base packages
  (`docker.io`, `syncthing`, `gh`, ...), and runs the system provisioning script on first
  boot. Node comes from the official tarball because pi imports `globSync` from `node:fs`
  (node 22+) and trixie ships node 20.
- `guest/provision-system.sh` runs as root once: docker, node, pi + devcontainer, glab,
  tailscale, syncthing user service, then writes `/var/lib/vworker/system-ok`.
- `guest/provision-user.sh` runs on every `create` and `sync` as root on the guest user's
  behalf: shell, pi provider endpoint, MCP pruning, git config, tailscale join, the sandbox
  folder.
- `vworker.sh` is the driver and lives on the host only.

Ollama stays on the host. QEMU user networking maps `10.0.2.2` to the host loopback, so
the guest's pi config points at `http://10.0.2.2:11434/v1` and the host keeps ollama bound
to `127.0.0.1`. The same address works on any host, local or remote.

Port forwards: `127.0.0.1:2222` to guest 22, `127.0.0.1:22002` to guest 22000 (syncthing).
The host keeps 22000 for itself.

## The sandbox folder

| Side | Path | Folder id |
| --- | --- | --- |
| host | `~/vworker` (`SANDBOX_HOST_PATH`) | `vworker` (`SANDBOX_FOLDER_ID`) |
| guest | `~/sandbox` | `vworker` |

Type is `sendreceive` on both sides and the device list holds exactly two entries: the host
and that worker. Files dropped in `~/vworker` land in the guest's `~/sandbox` and the other
way round, so the worker can hand results back. The host side has staggered versioning, so
a file the worker deletes is stashed in `~/vworker/.stversions`.

Rules that keep this safe:

- The sandbox holds disposable work only. Never put anything in `~/vworker` that you would
  not be fine losing.
- Never add the vault folder to a worker. If the worker needs vault content, copy the file
  in.
- One folder per worker. Two workers, two folders, so a reset worker can only ever claim
  about its own sandbox.

### Why the worker does not get the vault

`2026-09-13`: the first version of this VM shared the vault as `sendreceive` and used a
deny list to thin it out. While iterating on that list the guest syncthing index was wiped.
A wiped index gives the device a new generation, so its "I do not have this file" claims
beat the other devices' versions and the host applied 261 deletions to the vault. 224 files
were git-tracked and came back with `git checkout`. 18 `.git` internals and 6 Cryptomator
stubs were not tracked and were lost. Syncthing refuses to delete a non-empty directory
whose contents the remote ignores, and that guard is the only reason whole directories
survived.

The deny list was the wrong tool. A worker that must never touch real data does not get a
share of it at all.

## Syncthing rules

- Never delete a peer's index while the folder is `sendreceive`. Set the folder
  `receiveonly` first, wipe, then set it back.
- Keep `~/sandbox/.stfolder` in place. Without that marker syncthing refuses to scan the
  folder and reports `folder marker missing`.
- The local `.stignore` never travels. It cannot protect the other side.

To re-pull a sandbox from scratch:

```sh
curl -X PATCH -H "X-API-Key: $K" -H 'Content-Type: application/json' \
  -d '{"paused":true}' http://127.0.0.1:8384/rest/config/folders/vworker
```

## Authentication state

Copied from the host: pi config (models, settings, AGENTS.md, mcp.json), `gh` and `glab`
config, git config, ssh `known_hosts` and a sanitized `ssh/config`. MCP servers pinned to
host-only paths are pruned at provisioning time.

`gh` is logged in without any extra step: every `create` and `sync` reads the host token
(`gh auth token`, from the host keyring) and pipes it through ssh stdin into
`gh auth login --with-token` inside the guest. The token is never written to a file on the
host. `vworker ssh 'gh auth status'` shows the copied token, `gh api user` works.

`glab` is logged in for every host whose credential can work in a guest. The config is
rebuilt at provisioning time and keeps only hosts with a plaintext token; OAuth grants
(they cannot be refreshed in a guest) and keyring-only entries are left out, so no unusable
secret is copied and `glab auth status` exits clean. Verified: `glab api user` returns the
account, `glab api projects` lists 57 projects.

Git over SSH needs no key in the worker. `vworker ssh` forwards the host ssh-agent (`ssh -A`),
so clones and pushes inside the worker use your laptop's keys while the connection is open.
The guest keeps only public material: `known_hosts`, and a copy of the host `ssh/config` with
`IdentitiesOnly` and `IdentityFile` lines removed, because those pins name key files the guest
does not have and would stop it from offering the agent's keys. Verified from inside a worker:
`ssh -T git@github.com` greets the account, and shallow clones of a private GitHub repo and of
`gitlab.untermoser.synology.me:server/nextcloud-config` both land on disk. Add keys to the
agent with `ssh-add` on the host, never inside the worker.

## Tailscale

Set `TS_AUTHKEY` (a reusable, tagged key, for example `tag:vworker`) in
`~/.config/vworker/secrets.env`, then `vworker sync`. Without it the join is skipped and
`vworker status` reports `tailscale: not-joined`.

## Running on another host

The script is host-agnostic. Clone the repo on the target machine, then run the same two
commands. For a worker that reaches its host over a tailnet, pass the address:
`vworker pair-sandbox <tailnet-address>:22000`. The image URL is amd64 only; override
`IMAGE_URL` for arm64.

## Troubleshooting

```sh
vm/vworker.sh logs 100                              # serial console
vm/vworker.sh ssh sudo cat /var/log/vworker-provision.log
vm/vworker.sh ssh 'systemctl --user status syncthing'
```

Guest syncthing REST: read the key with
`sed -n 's:.*<apikey>\([^<]*\)</apikey>.*:\1:p' ~/.local/state/syncthing/config.xml`, then
query `http://127.0.0.1:8384/rest/db/status?folder=vworker`.
