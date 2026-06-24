-- ducto: aggregate statistics across all users.
-- Idempotent — safe to run multiple times (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION public.aggregate_stats(p_start TIMESTAMPTZ, p_end TIMESTAMPTZ)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    result JSON;
    day_count BIGINT;
BEGIN
    -- Count distinct days in the window
    SELECT COUNT(DISTINCT created_at::DATE) INTO day_count
    FROM public.credit_transactions
    WHERE type = 'usage'
      AND amount < 0
      AND created_at >= p_start
      AND created_at <= p_end;

    SELECT json_build_object(
        'total_credits_consumed', COALESCE(SUM(ABS(amount))::BIGINT, 0),
        'active_users', COUNT(DISTINCT user_id)::BIGINT,
        'avg_daily_spend', CASE WHEN day_count > 0 THEN COALESCE(SUM(ABS(amount)) / day_count, 0)::BIGINT ELSE 0 END,
        'top_model', COALESCE(
            (SELECT metadata->>'model'
             FROM public.credit_transactions
             WHERE type = 'usage'
               AND amount < 0
               AND created_at >= p_start
               AND created_at <= p_end
             GROUP BY metadata->>'model'
             ORDER BY SUM(ABS(amount)) DESC
             LIMIT 1),
            ''
        ),
        'top_user', COALESCE(
            (SELECT user_id::TEXT
             FROM public.credit_transactions
             WHERE type = 'usage'
               AND amount < 0
               AND created_at >= p_start
               AND created_at <= p_end
             GROUP BY user_id
             ORDER BY SUM(ABS(amount)) DESC
             LIMIT 1),
            ''
        )
    ) INTO result
    FROM public.credit_transactions
    WHERE type = 'usage'
      AND amount < 0
      AND created_at >= p_start
      AND created_at <= p_end;

    RETURN result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.aggregate_stats FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';
