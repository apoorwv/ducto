import { ConfigError } from "./errors.js";
import { validateExpression } from "./expr.js";

/** Internal validated pricing configuration. */
export interface PricingConfig {
  version: number;
  models: Record<string, string>;
  tools: Record<string, string>;
  search: Record<string, string>;
  cache: Record<string, string>;
  minBalance: number;
  fixed: Record<string, number>;
}

function validateConfigData(data: Record<string, unknown>): void {
  if (data.version == null) throw new ConfigError("missing required field: version");
  if (data.version !== 1) throw new ConfigError(`unsupported version: ${data.version}`);
  if (data.models == null) throw new ConfigError("missing required section: models");
  if (typeof data.models !== "object" || Object.keys(data.models as object).length === 0) {
    throw new ConfigError("models must be a non-empty dict");
  }
}

function validateExpressions(raw: PricingConfig): void {
  for (const [key, expr] of Object.entries(raw.models)) {
    try { validateExpression(expr); } catch (e) {
      throw new ConfigError(`invalid expression in models.${key}: ${(e as Error).message}`);
    }
  }
  for (const [key, expr] of Object.entries(raw.tools)) {
    try { validateExpression(expr); } catch (e) {
      throw new ConfigError(`invalid expression in tools.${key}: ${(e as Error).message}`);
    }
  }
  for (const [key, expr] of Object.entries(raw.search)) {
    try { validateExpression(expr); } catch (e) {
      throw new ConfigError(`invalid expression in search.${key}: ${(e as Error).message}`);
    }
  }
  for (const [key, expr] of Object.entries(raw.cache)) {
    try { validateExpression(expr); } catch (e) {
      throw new ConfigError(`invalid expression in cache.${key}: ${(e as Error).message}`);
    }
  }
}

/** Load and validate a pricing config from a raw dictionary. */
export function loadConfigFromDict(data: Record<string, unknown>): PricingConfig {
  validateConfigData(data);
  const config: PricingConfig = {
    version: data.version as number,
    models: data.models as Record<string, string>,
    tools: { _default: "tool_calls * 0", ...(data.tools as Record<string, string> | undefined) },
    search: (data.search as Record<string, string>) ?? {},
    cache: (data.cache as Record<string, string>) ?? {},
    minBalance: (data.minBalance as number) ?? 5,
    fixed: (data.fixed as Record<string, number>) ?? {},
  };
  if (config.minBalance < 0) throw new ConfigError("min_balance must be >= 0");
  validateExpressions(config);
  return config;
}
