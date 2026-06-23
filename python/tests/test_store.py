"""Tests for store-level pricing operations."""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest

from ducto import ConfigError, CreditManager, MemoryStore
from ducto.interface.models import PlanDefinition, PricingConfigData, PricingConfigV2


def test_get_pricing_when_none() -> None:
    store = MemoryStore()
    result = store.get_active_pricing()
    assert result is None


def test_set_and_get_pricing() -> None:
    store = MemoryStore()
    config = PricingConfigData(
        version=1,
        models={"gpt-4": "input_tokens * 0.01"},
    )
    returned_id = store.set_active_pricing(config, label="v1")
    assert returned_id != ""

    result = store.get_active_pricing()
    assert result is not None
    assert result.config.models == {"gpt-4": "input_tokens * 0.01"}


def test_set_pricing_replaces_active() -> None:
    store = MemoryStore()
    c1 = PricingConfigData(version=1, models={"_default": "input_tokens * 1"})
    store.set_active_pricing(c1, label="first")

    c2 = PricingConfigData(version=1, models={"_default": "input_tokens * 2"})
    store.set_active_pricing(c2, label="second")

    result = store.get_active_pricing()
    assert result is not None
    assert result.config.models["_default"] == "input_tokens * 2"


def test_publish_pricing_from_dict_invalid_data() -> None:
    manager = CreditManager(store=MemoryStore())

    with pytest.raises(ConfigError):
        manager.publish_pricing_from_dict({"version": 1})


def test_load_pricing_file_yaml(tmp_path) -> None:
    """Load a YAML pricing file via _load_pricing_file."""
    from ducto.__main__ import _load_pricing_file

    f = tmp_path / "pricing.yaml"
    f.write_text("version: 1\nmodels:\n  _default: input_tokens * 1\n")
    data = _load_pricing_file(str(f))
    assert data["version"] == 1
    assert data["models"]["_default"] == "input_tokens * 1"


# ── Plan management ─────────────────────────────────────────────────────


class TestPlanManagement:
    def test_get_user_plan_no_plan(self) -> None:
        store = MemoryStore()
        result = store.get_user_plan("user-1")
        assert result.plan_id is None
        assert result.plan_name is None
        assert result.free_allowance == 0

    def test_set_and_get_user_plan(self) -> None:
        store = MemoryStore()
        # Seed plan via v2 config
        v2 = PricingConfigV2(
            version=2,
            models={"_default": "1"},
            plans={
                "pro": PlanDefinition(id="pro", name="Pro Plan", free_allowance=500),
            },
        )
        store.set_active_pricing(v2)
        store.set_user_plan("user-1", "pro")

        result = store.get_user_plan("user-1")
        assert result.plan_id == "pro"
        assert result.plan_name == "Pro Plan"
        assert result.free_allowance == 500

    def test_check_allowance_no_plan(self) -> None:
        store = MemoryStore()
        allowance = store.check_allowance("nobody")
        assert allowance.allowance_remaining == 0

    def test_check_allowance_with_allowance(self) -> None:
        store = MemoryStore()
        v2 = PricingConfigV2(
            version=2,
            models={"_default": "1"},
            plans={"basic": PlanDefinition(id="basic", name="Basic", free_allowance=200)},
        )
        store.set_active_pricing(v2)
        store.set_user_plan("user-1", "basic")

        allowance = store.check_allowance("user-1")
        assert allowance.allowance_remaining == 200
        assert allowance.plan_id == "basic"

    def test_increment_usage_window_reduces_allowance(self) -> None:
        store = MemoryStore()
        v2 = PricingConfigV2(
            version=2,
            models={"_default": "1"},
            plans={"basic": PlanDefinition(id="basic", name="Basic", free_allowance=200)},
        )
        store.set_active_pricing(v2)
        store.set_user_plan("user-1", "basic")

        store.increment_usage_window("user-1", "basic", 50)
        assert store.check_allowance("user-1").allowance_remaining == 150

        store.increment_usage_window("user-1", "basic", 30)
        assert store.check_allowance("user-1").allowance_remaining == 120


# ── Credit expiry ───────────────────────────────────────────────────────────


class TestCreditExpiry:
    def test_credits_expire_after_ttl(self) -> None:
        store = MemoryStore()
        expires_at = datetime.now().replace(second=0)  # already expired
        store.add_credits("user_1", 100, "purchase", expires_at=expires_at)

        result = store.sweep_expired_credits()
        assert result.expired_count == 1
        assert result.expired_amount == 100
        assert result.dry_run is False
        assert store.get_balance("user_1").balance == 0

    def test_dry_run_reports_without_modifying(self) -> None:
        store = MemoryStore()
        expires_at = datetime.now().replace(second=0)
        store.add_credits("user_1", 100, "purchase", expires_at=expires_at)

        result = store.sweep_expired_credits(dry_run=True)
        assert result.expired_count == 1
        assert result.expired_amount == 100
        assert result.dry_run is True
        assert store.get_balance("user_1").balance == 100  # unchanged

    def test_credits_without_expiry_never_expire(self) -> None:
        store = MemoryStore()
        store.add_credits("user_1", 100)

        result = store.sweep_expired_credits()
        assert result.expired_count == 0
        assert result.expired_amount == 0
        assert store.get_balance("user_1").balance == 100

    def test_sweep_with_no_expired_returns_zero(self) -> None:
        store = MemoryStore()
        result = store.sweep_expired_credits()
        assert result.expired_count == 0
        assert result.expired_amount == 0

    def test_partial_expiry_caps_at_balance(self) -> None:
        store = MemoryStore()
        expires_at = datetime.now().replace(second=0)
        store.add_credits("user_1", 50, "purchase", expires_at=expires_at)
        store.add_credits("user_1", 30, "purchase")

        result = store.sweep_expired_credits()
        assert result.expired_amount == 50
        assert store.get_balance("user_1").balance == 30


# ── Refunds ────────────────────────────────────────────────────────────────


class TestRefund:
    def test_full_refund_restores_balance(self) -> None:
        store = MemoryStore()
        store.add_credits("user_1", 100, "purchase")
        # Deduct 30
        reserve = store.reserve_credits("user_1", 30, "usage")
        deduct = store.deduct_credits("user_1", reserve.reservation_id, 30)
        assert store.get_balance("user_1").balance == 70

        refund = store.refund_credits(deduct.transaction_id)
        assert refund.error is None
        assert refund.amount == 30
        assert store.get_balance("user_1").balance == 100

    def test_partial_refund(self) -> None:
        store = MemoryStore()
        store.add_credits("user_1", 100)
        reserve = store.reserve_credits("user_1", 50, "usage")
        deduct = store.deduct_credits("user_1", reserve.reservation_id, 50)

        refund = store.refund_credits(deduct.transaction_id, amount=20)
        assert refund.error is None
        assert refund.amount == 20
        assert store.get_balance("user_1").balance == 70  # 50 + 20

    def test_double_refund_returns_error(self) -> None:
        store = MemoryStore()
        store.add_credits("user_1", 100)
        reserve = store.reserve_credits("user_1", 30, "usage")
        deduct = store.deduct_credits("user_1", reserve.reservation_id, 30)

        r1 = store.refund_credits(deduct.transaction_id)
        assert r1.error is None

        r2 = store.refund_credits(deduct.transaction_id)
        assert r2.error == "already_refunded"

    def test_unknown_transaction_returns_error(self) -> None:
        store = MemoryStore()
        refund = store.refund_credits("non-existent-id")
        assert refund.error == "transaction_not_found"


# ── Usage analytics ───────────────────────────────────────────────────────────


class TestUsageAnalytics:
    def test_spend_by_user_returns_correct_totals(self) -> None:
        store = MemoryStore()
        store.add_credits("user_1", 1000)
        store.add_credits("user_2", 2000)

        r1 = store.reserve_credits("user_1", 100, "usage")
        store.deduct_credits("user_1", r1.reservation_id, 100)
        r2 = store.reserve_credits("user_1", 50, "usage")
        store.deduct_credits("user_1", r2.reservation_id, 50)
        r3 = store.reserve_credits("user_2", 200, "usage")
        store.deduct_credits("user_2", r3.reservation_id, 200)

        now = datetime.now()
        rows = store.spend_by_user(now - timedelta(seconds=10), now + timedelta(seconds=10))

        assert len(rows) == 2
        u1 = next(r for r in rows if r.user_id == "user_1")
        assert u1.total_spend == 150  # 100 + 50
        assert u1.transaction_count == 2
        u2 = next(r for r in rows if r.user_id == "user_2")
        assert u2.total_spend == 200
        assert u2.transaction_count == 1

    def test_spend_by_model_returns_correct_totals(self) -> None:
        store = MemoryStore()
        store.add_credits("user_1", 1000)

        from ducto.interface.models import CreditMetadata

        r1 = store.reserve_credits("user_1", 100, "usage")
        store.deduct_credits("user_1", r1.reservation_id, 100, metadata=CreditMetadata(model="gpt-4"))
        r2 = store.reserve_credits("user_1", 50, "usage")
        store.deduct_credits("user_1", r2.reservation_id, 50, metadata=CreditMetadata(model="claude-3"))

        now = datetime.now()
        rows = store.spend_by_model(now - timedelta(seconds=10), now + timedelta(seconds=10))
        gpt4 = next((r for r in rows if r.model == "gpt-4"), None)
        assert gpt4 is not None
        assert gpt4.total_spend == 100

    def test_empty_time_window_returns_empty(self) -> None:
        store = MemoryStore()
        store.add_credits("user_1", 100)
        r = store.reserve_credits("user_1", 10, "usage")
        store.deduct_credits("user_1", r.reservation_id, 10)

        rows = store.spend_by_user(
            datetime(2020, 1, 1),
            datetime(2020, 1, 2),
        )
        assert len(rows) == 0

    def test_top_users_respects_limit(self) -> None:
        store = MemoryStore()
        store.add_credits("user_1", 1000)
        store.add_credits("user_2", 1000)
        store.add_credits("user_3", 1000)

        for uid, amt in [("user_1", 300), ("user_2", 200), ("user_3", 100)]:
            r = store.reserve_credits(uid, amt, "usage")
            store.deduct_credits(uid, r.reservation_id, amt)

        now = datetime.now()
        top = store.top_users(2, now - timedelta(seconds=10), now + timedelta(seconds=10))
        assert len(top) == 2
        assert top[0].total_spend >= top[1].total_spend

    def test_daily_spend_bucketing_correct(self) -> None:
        store = MemoryStore()
        store.add_credits("user_1", 1000)
        r = store.reserve_credits("user_1", 75, "usage")
        store.deduct_credits("user_1", r.reservation_id, 75)

        now = datetime.now()
        rows = store.daily_spend(now - timedelta(days=1), now + timedelta(days=1))
        assert len(rows) >= 1
        assert rows[0].total_spend == 75
        assert rows[0].transaction_count == 1


def test_load_pricing_file_json(tmp_path) -> None:
    """Load a JSON pricing file via _load_pricing_file."""
    from ducto.__main__ import _load_pricing_file

    f = tmp_path / "pricing.json"
    f.write_text('{"version": 1, "models": {"_default": "input_tokens * 1"}}')
    data = _load_pricing_file(str(f))
    assert data["version"] == 1
    assert data["models"]["_default"] == "input_tokens * 1"


# ── Team/shared balance pools ─────────────────────────────────────────


class TestTeamBalances:
    def test_create_team_and_get_balance(self) -> None:
        store = MemoryStore()
        result = store.create_team("Engineering")
        assert result.team_id != ""
        assert result.name == "Engineering"

        balance = store.get_team_balance(result.team_id)
        assert balance.name == "Engineering"
        assert balance.balance == 0
        assert balance.member_count == 0

    def test_create_team_with_initial_balance(self) -> None:
        store = MemoryStore()
        result = store.create_team("Pro Team", initial_balance=1000)
        balance = store.get_team_balance(result.team_id)
        assert balance.balance == 1000

    def test_add_team_member_and_track_members(self) -> None:
        store = MemoryStore()
        team = store.create_team("Team A", 500)
        store.add_team_member(team.team_id, "user-1", role="admin")
        store.add_team_member(team.team_id, "user-2", role="member")

        balance = store.get_team_balance(team.team_id)
        assert balance.member_count == 2

        members = store.get_team_members(team.team_id)
        assert len(members) == 2
        assert members[0].role == "admin"

    def test_add_team_member_with_spend_cap(self) -> None:
        store = MemoryStore()
        team = store.create_team("Capped Team", 5000)
        store.add_team_member(team.team_id, "user-1", spend_cap=100)
        members = store.get_team_members(team.team_id)
        assert members[0].spend_cap == 100

    def test_deduct_team_debits_team_pool_not_user_balance(self) -> None:
        store = MemoryStore()
        store.add_credits("user-1", 100)  # user balance
        team = store.create_team("Pool", 500)
        store.add_team_member(team.team_id, "user-1")

        result = store.deduct_team(team.team_id, "user-1", 50)
        assert result.error is None
        assert result.amount == -50
        assert result.team_balance_after == 450

        # User balance unchanged
        assert store.get_balance("user-1").balance == 100

    def test_deduct_team_insufficient_balance(self) -> None:
        store = MemoryStore()
        team = store.create_team("Poor Team", 10)
        store.add_team_member(team.team_id, "user-1")
        result = store.deduct_team(team.team_id, "user-1", 100)
        assert result.error == "insufficient_team_balance"

    def test_deduct_team_user_not_in_team(self) -> None:
        store = MemoryStore()
        team = store.create_team("Closed Team", 500)
        result = store.deduct_team(team.team_id, "user-1", 10)
        assert result.error == "user_not_in_team"

    def test_deduct_team_spend_cap_blocks_overspend(self) -> None:
        store = MemoryStore()
        team = store.create_team("Capped", 1000)
        store.add_team_member(team.team_id, "user-1", role="member", spend_cap=50)

        r1 = store.deduct_team(team.team_id, "user-1", 30)
        assert r1.error is None
        assert r1.team_balance_after == 970

        r2 = store.deduct_team(team.team_id, "user-1", 30)
        assert r2.error == "spend_cap_exceeded"

    def test_deduct_team_nonexistent_team(self) -> None:
        store = MemoryStore()
        result = store.deduct_team("no-such-team", "user-1", 10)
        assert result.error == "team_not_found"
