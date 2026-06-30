-- ducto: drop legacy reserve_credits and deduct_credits RPCs.
--
-- These two-phase functions (reserve then deduct) predated the atomic lease
-- lifecycle introduced in 016_lease_lifecycle.sql. All admission control now
-- goes through create_lease / settle_lease / release_lease / renew_lease.
-- The credit_reservations TABLE itself is kept — it backs the lease system.

DROP FUNCTION IF EXISTS public.reserve_credits(UUID, NUMERIC, TEXT, JSONB, NUMERIC);
DROP FUNCTION IF EXISTS public.deduct_credits(UUID, UUID, NUMERIC, JSONB);

-- Also drop the old INTEGER-signature stubs that 002_credit_rpcs.sql cleaned up
-- at install time, in case any environment still has them.
DROP FUNCTION IF EXISTS public.reserve_credits(UUID, INTEGER, TEXT, JSONB, INTEGER);
DROP FUNCTION IF EXISTS public.deduct_credits(UUID, UUID, INTEGER, JSONB);

-- Refresh PostgREST schema cache so the removed RPCs are no longer advertised.
NOTIFY pgrst, 'reload schema';
