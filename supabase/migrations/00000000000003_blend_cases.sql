-- 00000000000003_blend_cases.sql
--
-- blend_cases is the core execution record (state.cases[] / makeCase() in
-- blend-case-manager.html). The app models a 10-step lifecycle via a numeric
-- "stage" (see STAGES constant in the app) layered on top of a coarse
-- status (open / hold / closed). We keep both because the UI's stepper,
-- gating logic ("editable(c)"), and board grouping all key off stage, while
-- status is what a simple event/history model wants to track.
--
-- case_data holds the parts of the app's nested state that are still
-- actively evolving in the prototype and don't yet warrant first-class
-- columns (packet/document checklist, certification route bookkeeping,
-- pre-blend DVPE validation samples, mixing/settle timestamps, compliance
-- sampling linkage, device checkout lock). These can be promoted to their
-- own tables in a later milestone once the shape stabilizes.

create table if not exists public.blend_cases (
  id                 uuid primary key default gen_random_uuid(),
  case_number        text not null unique, -- e.g. 'BL-2026-0312', matches app-generated id
  plan_id            uuid references public.blend_plans (id) on delete set null,
  source_plan_snapshot jsonb, -- frozen copy of the plan at promotion time (c.sourcePlan)

  grade              text not null default 'REGULAR' check (grade in ('REGULAR', 'PREMIUM')),
  tank               text not null,
  tank_no            text not null,
  row_label          text, -- c.row, a short display label

  operator           text not null,
  pq                 text not null, -- PQ / quality reviewer name

  -- Lifecycle: stage is the 10-step position (0..9, see STAGES in the app).
  -- status is the coarse state used for simple filtering/history.
  stage              smallint not null default 0 check (stage between 0 and 9),
  status             text not null default 'open' check (status in ('open', 'hold', 'closed')),
  hold_reason        text,
  hold_at            timestamptz,

  decision           text check (decision in ('exact-load', 'round-up', 'truncate')),

  -- Planned vs actual, kept separate and never overwritten by each other.
  planned_est_vol_bbl numeric(12,1), -- c.est.vol
  planned_est_rvp     numeric(6,3),  -- c.est.rvp
  actual_tov_bbl      numeric(12,1), -- c.act.tov, populated at open gauge

  case_data          jsonb not null default '{}'::jsonb,

  checkout_device    text,
  checkout_by        text,
  checkout_at        timestamptz,

  planned_at         timestamptz not null default now(), -- when the case was created/promoted
  started_at         timestamptz, -- first open-gauge recorded
  completed_at       timestamptz, -- when closed (mirrors blend_case_results.completed_at)

  created_by         text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table public.blend_cases is
  'Execution blend cases (Blend Case Manager board). One row per BL-2026-#### case; stage tracks the 10-step lifecycle, status is a coarse open/hold/closed flag.';
comment on column public.blend_cases.case_data is
  'Catch-all for not-yet-normalized nested prototype state: documents/packet checklist, certification.{route,labOrder}, preBlendResults, mixing, compliance linkage, iterations. Final release + close-gauge outcome lives in blend_case_results, not here.';

create index if not exists blend_cases_status_idx on public.blend_cases (status);
create index if not exists blend_cases_stage_idx on public.blend_cases (stage);
create index if not exists blend_cases_tank_idx on public.blend_cases (tank);
create index if not exists blend_cases_plan_id_idx on public.blend_cases (plan_id);

create trigger blend_cases_set_updated_at
  before update on public.blend_cases
  for each row execute function public.set_updated_at();
