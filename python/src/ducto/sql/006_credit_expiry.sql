-- ducto: credit expiry/TTL support.
-- Idempotent — safe to run multiple times (CREATE OR REPLACE).

-- expire_credits: sweep expired credits from all users' balances.
-- Returns count and amount of expired credits. When p_dry_run is true,
-- reports without modifying any balances.
CREATE OR REPLACE FUNCTION public.expire_credits(p_dry_run BOOLEAN DEFAULT false)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_expired_count INTEGER := 0;
    v_expired_amount INTEGER := 0;
    v_user RECORD;
    v_user_expired INTEGER;
    v_current_balance INTEGER;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        RETURN jsonb_build_object('error', 'unauthorized');
    END IF;

    -- Find all users with expired grant transactions
    FOR v_user IN
        SELECT DISTINCT user_id
        FROM public.credit_transactions
        WHERE type IN ('purchase', 'adjustment')
          AND metadata ? 'expires_at'
          AND (metadata->>'expires_at')::timestamptz <= now()
    LOOP
        -- Total expired grants for this user
        SELECT COALESCE(SUM(amount), 0) INTO v_user_expired
        FROM public.credit_transactions
        WHERE user_id = v_user.user_id
          AND type IN ('purchase', 'adjustment')
          AND metadata ? 'expires_at'
          AND (metadata->>'expires_at')::timestamptz <= now();

        -- Get current balance (lock row to prevent concurrent deduction)
        SELECT COALESCE(balance, 0) INTO v_current_balance
        FROM public.user_credits
        WHERE user_id = v_user.user_id
        FOR UPDATE;

        -- Cap at current balance
        v_user_expired := LEAST(v_user_expired, v_current_balance);

        IF v_user_expired > 0 THEN
            v_expired_count := v_expired_count + 1;
            v_expired_amount := v_expired_amount + v_user_expired;

            IF NOT p_dry_run THEN
                -- Deduct expired amount from balance
                UPDATE public.user_credits
                SET balance = balance - v_user_expired,
                    updated_at = now()
                WHERE user_id = v_user.user_id;

                -- Log adjustment transaction
                INSERT INTO public.credit_transactions (user_id, amount, type, metadata)
                VALUES (v_user.user_id, -v_user_expired, 'adjustment',
                        jsonb_build_object('reason', 'credit_expired', 'expired_amount', v_user_expired));
            END IF;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'expired_count', v_expired_count,
        'expired_amount', v_expired_amount,
        'dry_run', p_dry_run
    );
END;
$$;

-- Index for expiry sweep (finds expired grants without full scan)
CREATE INDEX IF NOT EXISTS idx_credit_transactions_expires_at
    ON public.credit_transactions ((metadata ->> 'expires_at'))
    WHERE metadata ? 'expires_at';

REVOKE EXECUTE ON FUNCTION public.expire_credits FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';
