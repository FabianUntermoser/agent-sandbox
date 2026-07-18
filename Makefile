build:
	docker buildx bake --load

setup: build
	./scripts/setup.sh

shell: build
	./scripts/sandbox.sh

claude: build
	./scripts/sandbox.sh claude

pi: build
	./scripts/sandbox.sh pi

.PHONY: build setup shell claude pi
