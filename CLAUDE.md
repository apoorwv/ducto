# ducto — Declarative Credit Calculation Engine

**Stack:** Pydantic (schemas), PyYAML/Pydantic (config), Python `ast` (safe expressions). Opt. Supabase/Postgres backends.

Standalone Python library. Calculates credit costs from usage metrics (model tokens, tools, search/RAG) using pricing expressions (YAML files or DB-backed `credit_pricing_config` table). Safe expression engine — no eval/exec. Stateless, pure calculation. Used by zonastery's billing pipeline for per-request credit deduction.
