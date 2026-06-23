# @apoorwv/ducto

Declarative credit calculation engine for AI SaaS platforms.

```typescript
import { PricingEngine } from "@apoorwv/ducto";

const engine = PricingEngine.fromDict({
  version: 1,
  models: { "gpt-4": "input_tokens * (0.01 / 1000) + output_tokens * (0.03 / 1000)" },
});
const cost = engine.calculate({ model: "gpt-4", inputTokens: 1000, outputTokens: 500 });
console.log(cost.total);
```

See the [GitHub repo](https://github.com/apoorwv/ducto) for full documentation.
