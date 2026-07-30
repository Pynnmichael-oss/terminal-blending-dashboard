-- 00000000000004_blend_case_deliveries.sql
--
-- blend_case_deliveries is the closest real analog to the brief's
-- "blend_components": each row is one truck load of butane against a case,
-- carrying a planned_bbl (set at approval time) and an actual_bbl that is
-- only ever filled in independently once the truck is verified/offloaded
-- (state.cases[].deliveries[] in the app). Planned values are never
-- overwritten when actuals are recorded.

create table if not exists public.blend_case_deliveries (
  id              uuid primary key default gen_random_uuid(),
  blend_case_id   uuid not null references public.blend_cases (id) on delete cascade,
  sequence        integer not null, -- truck number within the case (c.deliveries[].n)
  bol             text,             -- bill of lading reference
  driver          text,
  operator        text,
  status          text not null default 'offloading'
                    check (status in ('offloading', 'complete', 'refused')),
  planned_bbl     numeric(10,1) not null,
  actual_bbl      numeric(10,1), -- null until verified at offload completion
  worksheet       jsonb not null default '{}'::jsonb, -- pre-transfer checklist booleans
  started_at      timestamptz,
  completed_at    timestamptz,
  refused_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  unique (blend_case_id, sequence)
);

comment on table public.blend_case_deliveries is
  'One row per truck delivery against a blend case: planned_bbl is fixed at load-plan approval, actual_bbl is set independently once the truck is verified. This is the planned-vs-actual "component" of the domain.';

create index if not exists blend_case_deliveries_case_idx on public.blend_case_deliveries (blend_case_id);
create index if not exists blend_case_deliveries_status_idx on public.blend_case_deliveries (status);

create trigger blend_case_deliveries_set_updated_at
  before update on public.blend_case_deliveries
  for each row execute function public.set_updated_at();
