-- ducto: 021 — enforce floor clamp in settle_lease (C1).
--
-- The original settle_lease was "de-clamped": it charged the full actual cost
-- with no floor check, so strict_prepaid / overdraft guarantees were not
-- enforced at settle time (p_min_balance was declared but never used).
--
-- This migration replaces settle_lease with a version that:
--   • reads billing_mode + overdraft_floor from the lease record;
--   • for strict/strict_prepaid: clamps the debit so balance ≥ p_min_balance;
--   • for overdraft: clamps so balance ≥ overdraft_floor (can be negative);
--   • re-clamps allowance consume so it never exceeds the actual net charged.

CREATE OR REPLACE FUNCTION public.settle_lease(
    p_user_id         UUID,
    p_lease_id        UUID,
    p_amount          NUMERIC,
    p_idempotency_key TEXT DEFAULT NULL,
    p_min_balance     NUMERIC DEFAULT 0,
    p_model           TEXT DEFAULT NULL,
    p_metadata        JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_balance        NUMERIC;
    v_plan_id        UUID;
    v_status         TEXT;
    v_settle_tx      UUID;
    v_lease_expires  TIMESTAMPTZ;
    v_billing_mode   TEXT;
    v_overdraft_floor NUMERIC;
    v_settle_floor   NUMERIC;
    v_max_debit      NUMERIC;
    v_free_allowance NUMERIC;
    v_period_start   DATE;
    v_used           NUMERIC;
    v_consume        NUMERIC := 0;
    v_net            NUMERIC;
    v_cap            RECORD;
    v_cap_window     TIMESTAMPTZ;
    v_cap_spend      NUMERIC;
    v_cap_warning    TEXT := NULL;
    v_new_balance    NUMERIC;
    v_tx_id          UUID;
    v_metadata       JSONB;
    v_existing_id    UUID;
    v_existing_amt   NUMERIC;
    v_existing_cons  NUMERIC;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        RETURN jsonb_build_object('error', 'unauthorized');
    END IF;

    IF p_amount IS NULL OR NOT (p_amount = p_amount)
       OR p_amount = 'Infinity'::numeric OR p_amount = '-Infinity'::numeric OR p_amount < 0 THEN
        RETURN jsonb_build_object('error', 'invalid_amount', 'amount', p_amount);
    END IF;

    SELECT balance, plan_id INTO v_balance, v_plan_id
    FROM public.user_credits WHERE user_id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO public.user_credits (user_id, balance, lifetime_purchased)
        VALUES (p_user_id, 0, 0) ON CONFLICT (user_id) DO NOTHING;
        SELECT balance, plan_id INTO v_balance, v_plan_id
        FROM public.user_credits WHERE user_id = p_user_id FOR UPDATE;
    END IF;

    -- Idempotency replay (user-scoped).
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id, ABS(amount), COALESCE((metadata->>'allowance_consumed')::numeric, 0)
        INTO v_existing_id, v_existing_amt, v_existing_cons
        FROM public.credit_transactions
        WHERE user_id = p_user_id AND metadata->>'idempotency_key' = p_idempotency_key
        LIMIT 1;
        IF FOUND THEN
            RETURN jsonb_build_object(
                'transaction_id', v_existing_id, 'amount', v_existing_amt,
                'allowance_consumed', v_existing_cons, 'balance_after', v_balance,
                'idempotent', true, 'cap_warning', NULL
            );
        END IF;
    END IF;

    -- Lock + validate the lease state; also read billing policy columns (C1).
    SELECT status, settle_tx_id, expires_at, billing_mode, overdraft_floor
    INTO v_status, v_settle_tx, v_lease_expires, v_billing_mode, v_overdraft_floor
    FROM public.credit_reservations
    WHERE id = p_lease_id AND user_id = p_user_id FOR UPDATE;

    IF NOT FOUND OR v_status = 'released' THEN
        RETURN jsonb_build_object('error', 'lease_not_found', 'balance_after', v_balance);
    END IF;
    IF v_status = 'settled' THEN
        IF v_settle_tx IS NOT NULL THEN
            SELECT id, ABS(amount), COALESCE((metadata->>'allowance_consumed')::numeric, 0)
            INTO v_existing_id, v_existing_amt, v_existing_cons
            FROM public.credit_transactions WHERE id = v_settle_tx;
            IF FOUND THEN
                RETURN jsonb_build_object(
                    'transaction_id', v_existing_id, 'amount', v_existing_amt,
                    'allowance_consumed', v_existing_cons, 'balance_after', v_balance,
                    'idempotent', true, 'cap_warning', NULL
                );
            END IF;
        END IF;
        RETURN jsonb_build_object('amount', 0, 'balance_after', v_balance, 'idempotent', true);
    END IF;
    IF v_status = 'expired' OR v_lease_expires <= now() THEN
        UPDATE public.credit_reservations SET status = 'expired' WHERE id = p_lease_id;
        RETURN jsonb_build_object('error', 'lease_expired', 'balance_after', v_balance);
    END IF;

    -- Zero-cost settle releases the lease without charging (M3).
    IF p_amount = 0 THEN
        UPDATE public.credit_reservations SET status = 'settled' WHERE id = p_lease_id;
        RETURN jsonb_build_object('transaction_id', NULL, 'amount', 0, 'balance_after', v_balance, 'idempotent', false);
    END IF;

    -- Allowance consume on the actual cost (mirrors 015).
    IF v_plan_id IS NOT NULL THEN
        SELECT free_allowance INTO v_free_allowance FROM public.credit_plans WHERE id = v_plan_id;
        v_period_start := (date_trunc('month', now() AT TIME ZONE 'UTC'))::DATE;
        SELECT COALESCE(SUM(usage), 0) INTO v_used
        FROM public.credit_usage_window
        WHERE user_id = p_user_id AND plan_id = v_plan_id AND billing_period = v_period_start;
        v_consume := LEAST(GREATEST(COALESCE(v_free_allowance, 0) - COALESCE(v_used, 0), 0), p_amount);
    END IF;
    v_net := p_amount - v_consume;

    -- Floor enforcement (C1): clamp v_net so the post-settle balance stays ≥ floor.
    -- strict / strict_prepaid → floor is p_min_balance (engine's min_balance).
    -- overdraft → floor is the overdraft_floor stored on the lease (can be negative).
    IF v_billing_mode IN ('strict', 'strict_prepaid') THEN
        v_settle_floor := COALESCE(p_min_balance, 0);
    ELSE
        v_settle_floor := COALESCE(v_overdraft_floor, 0);
    END IF;
    v_max_debit := GREATEST(0, v_balance - v_settle_floor);
    IF v_net > v_max_debit THEN
        v_net := v_max_debit;
        -- Re-clamp allowance consume so it doesn't exceed amount - net.
        IF v_net < p_amount THEN
            v_consume := LEAST(v_consume, p_amount - v_net);
        END IF;
    END IF;

    -- Spend cap is ADVISORY at settle (never blocks): record the strongest breach.
    FOR v_cap IN
        SELECT action, cap_type, model, cap_limit FROM public.credit_spend_caps
        WHERE user_id = p_user_id AND (model IS NULL OR model = p_model)
        ORDER BY (action = 'deny') DESC, cap_limit ASC
    LOOP
        v_cap_window := CASE v_cap.cap_type
            WHEN 'daily' THEN date_trunc('day', now() AT TIME ZONE 'UTC')
            ELSE date_trunc('month', now() AT TIME ZONE 'UTC')
        END;
        SELECT COALESCE(SUM(ABS(ct.amount)), 0) INTO v_cap_spend
        FROM public.credit_transactions ct
        WHERE ct.user_id = p_user_id AND ct.type IN ('usage', 'team_usage') AND ct.amount < 0
          AND ct.created_at >= v_cap_window
          AND (v_cap.model IS NULL OR ct.metadata->>'model' = v_cap.model);
        IF v_cap_spend + v_net > v_cap.cap_limit AND (v_cap_warning IS NULL OR (v_cap_warning <> 'deny' AND v_cap.action = 'deny')) THEN
            v_cap_warning := v_cap.action;
        END IF;
    END LOOP;

    IF v_consume > 0 THEN
        INSERT INTO public.credit_usage_window (user_id, plan_id, billing_period, usage)
        VALUES (p_user_id, v_plan_id, v_period_start, v_consume)
        ON CONFLICT (user_id, plan_id, billing_period)
        DO UPDATE SET usage = public.credit_usage_window.usage + v_consume, updated_at = now();
    END IF;

    v_metadata := COALESCE(p_metadata, '{}'::jsonb)
        || jsonb_strip_nulls(jsonb_build_object('idempotency_key', p_idempotency_key, 'model', p_model))
        || jsonb_build_object('allowance_consumed', v_consume);

    UPDATE public.user_credits SET balance = balance - v_net, updated_at = now()
    WHERE user_id = p_user_id RETURNING balance INTO v_new_balance;

    INSERT INTO public.credit_transactions (user_id, amount, type, metadata)
    VALUES (p_user_id, -v_net, 'usage', v_metadata) RETURNING id INTO v_tx_id;

    UPDATE public.credit_reservations SET status = 'settled', settle_tx_id = v_tx_id WHERE id = p_lease_id;

    RETURN jsonb_build_object(
        'transaction_id', v_tx_id, 'amount', v_net, 'allowance_consumed', v_consume,
        'balance_after', v_new_balance, 'idempotent', false, 'cap_warning', v_cap_warning
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.settle_lease(UUID, UUID, NUMERIC, TEXT, NUMERIC, TEXT, JSONB) FROM anon, authenticated;
