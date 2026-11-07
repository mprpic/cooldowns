export UV_EXCLUDE_NEWER ?= 3 days

.PHONY: docs lint smoke-test

docs:
	uv run build.py --serve

lint:
	shellcheck cooldowns.sh
	uv run --with mdlint mdlint check README.md
	uv run --with ruff ruff check
	uv run --with ruff ruff format --check
	uv run build.py

smoke-test:
	podman run --rm -i \
		-v ./cooldowns.sh:/usr/local/bin/cooldowns.sh:ro,z \
		quay.io/fedora/fedora:latest \
		bash -c 'dnf install -q -y nodejs24-npm python3-pip && pip install -q --upgrade pip poetry && bash -s /etc/profile.d/cooldowns.sh' \
		< tests/smoke-test.sh
