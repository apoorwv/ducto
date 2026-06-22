# Contributing

## Development Setup

```bash
git clone https://github.com/apoorwv/ducto.git
cd ducto
uv sync              # Install dependencies
uv sync --group dev  # Install dev dependencies (ruff, pyright, pytest)
```

## Running Tests

```bash
uv run python -m pytest tests/ -q       # Quick run
uv run python -m pytest tests/ -v       # Verbose
uv run python -m pytest tests/ --cov    # With coverage
```

## Code Style

- **Formatter**: ruff (120 char line width, double quotes)
- **Linter**: ruff with selected rulesets (E, F, I, N, W, UP, B, ASYNC, SIM, RET)
- **Type checker**: pyright (standard mode)

Format and lint before committing:

```bash
uv run ruff format src/ tests/ scripts/
uv run ruff check --fix src/ tests/ scripts/
uv run pyright src/
```

Pre-commit hooks run automatically via lefthook on `git commit`.

## Pull Request Process

1. Branch from `main`.
2. Make changes with descriptive commits (conventional-changelog style).
3. Ensure all tests pass and no new type errors.
4. Open a PR against `main`.
5. CI runs lint → typecheck → test automatically.

## Project Structure

```
ducto/
├── src/ducto/           # Source code
│   ├── __init__.py      # Public API exports
│   ├── __main__.py      # CLI entry point
│   ├── engine.py        # PricingEngine — core calculation
│   ├── config.py        # PricingConfig — validated config model
│   ├── expr.py          # Safe AST expression evaluator
│   ├── manager.py       # CreditManager — lifecycle orchestration
│   ├── metrics.py       # UsageMetrics, ToolCall dataclasses
│   ├── breakdown.py     # CostBreakdown result
│   ├── interface/       # Storage adapters (ABC + implementations)
│   └── sql/             # Bundled SQL migrations
├── tests/               # pytest suite
└── scripts/             # Utility scripts (seed_pricing.py)
```

## Adding Storage Backends

Implement the `CreditStore` ABC in `ducto/interface/`:
- All 8 abstract methods must be implemented.
- Return typed Pydantic models from `ducto/interface/models.py`.
- Add tests in `tests/test_store.py`.

## Releasing

```bash
git tag v0.1.2
git push origin v0.1.2
```

CI runs lint → typecheck → test → build → publish to PyPI automatically.

Requires a [trusted publisher](https://docs.pypi.org/trusted-publishers/) configured on PyPI:

| Field | Value |
|---|---|
| PyPI Project | `ducto` |
| Workflow name | `ci.yml` |
| Environment | (leave blank) |

To set it up: https://pypi.org/manage/account/publishing/
