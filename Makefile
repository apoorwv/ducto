.PHONY: build clean lint typecheck test publish publish-test

VERSION ?= $(shell uv run python -c "from ducto import __version__; print(__version__)")

build: clean
	uv build

clean:
	rm -rf dist/ build/ *.egg-info/
	rm -rf .pytest_cache .ruff_cache __pycache__/
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

lint:
	uv run ruff check src/ tests/ scripts/

typecheck:
	uv run pyright src/

test: lint typecheck
	uv run python -m pytest tests/ -q

publish-test: test build
	. ./.env && uv publish --publish-url https://test.pypi.org/legacy/

# Manual publish (use CI release for automated):
#   1. git tag v$(VERSION)
#   2. git push origin v$(VERSION)
#   CI runs lint → typecheck → test → build → publish
publish: build
	. ./.env && uv publish

release: publish
	@echo "Released ducto v$(VERSION)"

release-ci:
	@echo "Release via CI: git tag v$(VERSION) && git push origin v$(VERSION)"
