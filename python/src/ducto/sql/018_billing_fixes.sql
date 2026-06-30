-- ducto: 018 — billing correctness fixes
--
-- Three targeted fixes applied by re-creating the affected RPCs:
--
-- (A) create_lease — allowance-aware admission (Fix 1 / D4)
--     Reads the user's plan and remaining free allowance inside the lock, then
--     adds it to the effective available headroom before the floor check.
--     A free-tier user with 50 balance + 60 allowance can now afford an 80-credit
--     worst-case hold; previously they were rejected with insufficient_credits.
--
-- (B) deduct_with_allowance — skip_allowance flag (Fix 7) and
--     correct idempotent balance_after (Fix 8 / §2)
--     p_skip_allowance bypasses allowance consumption so fixed-cost batch jobs
--     (daily_report, batch_train, …) do NOT eat the user's inference allowance.
--     balance_after is now stored in the transaction metadata and returned on
--     idempotent replay instead of the (wrong) current balance.
--
-- (C) settle_lease — correct idempotent balance_after (Fix 8 / D5)
--     Same metadata-storage fix as (B): the balance at the time of the original
--     settle is stored and replayed rather than the (wrong) current balance.

-- ── (A) create_lease: allowance-aware admission ──────────────────────────────
CREATE OR REPLACE FUNCTION public.create_lease(
    p_user_id         UUID,
    p_amount          NUMERIC,
    p_operation_type  TEXT,
    p_billing_mode    TEXT DEFAULT 'strict',
    p_floor           NUMERIC DEFAULT 0,
    p_max_concurrent  INTEGER DEFAULT NULL,
    p_ttl_seconds     INTEGER DEFAULT 600,
    p_model           TEXT DEFAULT NULL,
    p_overdraft_floor NUMERIC DEFAULT NULL,
    p_metadata        JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_balance         NUMERIC;
    v_plan_id         UUID;
    v_free_allowance  NUMERIC;
    v_period_start    DATE;
    v_used            NUMERIC;
    v_allowance_avail NUMERIC := 0;
    v_active_cnt      INTEGER;
    v_reserved        NUMERIC;
    v_available       NUMERIC;
    v_cap             RECORD;
    v_cap_window      TIMESTAMPTZ;
    v_cap_spend       NUMERIC;
    v_lease_id        UUID;
    v_expires_at      TIMESTAMPTZ;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        RETURN jsonb_build_object('error', 'unauthorized');
    END IF;

    IF p_amount IS NULL OR NOT (p_amount = p_amount)
       OR p_amount = 'Infinity'::numeric OR p_amount = '-Infinity'::numeric OR p_amount <= 0 THEN
        RETURN jsonb_build_object('error', 'invalid_amount', 'amount', p_amount);
    END IF;

    -- Lock the balance row (and capture plan_id), creating it if missing.
    SELECT balance, plan_id INTO v_balance, v_plan_id
    FROM public.user_credits WHERE user_id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO public.user_credits (user_id, balance, lifetime_purchased)
        VALUES (p_user_id, 0, 0) ON CONFLICT (user_id) DO NOTHING;
        SELECT balance, plan_id INTO v_balance, v_plan_id
        FROM public.user_credits WHERE user_id = p_user_id FOR UPDATE;
    END IF;

    -- (1A) Allowance headroom: remaining free allowance counts toward available funds
    --      at admission so a free-tier user can hold a worst-case amount even when
    --      their cash balance is below the hold (Fix 1 / D4).
    IF v_plan_id IS NOT NULL THEN
        SELECT free_allowance INTO v_free_allowance
        FROM public.credit_plans WHERE id = v_plan_id;
        v_period_start := (date_trunc('month', now() AT TIME ZONE 'UTC'))::DATE;
        SELECT COALESCE(SUM(usage), 0) INTO v_used
        FROM public.credit_usage_window
        WHERE user_id = p_user_id AND plan_id = v_plan_id AND billing_period = v_period_start;
        v_allowance_avail := GREATEST(COALESCE(v_free_allowance, 0) - COALESCE(v_used, 0), 0);
    END IF;

    -- (2) Concurrency: count active, unexpired leases for this operation type.
    IF p_max_concurrent IS NOT NULL THEN
        SELECT COUNT(*) INTO v_active_cnt
        FROM public.credit_reservations
        WHERE user_id = p_user_id AND operation_type = p_operation_type
          AND status = 'active' AND expires_at > now();
        IF v_active_cnt >= p_max_concurrent THEN
            RETURN jsonb_build_object('error', 'concurrency_limit', 'billing_mode', p_billing_mode);
        END IF;
    END IF;

    -- (3) Deny spend cap at admission.
    FOR v_cap IN
        SELECT cap_type, model, cap_limit FROM public.credit_spend_caps
        WHERE user_id = p_user_id AND action = 'deny' AND (model IS NULL OR model = p_model)
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
        IF v_cap_spend + p_amount > v_cap.cap_limit THEN
            RETURN jsonb_build_object('error', 'cap_reached', 'billing_mode', p_billing_mode);
        END IF;
    END LOOP;

    -- (4) effective_available = balance − Σ active holds + allowance headroom.
    --     Allowance covers the gap so free-tier users aren't falsely rejected.
    SELECT COALESCE(SUM(amount), 0) INTO v_reserved
    FROM public.credit_reservations
    WHERE user_id = p_user_id AND status = 'active' AND expires_at > now();

    v_available := v_balance - v_reserved + v_allowance_avail;
    IF v_available - p_amount < p_floor THEN
        RETURN jsonb_build_object(
            'error', 'insufficient_credits',
            'available', v_available, 'reserved', v_reserved, 'billing_mode', p_billing_mode
        );
    END IF;

    -- (5) Insert the active lease.
    v_expires_at := now() + make_interval(secs => p_ttl_seconds);
    INSERT INTO public.credit_reservations
        (user_id, amount, operation_type, metadata, expires_at, status, billing_mode, overdraft_floor)
    VALUES
        (p_user_id, p_amount, p_operation_type, COALESCE(p_metadata, '{}'::jsonb),
         v_expires_at, 'active', p_billing_mode, p_overdraft_floor)
    RETURNING id INTO v_lease_id;

    RETURN jsonb_build_object(
        'lease_id', v_lease_id,
        'user_id', p_user_id,
        'amount', p_amount,
        'available', v_available - p_amount,
        'reserved', v_reserved + p_amount,
        'billing_mode', p_billing_mode,
        'expires_at', v_expires_at
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_lease(UUID, NUMERIC, TEXT, TEXT, NUMERIC, INTEGER, INTEGER, TEXT, NUMERIC, JSONB) FROM anon, authenticated;

-- ── (B) deduct_with_allowance: skip_allowance + correct idempotent balance_after ─
CREATE OR REPLACE FUNCTION public.deduct_with_allowance(
    p_user_id          UUID,
    p_amount           NUMERIC,
    p_idempotency_key  TEXT DEFAULT NULL,
    p_min_balance      NUMERIC DEFAULT 0,
    p_model            TEXT DEFAULT NULL,
    p_metadata         JSONB DEFAULT '{}'::jsonb,
    p_skip_allowance   BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_balance              NUMERIC;
    v_plan_id              UUID;
    v_free_allowance       NUMERIC;
    v_period_start         DATE;
    v_used                 NUMERIC;
    v_remaining            NUMERIC;
    v_consume              NUMERIC := 0;
    v_net                  NUMERIC;
    v_cap                  RECORD;
    v_cap_spend            NUMERIC;
    v_cap_window           TIMESTAMPTZ;
    v_cap_warning          TEXT := NULL;
    v_new_balance          NUMERIC;
    v_transaction_id       UUID;
    v_metadata             JSONB;
    v_existing_id          UUID;
    v_existing_amt         NUMERIC;
    v_existing_cons        NUMERIC;
    v_existing_bal_after   NUMERIC;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        RETURN jsonb_build_object('error', 'unauthorized');
    END IF;

    IF p_amount IS NULL
       OR NOT (p_amount = p_amount)
       OR p_amount = 'Infinity'::numeric
       OR p_amount = '-Infinity'::numeric
       OR p_amount < 0 THEN
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

    -- (2) Idempotency replay: return the original balance_after from tx metadata
    --     rather than the (wrong) current balance (Fix 8).
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id,
               ABS(amount),
               COALESCE((metadata->>'allowance_consumed')::numeric, 0),
               COALESCE((metadata->>'balance_after')::numeric, v_balance)
        INTO v_existing_id, v_existing_amt, v_existing_cons, v_existing_bal_after
        FROM public.credit_transactions
        WHERE user_id = p_user_id
          AND metadata->>'idempotency_key' = p_idempotency_key
        LIMIT 1;
        IF FOUND THEN
            RETURN jsonb_build_object(
                'transaction_id', v_existing_id,
                'amount', v_existing_amt,
                'allowance_consumed', v_existing_cons,
                'balance_after', v_existing_bal_after,
                'idempotent', true,
                'cap_warning', NULL
            );
        END IF;
    END IF;

    -- (3) Allowance: skipped for fixed-cost jobs (p_skip_allowance = TRUE, Fix 7).
    IF NOT p_skip_allowance AND v_plan_id IS NOT NULL THEN
        SELECT free_allowance INTO v_free_allowance
        FROM public.credit_plans WHERE id = v_plan_id;
        v_period_start := (date_trunc('month', now() AT TIME ZONE 'UTC'))::DATE;
        SELECT COALESCE(SUM(usage), 0) INTO v_used
        FROM public.credit_usage_window
        WHERE user_id = p_user_id AND plan_id = v_plan_id AND billing_period = v_period_start;
        v_remaining := GREATEST(COALESCE(v_free_allowance, 0) - COALESCE(v_used, 0), 0);
        v_consume   := LEAST(v_remaining, p_amount);
    END IF;

    v_net := p_amount - v_consume;

    BEGIN
        IF v_consume > 0 THEN
            INSERT INTO public.credit_usage_window (user_id, plan_id, billing_period, usage)
            VALUES (p_user_id, v_plan_id, v_period_start, v_consume)
            ON CONFLICT (user_id, plan_id, billing_period) DO UPDATE SET
                usage = public.credit_usage_window.usage + v_consume,
                updated_at = now();
        END IF;

        FOR v_cap IN
            SELECT action, cap_type, model, cap_limit
            FROM public.credit_spend_caps
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
            IF v_cap_spend + v_net > v_cap.cap_limit THEN
                IF v_cap.action = 'deny' THEN
                    RAISE EXCEPTION 'ducto_cap_reached' USING ERRCODE = 'DU001';
                ELSE
                    IF v_cap_warning IS NULL THEN v_cap_warning := v_cap.action; END IF;
                END IF;
            END IF;
        END LOOP;

        IF v_balance - v_net < p_min_balance THEN
            RAISE EXCEPTION 'ducto_insufficient_credits' USING ERRCODE = 'DU002';
        END IF;

        UPDATE public.user_credits
        SET balance = balance - v_net, updated_at = now()
        WHERE user_id = p_user_id
        RETURNING balance INTO v_new_balance;

        -- Store balance_after in metadata for correct idempotent replay (Fix 8).
        v_metadata := COALESCE(p_metadata, '{}'::jsonb)
            || jsonb_strip_nulls(jsonb_build_object('idempotency_key', p_idempotency_key, 'model', p_model))
            || jsonb_build_object('allowance_consumed', v_consume, 'balance_after', v_new_balance);

        INSERT INTO public.credit_transactions (user_id, amount, type, metadata)
        VALUES (p_user_id, -v_net, 'usage', v_metadata)
        RETURNING id INTO v_transaction_id;

    EXCEPTION
        WHEN SQLSTATE 'DU001' THEN
            RETURN jsonb_build_object('error', 'cap_reached', 'action', 'deny');
        WHEN SQLSTATE 'DU002' THEN
            RETURN jsonb_build_object('error', 'insufficient_credits');
        WHEN unique_violation THEN
            SELECT id,
                   ABS(amount),
                   COALESCE((metadata->>'allowance_consumed')::numeric, 0),
                   COALESCE((metadata->>'balance_after')::numeric, v_balance)
            INTO v_existing_id, v_existing_amt, v_existing_cons, v_existing_bal_after
            FROM public.credit_transactions
            WHERE user_id = p_user_id AND metadata->>'idempotency_key' = p_idempotency_key
            LIMIT 1;
            RETURN jsonb_build_object(
                'transaction_id', v_existing_id, 'amount', v_existing_amt,
                'allowance_consumed', v_existing_cons, 'balance_after', v_existing_bal_after,
                'idempotent', true, 'cap_warning', NULL
            );
    END;

    RETURN jsonb_build_object(
        'transaction_id', v_transaction_id,
        'amount', v_net,
        'allowance_consumed', v_consume,
        'balance_after', v_new_balance,
        'idempotent', false,
        'cap_warning', v_cap_warning
    );
END;
$$;

-- Grant the 7-argument overload (old 6-arg signature still works via defaults).
REVOKE EXECUTE ON FUNCTION public.deduct_with_allowance(UUID, NUMERIC, TEXT, NUMERIC, TEXT, JSONB, BOOLEAN) FROM anon, authenticated;

-- ── (C) settle_lease: correct idempotent balance_after ───────────────────────
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

    -- Allowance consume on actual cost (mirrors deduct_with_allowance).
    IF v_plan_id IS NOT NULL THEN
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

NOTIFY pgrst, 'reload schema';
