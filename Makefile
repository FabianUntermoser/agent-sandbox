build:
	docker buildx bake --load

check:
	bash -n scripts/*.sh
	./scripts/public-ip.sh --self-check
	./scripts/sandbox-manifest.test.sh

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

.PHONY: build check setup uninstall shell claude pi vm-create vm-start vm-stop vm-status vm-sync vm-pair vm-destroy
