# @apoorwv/ducto

[![CI](https://github.com/apoorwv/ducto/actions/workflows/ci.yml/badge.svg)](https://github.com/apoorwv/ducto/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@apoorwv/ducto)](https://www.npmjs.com/package/@apoorwv/ducto)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](https://github.com/apoorwv/ducto/blob/main/LICENSE)

Add usage-based credits to your AI SaaS in minutes — not weeks.

ducto is a drop-in credit calculation engine. Define pricing as math expressions
(per-model, per-tool, search/RAG, cache, fixed jobs), connect a database, and
start deducting credits. No billing infrastructure to build. Pricing lives in
your DB — update it live without redeploys.

```typescript
import { CreditManager, UsageMetrics } from "@apoorwv/ducto";
import { MemoryStore } from "@apoorwv/ducto";

// Create a store (use MemoryStore for testing, PostgresStore/SupabaseStore for prod)
const store = new MemoryStore();
const manager = new CreditManager(store);

// Load pricing and add credits
manager.publishPricingFromDict({
  version: 1,
  models: { "gpt-4": "input_tokens * (0.01 / 1000) + output_tokens * (0.03 / 1000)" },
});
await manager.addCredits("user_abc", 1000);

// Deduct credits from a single LLM call
const result = await manager.deduct("user_abc", {
  model: "gpt-4",
  inputTokens: 500,
  outputTokens: 200,
});
console.log(`Deducted ${Math.abs(result.amount)} credits`);
```

Works in Node.js 18+, Bun, and Deno.

## Features

- **Safe expression engine** — Recursive descent parser with a strict allowlist.
  Parses, validates, and evaluates expressions at config load time. No eval(),
  no arbitrary code execution.
- **Database-backed pricing** — Pricing expressions stored in a
  `credit_pricing_config` table. Enables live pricing updates without
  redeploys. Dict loading available for testing and stateless calculation.
- **Multi-dimensional** — Per-model formulas (with `_default` fallback),
  per-tool overrides, search/RAG, cache read discounts, fixed-cost jobs.
- **Stateless core** — Pure calculation layer has zero database dependency.
- **Auditable** — Returns a structured `CostBreakdown` with per-dimension
  costs and metadata.
- **Pluggable storage** — Reserve-then-deduct pattern via `CreditStore`
  adapters: Supabase (fetch-based, zero deps), raw PostgreSQL (`pg`), or
  in-memory for testing.
- **Safe defaults** — Configurable `minBalance` floor, idempotent deductions,
  concurrent reservation protection.

## Installation

```bash
npm install @apoorwv/ducto

# PostgreSQL store (optional)
npm install pg

# YAML pricing config loading (optional)
npm install js-yaml
```

Requires Node.js 18+ (for native `fetch` support with Supabase store).

## Quick Start

### Calculation only (no database)

```typescript
import { PricingEngine } from "@apoorwv/ducto";

const engine = PricingEngine.fromDict({
  version: 1,
  models: {
    "gpt-4": "input_tokens * (0.01 / 1000) + output_tokens * (0.03 / 1000)",
    "_default": "input_tokens * (0.001 / 1000) + output_tokens * (0.003 / 1000)",
  },
});

const cost = engine.calculate({
  model: "gpt-4",
  inputTokens: 500,
  outputTokens: 200,
});
console.log(`Total: ${cost.total}`); // 0.011
console.log(`Model: ${cost.modelCredits}, Tools: ${cost.toolCredits}`);
```

### Full credit lifecycle (in-memory, no database)

```typescript
import { CreditManager, MemoryStore } from "@apoorwv/ducto";

const store = new MemoryStore();
const manager = new CreditManager(store);

// Publish pricing
manager.publishPricingFromDict({
  version: 1,
  models: { "gpt-4": "input_tokens * (0.01 / 1000) + output_tokens * (0.03 / 1000)" },
});

// Add credits and deduct
await manager.addCredits("user_abc", 1000);
const result = await manager.deduct(
  "user_abc",
  { model: "gpt-4", inputTokens: 500, outputTokens: 200 },
  "idempotency-key-123", // prevents double-charge on retry
);

console.log(`Remaining balance: ${(await manager.getBalance("user_abc")).balance}`);
```

### Production with Supabase

```typescript
import { CreditManager } from "@apoorwv/ducto";
import { HttpxSupabaseStore } from "@apoorwv/ducto";

const store = new HttpxSupabaseStore(
  "https://your-project.supabase.co",
  "service_role_key"
);
const manager = new CreditManager(store);
await manager.loadPricingFromStore();
await manager.addCredits("user_abc", 5000);
```

## Pricing Configuration

Pricing is a JSON object with version, model expressions, and optional sections
for tools, search, cache, and fixed-cost jobs.

### Expression format

```json
{
  "version": 1,
  "models": {
    "gpt-4": "input_tokens * (0.01 / 1000) + output_tokens * (0.03 / 1000)",
    "gpt-3.5-turbo": "input_tokens * (0.001 / 1000) + output_tokens * (0.002 / 1000)",
    "_default": "input_tokens * (0.05 / 1000)"
  },
  "tools": {
    "_default": "tool_calls * 5 / 1000",
    "code_exec": "tool_calls * 10 / 1000"
  },
  "search": {
    "costs": "search_queries * 0.5 + search_results * 0.05"
  },
  "cache": {
    "discount": "-cache_read_tokens * (0.001 / 1000)"
  },
  "fixed": {
    "batch_train": 100,
    "daily_report": 10
  },
  "minBalance": 5
}
```

### Expression syntax

| Feature | Example | Description |
|---------|---------|-------------|
| Arithmetic | `input_tokens * 0.01` | `+`, `-`, `*`, `/`, `//`, `%`, `**` |
| Variables | `input_tokens`, `output_tokens`, `tool_calls` | All usage metrics available |
| Comparisons | `output_tokens > 1000` | `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`, `not in` |
| Boolean | `tool_calls > 0 and tool_calls <= 10` | `and`, `or` |
| Ternary | `output_tokens * 0.5 if output_tokens > 1000 else output_tokens * 0.3` | Python-style `X if cond else Y` |
| Functions | `ceil()`, `floor()`, `min()`, `max()`, `round()` | Safe math functions |

### Loading from file

```typescript
import { loadPricingFile } from "@apoorwv/ducto";
import { PricingEngine } from "@apoorwv/ducto";

const data = await loadPricingFile("./pricing.yaml");
const engine = PricingEngine.fromDict(data);
```

## Available metrics

| Variable | Source | Type |
|----------|--------|------|
| `input_tokens` | `metrics.inputTokens` | `number` |
| `output_tokens` | `metrics.outputTokens` | `number` |
| `cache_read_tokens` | `metrics.cacheReadTokens` | `number` |
| `cache_write_tokens` | `metrics.cacheWriteTokens` | `number` |
| `tool_calls` | `metrics.toolCalls.length` | `number` |
| `search_queries` | `metrics.searchQueries` | `number` |
| `search_results` | `metrics.searchResults` | `number` |
| `web_search_calls` | `metrics.webSearchCalls` | `number` |
| `code_exec_calls` | `metrics.codeExecCalls` | `number` |

## Store adapters

| Store | Import | Deps | Use case |
|-------|--------|------|----------|
| `MemoryStore` | `@apoorwv/ducto` | None | Testing, development |
| `HttpxSupabaseStore` | `@apoorwv/ducto` | Node 18+ (`fetch`) | Supabase production |
| `PostgresStore` | `@apoorwv/ducto` | `pg` | Direct PostgreSQL |

## API

### `PricingEngine`

```typescript
PricingEngine.fromDict(data): PricingEngine
engine.calculate(metrics: UsageMetrics): CostBreakdown
engine.calculateBatch(metrics: UsageMetrices[]): CostBreakdown[]
engine.resolveModel(modelVersion: string): string | null
engine.hasModel(modelName: string): boolean
engine.getFixedCost(jobName: string): number | null
engine.pricingSchema(): PricingConfigData
engine.minBalance: number
```

### `CreditManager`

```typescript
new CreditManager(store: CreditStore, engine?: PricingEngine)
manager.publishPricingFromDict(data): void
manager.loadPricingFromStore(): Promise<void>
manager.publishPricing(config, label?): void
manager.getBalance(userId): Promise<BalanceResult>
manager.addCredits(userId, amount, type?, metadata?): Promise<AddCreditsResult>
manager.reserveCredits(userId, amount, opType?, metadata?, minBalance?): Promise<ReserveResult>
manager.deduct(userId, metrics, idempotencyKey?, metadata?): Promise<DeductionResult>
manager.deductFixed(userId, jobName, idempotencyKey?, metadata?): Promise<DeductionResult>
manager.pricingEngine: PricingEngine | null
```

## License

MIT
