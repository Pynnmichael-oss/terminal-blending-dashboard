-- 00000000000006_blend_case_results.sql
--
-- blend_case_results holds the final, one-per-case outcome record: close
-- gauge + open-to-close reconciliation, DVPE/quality result set,
-- certification/release decision, operational notes, and completion
-- metadata. It is created/updated as the case moves through
-- "Close Gauge", "Certify & Release" and "Close / Packet", and is what
-- lets planned values (on blend_cases / blend_plans) stay untouched while
-- actual outcomes accumulate here.

create table if not exists public.blend_case_results (
  id                  uuid primary key default gen_random_uuid(),
  blend_case_id       uuid not null unique references public.blend_cases (id) on delete cascade,

  final_quantity_bbl   numeric(12,1), -- verified close-gauge net volume (c.closeGauge.netBbl)

  open_gauge          jsonb, -- { at, height, temperature, api, netBbl, water, device, operator }
  close_gauge         jsonb, -- same shape as open_gauge

  expected_close_bbl   numeric(12,1),
  actual_close_bbl     numeric(12,1),
  variance_bbl         numeric(10,1),
  within_tolerance     boolean,
  variance_reason      text,

  quality_data        jsonb not null default '{}'::jsonb,
  -- preBlendResults (DVPE/Ptot validation samples), iterations/measurements,
  -- certification.{route, release} -- all flexible/evolving result shapes.

  operational_notes    text,

  completed_by         text,
  completed_at         timestamptz,

  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on table public.blend_case_results is
  'One row per blend case holding final/actual outcomes: close gauge, reconciliation, quality (DVPE) results, certification/release, and completion. Planned values live on blend_cases/blend_plans and are never overwritten here.';

create index if not exists blend_case_results_case_idx on public.blend_case_results (blend_case_id);

create trigger blend_case_results_set_updated_at
  before update on public.blend_case_results
  for each row execute function public.set_updated_at();
