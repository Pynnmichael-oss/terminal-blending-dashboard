-- 00000000000020_blend_case_delivery_rpcs_and_constraints.sql
--
-- Hardening pass, part 8: replace the generic upsertDelivery() write path
-- (which could silently overwrite a completed delivery's actual_bbl or
-- reset its status) with specific lifecycle functions, plus numeric/
-- lifecycle invariant constraints on blend_cases and
-- blend_case_deliveries.

-- plan_blend_case_delivery: add/plan a truck load (offloading, no actual yet).
create or replace function public.plan_blend_case_delivery(
  p_blend_case_id uuid,
  p_sequence      integer,
  p_planned_bbl   numeric,
  p_bol           text default null,
  p_driver        text default null,
  p_operator      text default null,
  p_worksheet     jsonb default '{}'::jsonb
)
returns public.blend_case_deliveries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.blend_case_deliveries;
  v_case public.blend_cases;
begin
  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.status not in ('open', 'hold') then
    raise exception 'case % is % and cannot receive a new delivery', v_case.case_number, v_case.status;
  end if;

  insert into public.blend_case_deliveries (
    blend_case_id, sequence, planned_bbl, bol, driver, operator, status, started_at, worksheet
  ) values (
    p_blend_case_id, p_sequence, p_planned_bbl, p_bol, p_driver, p_operator, 'offloading', now(), coalesce(p_worksheet, '{}'::jsonb)
  )
  returning * into v_row;

  insert into public.blend_case_events (blend_case_id, event_type, message, created_by)
  values (p_blend_case_id, 'delivery', format('Truck %s worksheet complete; offload started', p_sequence), coalesce(p_operator, 'system'));

  return v_row;
end;
$$;

comment on function public.plan_blend_case_delivery is
  'Starts a new truck delivery (status=offloading) against an active case. Sequence uniqueness is enforced by the existing (blend_case_id, sequence) unique constraint.';

grant execute on function public.plan_blend_case_delivery(uuid, integer, numeric, text, text, text, jsonb) to anon, authenticated;

-- complete_blend_case_delivery: verified net volume at offload completion.
create or replace function public.complete_blend_case_delivery(
  p_delivery_id uuid,
  p_actual_bbl  numeric,
  p_actor       text
)
returns public.blend_case_deliveries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.blend_case_deliveries;
begin
  select * into v_row from public.blend_case_deliveries where id = p_delivery_id for update;
  if not found then
    raise exception 'delivery % not found', p_delivery_id;
  end if;
  if v_row.status <> 'offloading' then
    raise exception 'delivery % is % and cannot be completed directly; use correct_completed_blend_case_delivery for corrections', v_row.id, v_row.status;
  end if;
  if p_actual_bbl is null or p_actual_bbl < 0 then
    raise exception 'a nonnegative actual volume is required to complete a delivery';
  end if;

  update public.blend_case_deliveries set
    status = 'complete', actual_bbl = p_actual_bbl, completed_at = now()
  where id = p_delivery_id
  returning * into v_row;

  insert into public.blend_case_events (blend_case_id, event_type, message, created_by)
  values (v_row.blend_case_id, 'delivery', format('Truck %s complete; %s bbl verified', v_row.sequence, p_actual_bbl), p_actor);

  return v_row;
end;
$$;

comment on function public.complete_blend_case_delivery is
  'Completes an offloading delivery with its verified actual volume. Cannot be used to change an already-complete delivery -- see correct_completed_blend_case_delivery.';

grant execute on function public.complete_blend_case_delivery(uuid, numeric, text) to anon, authenticated;

-- refuse_blend_case_delivery: truck refused at pre-transfer verification.
create or replace function public.refuse_blend_case_delivery(
  p_delivery_id uuid,
  p_actor       text,
  p_reason      text default null
)
returns public.blend_case_deliveries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.blend_case_deliveries;
begin
  select * into v_row from public.blend_case_deliveries where id = p_delivery_id for update;
  if not found then
    raise exception 'delivery % not found', p_delivery_id;
  end if;
  if v_row.status <> 'offloading' then
    raise exception 'delivery % is % and cannot be refused', v_row.id, v_row.status;
  end if;

  update public.blend_case_deliveries set
    status = 'refused', refused_at = now()
  where id = p_delivery_id
  returning * into v_row;

  insert into public.blend_case_events (blend_case_id, event_type, message, created_by)
  values (v_row.blend_case_id, 'delivery',
    format('Truck %s refused at pre-transfer verification%s', v_row.sequence, case when p_reason is not null then ': ' || p_reason else '' end),
    p_actor);

  return v_row;
end;
$$;

comment on function public.refuse_blend_case_delivery is
  'Refuses a delivery that is still in the offloading state (pre-transfer verification failed).';

grant execute on function public.refuse_blend_case_delivery(uuid, text, text) to anon, authenticated;

-- correct_completed_blend_case_delivery: the only way to change a
-- delivery that already has status='complete'. Requires a reason and
-- writes a distinct audit event from the original completion.
create or replace function public.correct_completed_blend_case_delivery(
  p_delivery_id  uuid,
  p_actual_bbl   numeric,
  p_actor        text,
  p_reason       text
)
returns public.blend_case_deliveries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.blend_case_deliveries;
  v_prior numeric;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a reason is required to correct a completed delivery';
  end if;
  if p_actual_bbl is null or p_actual_bbl < 0 then
    raise exception 'a nonnegative actual volume is required';
  end if;

  select * into v_row from public.blend_case_deliveries where id = p_delivery_id for update;
  if not found then
    raise exception 'delivery % not found', p_delivery_id;
  end if;
  if v_row.status <> 'complete' then
    raise exception 'delivery % is not complete; use complete_blend_case_delivery instead', v_row.id;
  end if;

  v_prior := v_row.actual_bbl;

  update public.blend_case_deliveries set actual_bbl = p_actual_bbl
  where id = p_delivery_id
  returning * into v_row;

  insert into public.blend_case_events (blend_case_id, event_type, message, created_by, event_data)
  values (
    v_row.blend_case_id, 'delivery',
    format('Truck %s completed volume corrected from %s to %s bbl: %s', v_row.sequence, v_prior, p_actual_bbl, p_reason),
    p_actor, jsonb_build_object('prior_actual_bbl', v_prior, 'new_actual_bbl', p_actual_bbl, 'reason', p_reason)
  );

  return v_row;
end;
$$;

comment on function public.correct_completed_blend_case_delivery is
  'The only way to change actual_bbl on a delivery that is already complete. Requires a reason and creates a distinct audit event from the original completion, so the correction is visible in history rather than silently overwriting it.';

grant execute on function public.correct_completed_blend_case_delivery(uuid, numeric, text, text) to anon, authenticated;

-- Client can no longer upsert deliveries directly for meaningful lifecycle
-- fields; direct INSERT/UPDATE on this table is revoked below (migration
-- 022 tightens RLS holistically) -- kept narrow here to the delivery
-- lifecycle columns specifically so it's clear which change did it.
revoke insert, update on public.blend_case_deliveries from anon, authenticated;
grant select on public.blend_case_deliveries to anon, authenticated;

-- ---------------------------------------------------------------------
-- Numeric / lifecycle invariants
-- ---------------------------------------------------------------------

alter table public.blend_case_deliveries
  drop constraint if exists blend_case_deliveries_sequence_positive,
  add constraint blend_case_deliveries_sequence_positive check (sequence > 0),
  drop constraint if exists blend_case_deliveries_planned_bbl_positive,
  add constraint blend_case_deliveries_planned_bbl_positive check (planned_bbl > 0),
  drop constraint if exists blend_case_deliveries_actual_bbl_nonneg,
  add constraint blend_case_deliveries_actual_bbl_nonneg check (actual_bbl is null or actual_bbl >= 0),
  drop constraint if exists blend_case_deliveries_completed_requires_ts,
  add constraint blend_case_deliveries_completed_requires_ts
    check (status <> 'complete' or completed_at is not null),
  drop constraint if exists blend_case_deliveries_refused_requires_ts,
  add constraint blend_case_deliveries_refused_requires_ts
    check (status <> 'refused' or refused_at is not null);

alter table public.blend_cases
  drop constraint if exists blend_cases_planned_vol_nonneg,
  add constraint blend_cases_planned_vol_nonneg check (planned_est_vol_bbl is null or planned_est_vol_bbl >= 0),
  drop constraint if exists blend_cases_actual_tov_nonneg,
  add constraint blend_cases_actual_tov_nonneg check (actual_tov_bbl is null or actual_tov_bbl >= 0),
  drop constraint if exists blend_cases_closed_requires_completed_at,
  add constraint blend_cases_closed_requires_completed_at
    check (status <> 'closed' or completed_at is not null),
  drop constraint if exists blend_cases_closed_requires_final_stage,
  add constraint blend_cases_closed_requires_final_stage
    check (status <> 'closed' or stage = 9),
  drop constraint if exists blend_cases_abandoned_requires_metadata,
  add constraint blend_cases_abandoned_requires_metadata
    check (status <> 'abandoned' or (abandoned_at is not null and abandoned_by is not null and abandonment_reason is not null)),
  drop constraint if exists blend_cases_hold_requires_reason,
  add constraint blend_cases_hold_requires_reason
    check (status <> 'hold' or hold_reason is not null);

comment on constraint blend_cases_closed_requires_completed_at on public.blend_cases is
  'A closed case must record when it was completed.';
comment on constraint blend_cases_abandoned_requires_metadata on public.blend_cases is
  'An abandoned case must record who abandoned it, when, and why -- enforced at the column level in addition to the abandon_blend_case() RPC validation.';
