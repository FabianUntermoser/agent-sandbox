build:
	docker buildx bake --load

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

.PHONY: build setup uninstall shell claude pi
