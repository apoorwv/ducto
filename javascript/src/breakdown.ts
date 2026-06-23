/** Granular credit cost report for a usage event. */
export interface CostBreakdown {
  modelCredits: number;
  toolCredits: number;
  searchCredits: number;
  cacheSavings: number;
  fixedCredits: number;
  total: number;
  breakdown: Record<string, unknown>;
}

export function makeCostBreakdown(partial?: Partial<CostBreakdown>): CostBreakdown {
  const b: CostBreakdown = {
    modelCredits: partial?.modelCredits ?? 0,
    toolCredits: partial?.toolCredits ?? 0,
    searchCredits: partial?.searchCredits ?? 0,
    cacheSavings: partial?.cacheSavings ?? 0,
    fixedCredits: partial?.fixedCredits ?? 0,
    total: 0,
    breakdown: partial?.breakdown ?? {},
  };
  b.total = Math.max(
    0,
    b.modelCredits + b.toolCredits + b.searchCredits + b.fixedCredits + b.cacheSavings,
  );
  return b;
}
