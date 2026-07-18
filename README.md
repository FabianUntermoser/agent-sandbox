# agent-sandbox

Firewalled dev container for AI agents. Baked image, no host symlinks.

```sh
./setup.sh              # one-time: build + auth
sandbox.sh claude       # run in any project dir
sandbox.sh pi
sandbox.sh npm test
```

Default-deny egress. Allowlist: Anthropic, GitHub, GitLab, npm, PyPI, crates.io,
Go proxy, ollama.com. Edit `scripts/init-firewall.sh` to change.

Auth lives in a Docker volume (`agent-sandbox-config`), not the image.

MIT
