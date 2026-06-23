import type {
  AddCreditsResult,
  AddTeamMemberResult,
  AllowanceResult,
  BalanceResult,
  CreateTeamResult,
  CreditMetadata,
  DailySpendRow,
  DeductionResult,
  GetUserPlanResult,
  PricingConfigData,
  PricingConfigResult,
  RefundResult,
  ReserveResult,
  SetUserPlanResult,
  SetupResult,
  SpendByModelRow,
  SpendByUserRow,
  SweepResult,
  TeamBalanceResult,
  TeamDeductionResult,
  TeamMember,
  TopUserRow,
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

  // ── Usage analytics ──────────────────────────────────────────────────
  spendByUser(start: Date, end: Date): Promise<SpendByUserRow[]>;
  spendByModel(start: Date, end: Date): Promise<SpendByModelRow[]>;
  topUsers(limit: number, start: Date, end: Date): Promise<TopUserRow[]>;
  dailySpend(start: Date, end: Date): Promise<DailySpendRow[]>;

  // ── Team/shared balance pools ──────────────────────────────────────
  createTeam(name: string, initialBalance?: number): Promise<CreateTeamResult>;
  getTeamBalance(teamId: string): Promise<TeamBalanceResult>;
  addTeamMember(
    teamId: string,
    userId: string,
    role?: string,
    spendCap?: number | null,
  ): Promise<AddTeamMemberResult>;
  getTeamMembers(teamId: string): Promise<TeamMember[]>;
  deductTeam(
    teamId: string,
    userId: string,
    amount: number,
    metadata?: CreditMetadata | null,
  ): Promise<TeamDeductionResult>;
}
