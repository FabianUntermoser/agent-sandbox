# vworker

A QEMU VM that boots a Debian 13 guest preloaded like the host machine: pi, docker,
devcontainers, gh/glab, syncthing, tailscale, and a vault checkout it can write to.

Use it when a sandbox container is not enough: the worker owns its kernel, so docker
runs natively, `sudo` is real, and it can join the tailnet as its own node.

## Host prerequisites

`qemu-system-x86_64`, `qemu-img`, `mkfs.vfat` (dosfstools), `mcopy` (mtools), `rsync`, `curl`.

## Quick start

```sh
vm/vworker.sh create
vm/vworker.sh pair-vault
```

`create` downloads the Debian genericcloud image once, makes an overlay disk, boots it
with a cloud-init seed, waits for first-boot provisioning, then pushes host state.
`pair-vault` adds the guest as a device to the host syncthing config and shares the
vault folder with it.

## Commands

| Command | Effect |
| --- | --- |
| `create` | base image, disk, boot, provision, push host state |
| `start` / `stop` / `restart` | power control |
| `status` | running state plus guest summary |
| `ssh [cmd]` | shell or one-off command in the guest |
| `sync` | re-push pi/gh/glab/git config and re-run user provisioning |
| `pair-vault [addr]` | pair syncthing with the host, share the vault folder |
| `logs [n]` | serial console tail |
| `destroy --yes` | delete the VM directory |

Config lives in `~/.config/vworker/config` (`VM_RAM`, `VM_DISK`, `VM_CPUS`, `OLLAMA_BASE`,
`VM_NAME`, ...), secrets in `~/.config/vworker/secrets.env` (`TS_AUTHKEY`, `TS_HOSTNAME`).

## How it fits together

- `cloud-init/user-data` is the NoCloud seed: creates the user, installs base packages
  (`docker.io`, `syncthing`, `gh`, ...), and runs the system provisioning script on first
  boot. Node comes from the official tarball because pi imports `globSync` from `node:fs`
  (node 22+) and trixie ships node 20.
- `guest/provision-system.sh` runs as root once: docker, node, pi + devcontainer, glab,
  tailscale, syncthing user service, then writes `/var/lib/vworker/system-ok`.
- `guest/provision-user.sh` runs on every `create` and `sync` as root on the guest user's
  behalf: shell, pi provider endpoint, MCP pruning, git config, tailscale join, syncthing
  folder, `.stignore`.
- `vworker.sh` is the driver and lives on the host only.

Ollama stays on the host. QEMU user networking maps `10.0.2.2` to the host loopback, so
the guest's pi config points at `http://10.0.2.2:11434/v1` and the host keeps ollama bound
to `127.0.0.1`. The same address works on any host, local or remote.

Port forwards: `127.0.0.1:2222` to guest 22, `127.0.0.1:22002` to guest 22000 (syncthing).
The host keeps 22000 for itself.

## Vault sync

The guest folder is `sendreceive`, so notes written in the VM land in the vault and notes
edited on the host land in the VM. `~/notes` in the guest is a symlink into
`~/syncthing/Files/notes`.

The guest `.stignore` is a deny list, because whitelisting a subdirectory is impossible in
syncthing: re-including a directory drags its whole subtree in. Denied: `devices`,
`keepass`, `scripts`, `bruno`, `notes/.git`, `notes/.obsidian`, `notes/res`,
`notes/4ARCHIVE`, `notes/Clippings`, `notes/PUBLIC`, `notes/node_modules`. The worker sees
`notes/work`, `notes/3NOTES`, and the rest of the vault, about 56 MB.

### Do not wipe the guest syncthing index

`2026-09-13`: wiping the guest DB while the folder was `sendreceive` gave the guest a fresh
index ID, the host read that as "the worker deleted everything", and applied 261 deletions
to the vault. 224 were git-tracked and restored with `git checkout`. The rest were 18
`.git` internals and 6 Cryptomator stubs.

To re-pull from scratch: set the guest folder to `receiveonly`, wipe, then set it back.
Never delete the index in `sendreceive` mode.

```sh
# on the guest, K from ~/.local/state/syncthing/config.xml
curl -X PATCH -H "X-API-Key: $K" -H 'Content-Type: application/json' \
  -d '{"paused":true}' http://127.0.0.1:8384/rest/config/folders/jcuvm-8t2nt
```

Keep `~/syncthing/Files/.stfolder` in place. Without that marker syncthing refuses to scan
the folder and reports `folder marker missing`.

## Authentication state

Copied from the host: pi config (models, settings, AGENTS.md, mcp.json), `gh` and `glab`
config, git config. MCP servers pinned to host-only paths are pruned at provisioning time.

Not usable out of the box, because the credentials do not travel:

- `gh`: the host stores its token in the keyring, so the copied `hosts.yml` carries no
  token. Log in once inside the guest with `gh auth login` (device flow), or pipe a token:
  `gh auth token | vworker ssh 'gh auth login --with-token'`.
- `glab`: the copied OAuth refresh token is single use and already rotated, so API calls
  fail with `invalid_grant`. Use `glab auth login --token` or the device flow.
- git over SSH: the guest has no private key. Either add a new key (`ssh-keygen` in the
  guest, add the public half to GitHub/GitLab) or allow agent forwarding when connecting.

## Tailscale

Set `TS_AUTHKEY` (a reusable, tagged key, for example `tag:vworker`) in
`~/.config/vworker/secrets.env`, then `vworker sync`. Without it the join is skipped and
`vworker status` reports `tailscale: not-joined`.

## Running on another host

The script is host-agnostic: clone the repo on the target machine, `vworker create`, then
`vworker pair-vault <tailnet-address>:22000` using the address the guest can reach the
vault host on. The image URL is amd64 only; override `IMAGE_URL` for arm64.

## Troubleshooting

```sh
vm/vworker.sh logs 100                              # serial console
vm/vworker.sh ssh sudo cat /var/log/vworker-provision.log
vm/vworker.sh ssh 'systemctl --user status syncthing'
```

Guest syncthing REST: read the key with
`sed -n 's:.*<apikey>\([^<]*\)</apikey>.*:\1:p' ~/.local/state/syncthing/config.xml`, then
query `http://127.0.0.1:8384/rest/db/status?folder=jcuvm-8t2nt`.
