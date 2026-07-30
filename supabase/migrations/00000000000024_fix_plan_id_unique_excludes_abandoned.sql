-- 00000000000024_fix_plan_id_unique_excludes_abandoned.sql
--
-- Fixes a real bug found while driving blend-case-manager.html against
-- the live project: blend_cases_plan_id_unique (migration 014) is
-- `unique on (plan_id) where plan_id is not null` -- with NO exclusion
-- for abandoned cases, unlike blend_cases_one_active_per_tank on the
-- same migration, which correctly excludes closed/abandoned via
-- `where status in ('open', 'hold')`.
--
-- abandon_blend_case (migration 018) reverts the source blend_plans row
-- back to status='proposed' specifically "so it can be promoted again"
-- (its own comment, and docs/supabase-persistence.md's "Hardening pass"
-- section, say exactly this). But because the OLD unique index has no
-- status exclusion, the abandoned case's row permanently occupies that
-- plan_id forever -- create_blend_case's re-promotion attempt hits
-- unique_violation on blend_cases_plan_id_unique (not the tank-key
-- index, which is correctly clear) every time, regardless of the plan's
-- status. Reproduced live: promoted a plan, abandoned the resulting
-- case (plan correctly reverted to 'proposed'), then attempted to
-- promote the very same plan again through the actual browser UI --
-- rejected with 23505 "another request just created an active case for
-- this tank or promoted this plan", even though no other case existed
-- and the DB-level tank-key check was satisfied.
--
-- A CLOSED case's plan_id should still remain permanently claimed --
-- that plan legitimately completed a blend and re-promoting it would be
-- a real, meaningful duplicate. Only 'abandoned' should release it,
-- matching abandon_blend_case's own documented intent.

drop index if exists public.blend_cases_plan_id_unique;

create unique index blend_cases_plan_id_unique
  on public.blend_cases (plan_id)
  where plan_id is not null and status <> 'abandoned';

comment on index public.blend_cases_plan_id_unique is
  'A promoted planner row can back at most one non-abandoned case. Abandoned cases release their plan_id so the plan can be promoted again, per abandon_blend_case''s documented behavior; closed cases keep it claimed permanently.';
