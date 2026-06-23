"""ducto — declarative credit calculation engine for AI SaaS platforms."""

__version__ = "0.1.2"

from ducto.breakdown import CostBreakdown
from ducto.config import ConfigError, PricingConfig
from ducto.engine import PricingEngine
from ducto.expr import ExpressionError, evaluate_expression, validate_expression
from ducto.interface.memory import MemoryStore
from ducto.interface.models import (
    AddCreditsResult,
    AddTeamMemberResult,
    AllowanceResult,
    BalanceResult,
    CreateTeamResult,
    CreditMetadata,
    DailySpendRow,
    DeductionResult,
    GetUserPlanResult,
    PlanDefinition,
    PricingConfigData,
    PricingConfigResult,
    PricingConfigV2,
    RefundResult,
    ReserveResult,
    SetupResult,
    SetUserPlanResult,
    SpendByModelRow,
    SpendByUserRow,
    SweepResult,
    TeamBalanceResult,
    TeamDeductionResult,
    TeamMemberResult,
    TopUserRow,
)
from ducto.manager import CreditManager, InsufficientCreditsError, PricingNotLoadedError
from ducto.metrics import ToolCall, UsageMetrics

__all__ = [
    "AddCreditsResult",
    "AddTeamMemberResult",
    "AllowanceResult",
    "BalanceResult",
    "ConfigError",
    "CostBreakdown",
    "CreateTeamResult",
    "CreditManager",
    "CreditMetadata",
    "DailySpendRow",
    "DeductionResult",
    "ExpressionError",
    "GetUserPlanResult",
    "InsufficientCreditsError",
    "MemoryStore",
    "PlanDefinition",
    "PricingConfig",
    "PricingConfigData",
    "PricingConfigResult",
    "PricingConfigV2",
    "PricingEngine",
    "PricingNotLoadedError",
    "RefundResult",
    "ReserveResult",
    "SetupResult",
    "SetUserPlanResult",
    "SpendByModelRow",
    "SpendByUserRow",
    "SweepResult",
    "TeamBalanceResult",
    "TeamDeductionResult",
    "TeamMemberResult",
    "ToolCall",
    "TopUserRow",
    "UsageMetrics",
    "evaluate_expression",
    "validate_expression",
]
