# ducto — Declarative Credit Calculation Engine

Multi-language credit calculation engine for AI SaaS platforms.

| Language | Package | Path |
|----------|---------|------|
| Python | `ducto` (PyPI) | `python/` |
| TypeScript | `@apoorwv/ducto` (npm) | `javascript/` |

## Quick Start

**Python:** `pip install ducto`

```python
from ducto import PricingEngine
engine = PricingEngine.from_dict({"version":1,"models":{"gpt-4":"input_tokens * (0.01/1000) + output_tokens * (0.03/1000)"}})
cost = engine.calculate({"model":"gpt-4","inputTokens":1000,"outputTokens":500})
print(cost.total)  # 0.03
```

**TypeScript:** `npm install @apoorwv/ducto`

```typescript
import { PricingEngine } from "@apoorwv/ducto";
const engine = PricingEngine.fromDict({version:1,models:{"gpt-4":"input_tokens*(0.01/1000)+output_tokens*(0.03/1000)"}});
const cost = engine.calculate({model:"gpt-4",inputTokens:1000,outputTokens:500});
console.log(cost.total);
```

See `python/` and `javascript/` directories for language-specific docs.

## License

MIT
