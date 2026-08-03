-- 00000000000027_butane_compliance_tracker.sql
--
-- Backfills into version control a table + RPC that were applied live on
-- 2026-08-03 but never committed here (same situation as migration 026):
-- butane_compliance_tracker and add_butane_delivery_volume() already exist
-- in the running database with one seed row (cumulative_volume_gal = 8000).
-- This migration is idempotent against that live state (create table if
-- not exists, create or replace function) so applying it is a no-op there,
-- while giving fresh environments the same schema.
--
-- Tracks cumulative butane delivery volume toward a 500,000 gallon / 90-day
-- compliance sampling ceiling. A sample should be ordered proactively at
-- 300,000 gallons (lead time), not at the 500k ceiling itself.
--
-- cycle_start_date exists on the row but nothing currently resets
-- cumulative_volume_gal on a 90-day cadence -- this is a plain running
-- total. Flagged as a follow-up; out of scope for this migration.

create table if not exists public.butane_compliance_tracker (
  id                    uuid primary key default gen_random_uuid(),
  cycle_start_date      date not null default current_date,
  cumulative_volume_gal numeric not null default 0,
  sample_ordered        boolean not null default false,
  sample_ordered_at     timestamptz,
  ceiling_reached       boolean not null default false,
  ceiling_reached_at    timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on table public.butane_compliance_tracker is
  'Single running-total row tracking cumulative butane delivery volume (gallons) toward a 500,000 gal / 90-day compliance sampling ceiling. sample_ordered flips true at 300k (lead time to order a sample before the ceiling), ceiling_reached flips true at 500k. No 90-day reset logic exists yet -- see migration header.';

alter table public.butane_compliance_tracker enable row level security;

drop policy if exists "dev_read_all" on public.butane_compliance_tracker;
create policy "dev_read_all" on public.butane_compliance_tracker
  for select to public using (true);

-- Mutation is RPC-only (add_butane_delivery_volume below, SECURITY DEFINER);
-- no insert/update/delete policy is defined, so RLS rejects direct writes
-- from anon/authenticated by default -- matching the hardened-RPC-only
-- pattern used for blend_cases (see migrations 019-023), not the older
-- full-CRUD-via-RLS pattern from migration 008.

create or replace function public.add_butane_delivery_volume(p_volume_gal numeric)
returns butane_compliance_tracker
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row butane_compliance_tracker;
begin
  update butane_compliance_tracker
  set cumulative_volume_gal = cumulative_volume_gal + p_volume_gal,
      updated_at = now()
  where id = (select id from butane_compliance_tracker order by created_at desc limit 1)
  returning * into v_row;

  if v_row.cumulative_volume_gal >= 300000 and not v_row.sample_ordered then
    update butane_compliance_tracker
    set sample_ordered = true, sample_ordered_at = now()
    where id = v_row.id
    returning * into v_row;
  end if;

  if v_row.cumulative_volume_gal >= 500000 and not v_row.ceiling_reached then
    update butane_compliance_tracker
    set ceiling_reached = true, ceiling_reached_at = now()
    where id = v_row.id
    returning * into v_row;
  end if;

  return v_row;
end;
$function$;

-- Fix the actual gap: the live version of this function (applied outside
-- version control) only granted EXECUTE to authenticated/service_role.
-- This app's browser client authenticates as anon only (no login exists --
-- see supabase-client.js), so as deployed the RPC was uncallable from the
-- app itself. Every other browser-callable RPC in this schema grants
-- `anon, authenticated` (see migrations 008, 012, 016-022); this brings
-- this RPC in line with that convention.
grant execute on function public.add_butane_delivery_volume(numeric) to anon, authenticated;

-- Seed row: only insert if the table is empty, so this is a no-op against
-- the live database (which already has its seeded row at 8,000 gal) but
-- still gives a fresh environment a starting row to update.
insert into public.butane_compliance_tracker (cumulative_volume_gal)
select 8000
where not exists (select 1 from public.butane_compliance_tracker);
