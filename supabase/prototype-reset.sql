-- Fort Worth Terminal Dashboard - prototype Supabase reset
-- Run this once in a NEW Supabase project.

begin;

create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.blend_plans (
  id uuid primary key default gen_random_uuid(),
  plan_code text not null unique,
  label text not null default 'Planned blend',
  status text not null default 'planned' check (status in ('planned','deferred','promoted','cancelled')),
  grade text not null default 'REGULAR' check (grade in ('REGULAR','PREMIUM')),
  tank text not null,
  tank_no text,
  window_start text not null,
  window_end text not null,
  truck_start text,
  truck_finish text,
  est_pumpable_bbl numeric(12,1) not null default 0,
  est_tov_bbl numeric(12,1) not null default 0,
  incoming_rvp numeric(6,3) not null default 0,
  target_rvp numeric(6,3) not null default 0,
  butane_bbl numeric(12,1) not null default 0,
  trucks integer not null default 0 check (trucks >= 0),
  blended_rvp numeric(6,3) not null default 0,
  source_week text,
  assumption text,
  note text,
  reason text,
  planner_snapshot jsonb not null default '{}'::jsonb,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.blend_cases (
  id uuid primary key default gen_random_uuid(),
  case_number text not null unique,
  plan_id uuid unique references public.blend_plans(id) on delete set null,
  source_plan_snapshot jsonb not null default '{}'::jsonb,
  grade text not null default 'REGULAR' check (grade in ('REGULAR','PREMIUM')),
  tank text not null,
  tank_no text,
  row_label text,
  operator text not null,
  pq text not null,
  stage smallint not null default 1 check (stage between 0 and 10),
  status text not null default 'open' check (status in ('open','hold','closed','abandoned')),
  hold_reason text,
  hold_at timestamptz,
  decision text check (decision in ('exact-load','round-up','truncate')),
  planned_est_vol_bbl numeric(12,1),
  planned_est_rvp numeric(6,3),
  actual_tov_bbl numeric(12,1),
  case_state jsonb not null default '{"data":{},"deliveries":[],"log":[],"results":{}}'::jsonb,
  checkout_device text,
  checkout_by text,
  checkout_at timestamptz,
  abandoned_at timestamptz,
  abandoned_by text,
  abandonment_reason text,
  completed_at timestamptz,
  record_version integer not null default 1 check (record_version >= 1),
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.terminal_state (
  key text primary key,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create unique index blend_cases_one_active_per_tank on public.blend_cases(tank)
  where status not in ('closed','abandoned');
create index blend_plans_status_idx on public.blend_plans(status);
create index blend_cases_status_idx on public.blend_cases(status);

create trigger blend_plans_set_updated_at before update on public.blend_plans
  for each row execute function public.set_updated_at();
create trigger blend_cases_set_updated_at before update on public.blend_cases
  for each row execute function public.set_updated_at();
create trigger terminal_state_set_updated_at before update on public.terminal_state
  for each row execute function public.set_updated_at();

insert into public.terminal_state(key,state) values (
  'certified_butane_compliance',
  jsonb_build_object('cumulative_volume_gal',0,'cycle_start_date',current_date::text,'last_sample_date',null,'sample_ordered',false,'ceiling_reached',false)
);

alter table public.blend_plans enable row level security;
alter table public.blend_cases enable row level security;
alter table public.terminal_state enable row level security;

create policy "prototype blend plans" on public.blend_plans for all to anon,authenticated using (true) with check (true);
create policy "prototype blend cases" on public.blend_cases for all to anon,authenticated using (true) with check (true);
create policy "prototype terminal state" on public.terminal_state for all to anon,authenticated using (true) with check (true);

insert into storage.buckets(id,name,public,file_size_limit)
values ('blend-case-files','blend-case-files',false,26214400);
create policy "prototype read blend files" on storage.objects for select to anon,authenticated using (bucket_id='blend-case-files');
create policy "prototype insert blend files" on storage.objects for insert to anon,authenticated with check (bucket_id='blend-case-files');
create policy "prototype update blend files" on storage.objects for update to anon,authenticated using (bucket_id='blend-case-files') with check (bucket_id='blend-case-files');
create policy "prototype delete blend files" on storage.objects for delete to anon,authenticated using (bucket_id='blend-case-files');

commit;
