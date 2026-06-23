import type {
  AddCreditsResult,
  AllowanceResult,
  BalanceResult,
  CreditMetadata,
  DeductionResult,
  GetUserPlanResult,
  PricingConfigData,
  PricingConfigResult,
  RefundResult,
  ReserveResult,
  SetUserPlanResult,
  SetupResult,
  SweepResult,
} from "../types.js";

/** Interface for credit storage backends. */
export interface CreditStore {
  setup(databaseUrl?: string | null): Promise<SetupResult>;
  getBalance(userId: string): Promise<BalanceResult>;
  addCredits(
    userId: string,
    amount: number,
    type?: string,
    metadata?: CreditMetadata | null,
    expiresAt?: Date | null,
  ): Promise<AddCreditsResult>;
  reserveCredits(
    userId: string,
    amount: number,
    operationType: string,
    metadata?: CreditMetadata | null,
    minBalance?: number,
  ): Promise<ReserveResult>;
  deductCredits(
    userId: string,
    reservationId: string,
    amount: number,
    idempotencyKey?: string | null,
    metadata?: CreditMetadata | null,
  ): Promise<DeductionResult>;
  getActivePricing(): Promise<PricingConfigResult | null>;
  setActivePricing(config: PricingConfigData, label?: string | null): Promise<string>;

  // ── Plan management ────────────────────────────────────────────────
  getUserPlan(userId: string): Promise<GetUserPlanResult>;
  setUserPlan(userId: string, planId: string): Promise<SetUserPlanResult>;
  checkAllowance(userId: string): Promise<AllowanceResult>;
  incrementUsageWindow(userId: string, planId: string, amount: number): Promise<void>;

  // ── Refunds ────────────────────────────────────────────────────────
  refundCredits(
    transactionId: string,
    amount?: number,
    reason?: string,
    metadata?: CreditMetadata | null,
  ): Promise<RefundResult>;

  // ── Credit expiry ────────────────────────────────────────────────────
  sweepExpiredCredits(dryRun?: boolean): Promise<SweepResult>;
}
