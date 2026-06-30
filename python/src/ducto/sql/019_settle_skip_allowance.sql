-- ducto: 019 — settle_lease skip_allowance (Fix 7 / #4)
--
-- Adds p_skip_allowance BOOLEAN DEFAULT FALSE to settle_lease so that the
-- lease-based reservation path (reserve → settle) has the same allowance
-- control as the direct-deduct path (deduct / deduct_fixed).
--
-- Without this, any job using reserve+settle would always consume the user's
-- free inference allowance at settle time even when skip_allowance=True was
-- intended (runtime bug — Fix 7 incomplete for lease path, #4).

CREATE OR REPLACE FUNCTION public.settle_lease(
    p_user_id         UUID,
    p_lease_id        UUID,
    p_amount          NUMERIC,
    p_idempotency_key TEXT DEFAULT NULL,
    p_min_balance     NUMERIC DEFAULT 0,
    p_model           TEXT DEFAULT NULL,
    p_metadata        JSONB DEFAULT '{}'::jsonb,
    p_skip_allowance  BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_balance             NUMERIC;
    v_plan_id             UUID;
    v_status              TEXT;
    v_settle_tx           UUID;
    v_lease_expires       TIMESTAMPTZ;
    v_free_allowance      NUMERIC;
    v_period_start        DATE;
    v_used                NUMERIC;
    v_consume             NUMERIC := 0;
    v_net                 NUMERIC;
    v_cap                 RECORD;
    v_cap_window          TIMESTAMPTZ;
    v_cap_spend           NUMERIC;
    v_cap_warning         TEXT := NULL;
    v_new_balance         NUMERIC;
    v_tx_id               UUID;
    v_metadata            JSONB;
    v_existing_id         UUID;
    v_existing_amt        NUMERIC;
    v_existing_cons       NUMERIC;
    v_existing_bal_after  NUMERIC;
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

    -- Idempotency replay via key: return original balance_after from tx metadata (Fix 8).
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id,
               ABS(amount),
               COALESCE((metadata->>'allowance_consumed')::numeric, 0),
               COALESCE((metadata->>'balance_after')::numeric, v_balance)
        INTO v_existing_id, v_existing_amt, v_existing_cons, v_existing_bal_after
        FROM public.credit_transactions
        WHERE user_id = p_user_id AND metadata->>'idempotency_key' = p_idempotency_key
        LIMIT 1;
        IF FOUND THEN
            RETURN jsonb_build_object(
                'transaction_id', v_existing_id, 'amount', v_existing_amt,
                'allowance_consumed', v_existing_cons,
                'balance_after', v_existing_bal_after,
                'idempotent', true, 'cap_warning', NULL
            );
        END IF;
    END IF;

    SELECT status, settle_tx_id, expires_at INTO v_status, v_settle_tx, v_lease_expires
    FROM public.credit_reservations
    WHERE id = p_lease_id AND user_id = p_user_id FOR UPDATE;

    IF NOT FOUND OR v_status = 'released' THEN
        RETURN jsonb_build_object('error', 'lease_not_found', 'balance_after', v_balance);
    END IF;
    IF v_status = 'settled' THEN
        IF v_settle_tx IS NOT NULL THEN
            SELECT id,
                   ABS(amount),
                   COALESCE((metadata->>'allowance_consumed')::numeric, 0),
                   COALESCE((metadata->>'balance_after')::numeric, v_balance)
            INTO v_existing_id, v_existing_amt, v_existing_cons, v_existing_bal_after
            FROM public.credit_transactions WHERE id = v_settle_tx;
            IF FOUND THEN
                RETURN jsonb_build_object(
                    'transaction_id', v_existing_id, 'amount', v_existing_amt,
                    'allowance_consumed', v_existing_cons,
                    'balance_after', v_existing_bal_after,
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

    IF p_amount = 0 THEN
        UPDATE public.credit_reservations SET status = 'settled' WHERE id = p_lease_id;
        RETURN jsonb_build_object('transaction_id', NULL, 'amount', 0, 'balance_after', v_balance, 'idempotent', false);
    END IF;

    -- Allowance consume on actual cost.  Skipped when p_skip_allowance = TRUE (Fix 7 / #4):
    -- fixed-cost batch jobs reserved via the lease path must not deplete the
    -- free inference allowance (mirrors deduct_with_allowance p_skip_allowance).
    IF NOT p_skip_allowance AND v_plan_id IS NOT NULL THEN
        SELECT free_allowance INTO v_free_allowance FROM public.credit_plans WHERE id = v_plan_id;
        v_period_start := (date_trunc('month', now() AT TIME ZONE 'UTC'))::DATE;
        SELECT COALESCE(SUM(usage), 0) INTO v_used
        FROM public.credit_usage_window
        WHERE user_id = p_user_id AND plan_id = v_plan_id AND billing_period = v_period_start;
        v_consume := LEAST(GREATEST(COALESCE(v_free_allowance, 0) - COALESCE(v_used, 0), 0), p_amount);
    END IF;
    v_net := p_amount - v_consume;

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

    UPDATE public.user_credits SET balance = balance - v_net, updated_at = now()
    WHERE user_id = p_user_id RETURNING balance INTO v_new_balance;

    -- Store balance_after in metadata for correct idempotent replay (Fix 8).
    v_metadata := COALESCE(p_metadata, '{}'::jsonb)
        || jsonb_strip_nulls(jsonb_build_object('idempotency_key', p_idempotency_key, 'model', p_model))
        || jsonb_build_object('allowance_consumed', v_consume, 'balance_after', v_new_balance);

    INSERT INTO public.credit_transactions (user_id, amount, type, reference_type, metadata)
    VALUES (p_user_id, -v_net, 'usage', p_metadata->>'reference_type', v_metadata) RETURNING id INTO v_tx_id;

    UPDATE public.credit_reservations SET status = 'settled', settle_tx_id = v_tx_id WHERE id = p_lease_id;

    RETURN jsonb_build_object(
        'transaction_id', v_tx_id, 'amount', v_net, 'allowance_consumed', v_consume,
        'balance_after', v_new_balance, 'idempotent', false, 'cap_warning', v_cap_warning
    );
END;
$$;

-- Grant the 8-argument overload (old 7-arg signature still works via defaults).
REVOKE EXECUTE ON FUNCTION public.settle_lease(UUID, UUID, NUMERIC, TEXT, NUMERIC, TEXT, JSONB, BOOLEAN) FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';
