-- ducto: per-user spend caps and rate limiting.
-- credit_spend_caps table and check_spend_cap RPC.

CREATE TABLE IF NOT EXISTS public.credit_spend_caps (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES public.user_credits(user_id),
  cap_type TEXT NOT NULL CHECK (cap_type IN ('daily', 'monthly')),
  model TEXT,
  cap_limit INTEGER NOT NULL,
  action TEXT NOT NULL DEFAULT 'deny' CHECK (action IN ('deny', 'warn', 'notify')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, cap_type, COALESCE(model, ''))
);

ALTER TABLE public.credit_spend_caps ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Server-only credit_spend_caps' AND tablename = 'credit_spend_caps') THEN
    CREATE POLICY "Server-only credit_spend_caps" ON public.credit_spend_caps USING (false);
  END IF;
END;
$$;

-- check_spend_cap: evaluate whether a pending deduction would exceed any cap.
-- Returns JSONB with capped, current_spend, cap_limit, action, model.
CREATE OR REPLACE FUNCTION public.check_spend_cap(
  p_user_id UUID,
  p_model TEXT DEFAULT NULL,
  p_amount INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cap RECORD;
  v_current_spend INTEGER;
  v_window_start TIMESTAMPTZ;
  v_now TIMESTAMPTZ := now();
BEGIN
  FOR v_cap IN
    SELECT c.cap_type, c.model, c.cap_limit, c.action
    FROM public.credit_spend_caps c
    WHERE c.user_id = p_user_id
      AND (c.model IS NULL OR c.model = p_model)
    ORDER BY c.cap_limit ASC
  LOOP
    IF v_cap.cap_type = 'daily' THEN
      v_window_start := date_trunc('day', v_now);
    ELSE
      v_window_start := date_trunc('month', v_now);
    END IF;

    SELECT COALESCE(SUM(ABS(ct.amount)), 0)
    INTO v_current_spend
    FROM public.credit_transactions ct
    WHERE ct.user_id = p_user_id
      AND ct.type IN ('usage', 'team_usage')
      AND ct.amount < 0
      AND ct.created_at >= v_window_start;

    IF v_current_spend + p_amount > v_cap.cap_limit THEN
      IF v_cap.action = 'deny' THEN
        RETURN jsonb_build_object(
          'capped', true,
          'current_spend', v_current_spend,
          'cap_limit', v_cap.cap_limit,
          'action', v_cap.action,
          'model', v_cap.model
        );
      END IF;
    END IF;
  END LOOP;

  -- Check for warn/notify caps that are exceeded
  FOR v_cap IN
    SELECT c.cap_type, c.model, c.cap_limit, c.action
    FROM public.credit_spend_caps c
    WHERE c.user_id = p_user_id
      AND (c.model IS NULL OR c.model = p_model)
      AND c.action IN ('warn', 'notify')
    ORDER BY c.cap_limit ASC
  LOOP
    IF v_cap.cap_type = 'daily' THEN
      v_window_start := date_trunc('day', v_now);
    ELSE
      v_window_start := date_trunc('month', v_now);
    END IF;

    SELECT COALESCE(SUM(ABS(ct.amount)), 0)
    INTO v_current_spend
    FROM public.credit_transactions ct
    WHERE ct.user_id = p_user_id
      AND ct.type IN ('usage', 'team_usage')
      AND ct.amount < 0
      AND ct.created_at >= v_window_start;

    IF v_current_spend + p_amount > v_cap.cap_limit THEN
      RETURN jsonb_build_object(
        'capped', false,
        'current_spend', v_current_spend,
        'cap_limit', v_cap.cap_limit,
        'action', v_cap.action,
        'model', v_cap.model
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'capped', false,
    'current_spend', 0,
    'cap_limit', 0,
    'action', null
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.check_spend_cap FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';
