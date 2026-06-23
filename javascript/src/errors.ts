export class ConfigError extends Error {
  override readonly name = "ConfigError";
}

export class ExpressionError extends Error {
  override readonly name = "ExpressionError";
}

export class InsufficientCreditsError extends Error {
  override readonly name = "InsufficientCreditsError";
}

export class PricingNotLoadedError extends Error {
  override readonly name = "PricingNotLoadedError";
}

export class ImportError extends Error {
  override readonly name = "ImportError";
}
