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

publish: test build
	. ./.env && uv publish

release: publish
	@echo "Released ducto v$(VERSION)"
	@echo "Don't forget to update the submodule pointer in zonastery:"
	@echo "  cd /path/to/zonastery"
	@echo "  git add packages/ducto"
	@echo '  git commit -m "chore: update ducto submodule pointer (v$(VERSION))"'
