build:
	docker buildx bake --load

check:
	bash -n scripts/*.sh
	./scripts/public-ip.sh --self-check
	./scripts/sandbox-agent-mounts.test.sh
	./scripts/sandbox-manifest.test.sh
	./scripts/sandbox-name.test.sh
	./scripts/scan-digests.test.sh

# Real containers: the mounts are what they prove, so they need docker and the image.
worktree-check:
	./scripts/sandbox-worktree.test.sh
	./scripts/sandbox-worktree-siblings.test.sh

# reports land in security-out/, which git ignores: they are evidence for a run, not for the repo
scan: build
	./security/scan.sh "$$(docker image inspect --format '{{.Id}}' agent-sandbox:latest)" security-out/agent-sandbox
	./security/scan-digests.sh security-out

gate:
	./security/gate.sh security-out

setup:
	./scripts/setup.sh

uninstall:
	rm -f $(HOME)/.local/bin/sandbox.sh

shell: build
	./scripts/sandbox.sh

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

.PHONY: build check worktree-check scan gate setup uninstall shell claude pi vm-create vm-start vm-stop vm-status vm-sync vm-pair vm-destroy
