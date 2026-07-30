-- 00000000000002_blend_plans.sql
--
-- blend_plans holds proposed butane-blend planner rows created in the
-- "Blend Planner" board of blend-case-manager.html (state.plans[] / makePlan()).
-- A plan is promoted into an execution case (blend_cases) via the
-- promote_blend_plan() RPC (see migration 007). We never delete a promoted
-- plan row -- we flip its status to 'promoted' so the planner -> case link
-- and history remain intact.

create table if not exists public.blend_plans (
  id                  uuid primary key default gen_random_uuid(),
  plan_code           text not null unique, -- e.g. 'PLAN-2026-W31-01', matches app-generated id
  label               text not null default 'Planned blend',
  grade               text not null default 'REGULAR' check (grade in ('REGULAR', 'PREMIUM')),
  tank                text not null,
  tank_no             text not null,
  window_start        text not null, -- kept as free-text to match existing app format ("2026-07-28 06:00")
  window_end          text not null,
  est_pumpable_bbl     numeric(12,1) not null default 0,
  est_tov_bbl          numeric(12,1) not null default 0,
  incoming_rvp         numeric(6,3) not null default 0,
  target_rvp           numeric(6,3) not null default 8.85,
  butane_bbl           numeric(12,1) not null default 0,
  trucks              integer not null default 0,
  blended_rvp          numeric(6,3) not null default 0,
  truck_start          text,
  truck_finish         text,
  status              text not null default 'proposed'
                         check (status in ('proposed', 'deferred', 'promoted')),
  reason              text, -- defer reason (p.reason)
  note                text, -- defer / promote note (p.note)
  source_week          text,
  assumption          text,
  created_by           text, -- free-text operator name; no auth system exists yet (see RLS migration)
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on table public.blend_plans is
  'Proposed butane-blend planner rows (Blend Planner board). Promoted rows are linked to blend_cases via blend_cases.plan_id and kept (status=promoted), never deleted.';

create index if not exists blend_plans_status_idx on public.blend_plans (status);
create index if not exists blend_plans_tank_idx on public.blend_plans (tank);

create trigger blend_plans_set_updated_at
  before update on public.blend_plans
  for each row execute function public.set_updated_at();
