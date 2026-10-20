build:
	docker buildx bake --load

check:
	bash -n scripts/*.sh
	./scripts/public-ip.sh --self-check
	./scripts/sandbox-agent-mounts.test.sh
	./scripts/sandbox-manifest.test.sh
	./scripts/sandbox-tools.test.sh
	./scripts/sandbox-name.test.sh
	./scripts/sandbox-git-fence.test.sh
	./scripts/sandbox-firewall.test.sh

# Real container: the browser is what it proves, so it needs docker and the image.
browser-check:
	./scripts/sandbox-browser.test.sh

# Real containers: the mounts are what they prove, so they need docker and the image.
worktree-check:
	./scripts/sandbox-worktree.test.sh
	./scripts/sandbox-worktree-siblings.test.sh
	./scripts/sandbox-git-hooks.test.sh

setup:
	./scripts/setup.sh

uninstall:
	rm -f $(HOME)/.local/bin/sandbox.sh

shell: build
	./scripts/sandbox.sh shell

claude: build
	./scripts/sandbox.sh claude

pi: build
	./scripts/sandbox.sh pi

vm-create:
	./vm/vworker.sh create

vm-start:
	./vm/vworker.sh start

vm-stop:
	./vm/vworker.sh stop

vm-status:
	./vm/vworker.sh status

vm-sync:
	./vm/vworker.sh sync

vm-pair:
	./vm/vworker.sh pair-sandbox

vm-destroy:
	./vm/vworker.sh destroy --yes

.PHONY: build check browser-check worktree-check setup uninstall shell claude pi vm-create vm-start vm-stop vm-status vm-sync vm-pair vm-destroy
