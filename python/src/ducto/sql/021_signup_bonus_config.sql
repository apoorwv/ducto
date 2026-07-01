-- ducto migration 021: configurable signup bonus amount.
-- Replaces hardcoded 50 with value from active pricing config's
-- `signup_bonus` field (millicredits). Falls back to 50 if unset.

CREATE OR REPLACE FUNCTION public.grant_signup_bonus()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_bonus NUMERIC;
BEGIN
  SELECT COALESCE(
    (SELECT (config->>'signup_bonus')::numeric FROM public.credit_pricing_config WHERE active = TRUE LIMIT 1),
    50
  ) INTO v_bonus;

  INSERT INTO public.user_credits (user_id, balance, lifetime_purchased)
  VALUES (NEW.id, v_bonus, 0)
  ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.credit_transactions (user_id, amount, type)
  VALUES (NEW.id, v_bonus, 'signup_bonus');

  RETURN NEW;
END;
$$;
