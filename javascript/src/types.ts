/** Flexible metadata attached to credit transactions. */
export interface CreditMetadata {
  inputTokens?: number | null;
  outputTokens?: number | null;
  model?: string | null;
  referenceType?: string | null;
  referenceId?: string | null;
  idempotencyKey?: string | null;
  fixedJob?: string | null;
  [key: string]: unknown;
}

/** Schema for a versioned pricing configuration. */
export interface PricingConfigData {
  version: number;
  models: Record<string, string>;
  tools?: Record<string, string> | null;
  search?: Record<string, string> | null;
  cache?: Record<string, string> | null;
  fixed?: Record<string, number> | null;
  minBalance?: number | null;
}

/** Current credit balance for a user. */
export interface BalanceResult {
  userId: string;
  balance: number;
  lifetimePurchased: number;
}

/** Result of adding credits to a user's account. */
export interface AddCreditsResult {
  transactionId: string;
  userId: string;
  amount: number;
  newBalance: number;
  lifetimePurchased: number;
}

/** Result of reserving credits for an operation. */
export interface ReserveResult {
  reservationId: string;
  userId: string;
  amount: number;
  balance: number;
  reservedTotal: number;
  error?: string | null;
}

/** Result of deducting credits. */
export interface DeductionResult {
  transactionId: string;
  userId: string;
  amount: number;
  balanceAfter: number;
  idempotent: boolean;
  error?: string | null;
}

/** Pricing config fetched from store. */
export interface PricingConfigResult {
  id: string;
  config: PricingConfigData;
  version: number;
}

/** Report of SQL setup results. */
export interface SetupResult {
  tablesCreated: string[];
  rpcsCreated: string[];
  errors: string[];
  readonly success: boolean;
}
