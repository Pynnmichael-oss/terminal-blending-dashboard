-- 00000000000014_blend_case_uniqueness_constraints.sql
--
-- Hardening pass, part 2: replace the read-before-insert checks in
-- create_blend_case (vulnerable to two concurrent requests both passing
-- the check before either commits) with real database constraints. The
-- constraint is the final authority; create_blend_case keeps a friendly
-- pre-check for a good error message, but a unique-violation is what
-- actually prevents the race.

-- One active case per tank. Active = open or hold; closed/abandoned cases
-- are excluded so a tank can be reused once its case is finished.
create unique index if not exists blend_cases_one_active_per_tank
  on public.blend_cases (tank_key)
  where status in ('open', 'hold');

-- A promoted planner row can back at most one case. plan_id is null for
-- cases created without a planner row (legacy/manual), so the index is
-- partial on "not null".
create unique index if not exists blend_cases_plan_id_unique
  on public.blend_cases (plan_id)
  where plan_id is not null;
