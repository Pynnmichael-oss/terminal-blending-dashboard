-- 00000000000025_ftw_case_number_and_stage_10.sql
--
-- Merging the V8.9.8 UI (Blend Case Manager 0731.html) on top of the
-- hardening pass surfaced two real workflow/schema changes that shipped
-- in that UI ahead of this backend, not just cosmetic differences:
--
-- 1. Case numbers are operator-typed again, format
--    FTW<2-digit tank number><MMDDYY>[optional disambiguation letter],
--    e.g. FTW55073026, validated client-side by
--    /^[A-Z]{3}\d{8}[A-Z]?$/ and checked for uniqueness only against
--    in-memory state.cases (a client-only race, same class of bug the
--    hardening pass fixed for tank/plan conflicts). We accept the
--    client-proposed number instead of re-introducing DB generation:
--    the case_number column already has a `not null unique` constraint
--    (migration 003) that is the real race-safety net here, same as it
--    already is for next_blend_case_number()-generated values.
-- 2. A new stage 10 ("Close Blend") was added after the old terminal
--    stage 9 ("Final Blend Summary" is now 9; "Close Blend" is the new
--    terminal stage 10). Every place that hardcoded 9 as "the terminal
--    stage" needs to move to 10.

-- ---------------------------------------------------------------------
-- Part 1: stage 0-10 (was 0-9), closed requires stage 10 (was stage 9)
-- ---------------------------------------------------------------------

alter table public.blend_cases
  drop constraint if exists blend_cases_stage_check,
  add constraint blend_cases_stage_check check (stage between 0 and 10),
  drop constraint if exists blend_cases_closed_requires_final_stage,
  add constraint blend_cases_closed_requires_final_stage
    check (status <> 'closed' or stage = 10);

comment on constraint blend_cases_stage_check on public.blend_cases is
  'App lifecycle position, 0-10 (see STAGES in blend-case-manager.html V8.9.8+: stage 9 is now "Final Blend Summary", stage 10 is the new terminal "Close Blend" step). Widened from 0-9 by this migration.';
comment on constraint blend_cases_closed_requires_final_stage on public.blend_cases is
  'A closed case must be at the terminal stage. Moved from stage=9 to stage=10 when "Close Blend" became its own stage after "Final Blend Summary" (V8.9.8 UI).';

-- ---------------------------------------------------------------------
-- Part 2: ftw_allowed_next_stage gains 9->10; 8->9 is unchanged (it still
-- means Certify & Release -> Final Blend Summary, just no longer terminal)
-- ---------------------------------------------------------------------

create or replace function public.ftw_allowed_next_stage(p_current smallint)
returns smallint
language sql
immutable
as $$
  select case p_current
    when 0 then 1::smallint
    when 1 then 3::smallint
    when 3 then 5::smallint
    when 5 then 6::smallint
    when 6 then 7::smallint
    when 7 then 8::smallint
    when 8 then 9::smallint
    when 9 then 10::smallint
    else null
  end;
$$;

comment on function public.ftw_allowed_next_stage is
  'The single legal next stage from a given stage in the Fort Worth blend case workflow, or null if the stage is terminal (10) or unrecognized. Mirrors the STAGES stepper in blend-case-manager.html, which never assigns stage 2 or 4. Stage 10 ("Close Blend") became terminal in the V8.9.8 UI merge; 9 ("Final Blend Summary") is no longer terminal.';

-- ---------------------------------------------------------------------
-- Part 3: close_blend_case now requires stage 10, not 9
-- ---------------------------------------------------------------------

create or replace function public.close_blend_case(
  p_blend_case_id    uuid,
  p_expected_version bigint,
  p_actor            text,
  p_message          text default null
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
  v_has_release boolean;
  v_results_ok boolean;
begin
  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.record_version <> p_expected_version then
    raise exception 'stale record: expected version % but case is at version %', p_expected_version, v_case.record_version
      using errcode = 'serialization_failure';
  end if;
  if v_case.status <> 'open' then
    raise exception 'case % must be open to close (currently %)', v_case.case_number, v_case.status;
  end if;
  if v_case.stage <> 10 then
    raise exception 'case % must be at the final stage to close (currently stage %)', v_case.case_number, v_case.stage;
  end if;

  v_has_release := (v_case.case_data #>> '{certification,release}') is not null;
  select exists(
    select 1 from public.blend_case_results r
    where r.blend_case_id = p_blend_case_id and r.close_gauge is not null
  ) into v_results_ok;

  if not v_has_release then
    raise exception 'case % cannot close: release authorization has not been recorded', v_case.case_number;
  end if;
  if not v_results_ok then
    raise exception 'case % cannot close: close-gauge results have not been recorded', v_case.case_number;
  end if;

  update public.blend_cases set
    status         = 'closed',
    completed_at   = now(),
    checkout_device = null, checkout_by = null, checkout_at = null,
    checkout_token = null, checkout_expires_at = null,
    record_version = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  insert into public.blend_case_events (
    blend_case_id, event_type, previous_status, new_status, previous_stage, new_stage, message, created_by
  ) values (
    p_blend_case_id, 'status_change', 'open', 'closed', 10, 10,
    coalesce(p_message, 'Case signed, closed, and blend packet archived'),
    p_actor
  );

  return v_case;
end;
$$;

comment on function public.close_blend_case is
  'Closes a case at its final stage (10, "Close Blend"). Requires release authorization and close-gauge results to already be recorded, and sets completed_at. Reopening a closed case is not supported. Requires the caller''s last-known record_version.';

-- ---------------------------------------------------------------------
-- Part 4: create_blend_case accepts a client-supplied FTW-format case
-- number again. Server-side regex validation is defense in depth -- the
-- client already validates the same pattern, but this function must not
-- trust that. The case_number unique constraint (migration 003) remains
-- the real concurrency guarantee; we catch its unique_violation here and
-- raise the same friendly-error pattern already used for the tank/plan
-- pre-checks in this function.
--
-- next_blend_case_number() (migration 015) is intentionally left defined
-- but is no longer called automatically by this function -- kept in case
-- a future flow wants a generated-fallback option (e.g. an operator who
-- has no tank/date info yet). Do not drop it.
-- ---------------------------------------------------------------------

drop function if exists public.create_blend_case(
  text, text, text, uuid, text, text, text, numeric, numeric, jsonb, text, jsonb
);

create or replace function public.create_blend_case(
  p_case_number          text,
  p_operator             text,
  p_pq                   text,
  p_tank                 text,
  p_plan_id              uuid default null,
  p_grade                text default 'REGULAR',
  p_tank_no              text default '',
  p_row_label            text default null,
  p_planned_est_vol_bbl   numeric default null,
  p_planned_est_rvp       numeric default null,
  p_window               jsonb default '{}'::jsonb,
  p_created_by            text default null,
  p_deliveries           jsonb default '[]'::jsonb
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case     public.blend_cases;
  v_plan     public.blend_plans;
  v_delivery jsonb;
  v_tank_key text;
  v_case_number text;
begin
  if p_operator is null or length(trim(p_operator)) = 0 then
    raise exception 'operator is required to plan a blend';
  end if;
  if p_pq is null or length(trim(p_pq)) = 0 then
    raise exception 'pq (quality reviewer) is required to plan a blend';
  end if;
  if p_tank is null or length(trim(p_tank)) = 0 then
    raise exception 'tank is required to plan a blend';
  end if;

  v_case_number := upper(trim(coalesce(p_case_number, '')));
  if v_case_number !~ '^FTW\d{8}[A-Z]?$' then
    raise exception 'case number "%" is not a valid Fort Worth blend number (expected FTW + two-digit tank number + MMDDYY + optional disambiguation letter, e.g. FTW55073026)', v_case_number;
  end if;

  v_tank_key := coalesce(nullif(trim(p_tank_no), ''), upper(trim(p_tank)));

  if p_plan_id is not null then
    -- Lock the source planner row so a concurrent promotion attempt of
    -- the SAME plan blocks here rather than racing past this check.
    select * into v_plan from public.blend_plans where id = p_plan_id for update;
    if not found then
      raise exception 'blend plan % not found', p_plan_id;
    end if;
    if v_plan.status <> 'proposed' then
      raise exception 'blend plan % is not proposed (currently %)', p_plan_id, v_plan.status;
    end if;
  end if;

  -- Friendly pre-check. The unique index (blend_cases_one_active_per_tank)
  -- is the real authority -- this just gives a nicer error in the common
  -- non-concurrent case instead of a raw unique_violation.
  if exists (
    select 1 from public.blend_cases where tank_key = v_tank_key and status in ('open', 'hold')
  ) then
    raise exception 'an active case already exists for tank %', p_tank
      using errcode = 'unique_violation';
  end if;

  begin
    insert into public.blend_cases (
      case_number, plan_id, source_plan_snapshot, grade, tank, tank_no, row_label,
      operator, pq, planned_est_vol_bbl, planned_est_rvp, case_data, created_by
    ) values (
      v_case_number, p_plan_id,
      case when v_plan.id is not null then to_jsonb(v_plan) else null end,
      p_grade, p_tank, coalesce(p_tank_no, ''), p_row_label,
      p_operator, p_pq, p_planned_est_vol_bbl, p_planned_est_rvp,
      jsonb_build_object('window', p_window), coalesce(p_created_by, p_operator)
    )
    returning * into v_case;
  exception
    when unique_violation then
      -- Either the case_number unique constraint (client-picked number
      -- already exists), the tank-active-case index, or the
      -- plan_id-promoted index fired -- this is the real concurrency
      -- guarantee kicking in after the friendly pre-checks above raced
      -- and both passed (or the client picked a colliding number).
      if exists (select 1 from public.blend_cases where case_number = v_case_number) then
        raise exception 'blend number % already exists', v_case_number
          using errcode = 'unique_violation';
      end if;
      raise exception 'could not create the case: another request just created an active case for this tank or promoted this plan. Reload and try again.'
        using errcode = 'unique_violation';
  end;

  if p_plan_id is not null then
    update public.blend_plans set status = 'promoted' where id = p_plan_id;
  end if;

  for v_delivery in select * from jsonb_array_elements(coalesce(p_deliveries, '[]'::jsonb))
  loop
    insert into public.blend_case_deliveries (
      blend_case_id, sequence, planned_bbl, bol, driver, operator
    ) values (
      v_case.id,
      (v_delivery->>'sequence')::int,
      (v_delivery->>'planned_bbl')::numeric,
      v_delivery->>'bol',
      v_delivery->>'driver',
      coalesce(v_delivery->>'operator', p_operator)
    );
  end loop;

  insert into public.blend_case_events (
    blend_case_id, event_type, new_status, new_stage, message, created_by
  ) values (
    v_case.id, 'created', v_case.status, v_case.stage,
    case when p_plan_id is not null
      then format('Case %s created from planner row %s', v_case.case_number, p_plan_id)
      else format('Case %s created', v_case.case_number)
    end,
    coalesce(p_created_by, p_operator)
  );

  return v_case;
end;
$$;

comment on function public.create_blend_case is
  'Atomically creates a blend_cases row with a client-supplied, server-validated FTW-format case_number (optionally consuming a proposed blend_plans row and seeding initial deliveries) and logs a creation event. Backs the "Plan Blend" action. Case number format is enforced server-side (^FTW\d{8}[A-Z]?$) as defense in depth on top of the client-side check in blend-case-manager.html. The unique indexes on (case_number), (tank_key where active), and (plan_id where not null) are the real concurrency guarantee; this function raises a friendly error either from its own pre-check or by catching the resulting unique_violation.';

grant execute on function public.create_blend_case(
  text, text, text, text, uuid, text, text, text, numeric, numeric, jsonb, text, jsonb
) to anon, authenticated;

comment on function public.next_blend_case_number() is
  'Atomically allocates a next case number (BL-<year>-<6-digit seq>). No longer called automatically by create_blend_case() as of migration 025 -- the V8.9.8 UI reintroduced client-proposed FTW-format case numbers (see that migration''s header comment). Kept defined, not dropped, in case a future flow wants a generated-fallback option.';

-- ---------------------------------------------------------------------
-- Part 5: update_blend_case_data allow-list gains 'circulation' and
-- 'marginReview' -- new case_data fields written by the V8.9.8 UI's
-- circulation tracking and continueFromFinalSummary().
-- ---------------------------------------------------------------------

create or replace function public.update_blend_case_data(
  p_blend_case_id    uuid,
  p_expected_version bigint,
  p_patch            jsonb,
  p_actor            text,
  p_note             text default null
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
  -- Must mirror exactly what buildCaseDataPayload() in
  -- blend-case-manager.html can produce (every makeCase() field not in
  -- CASE_DATA_EXCLUDE). 'circulation' and 'marginReview' added by
  -- migration 025 for the V8.9.8 UI merge.
  v_allowed_keys text[] := array[
    'documents','preBlendResults','iterations','certification','isolation',
    'timestamps','valveAlignment','window','truckPlan','order','ordered',
    'orderedVolume','globalBatchId','plannerId','receipt','complianceSupplier',
    'complianceContributionGal','summaryGenerated','actualSamples',
    'circulation','marginReview'
  ];
  v_key text;
  v_merged jsonb;
begin
  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.record_version <> p_expected_version then
    raise exception 'stale record: expected version % but case is at version %', p_expected_version, v_case.record_version
      using errcode = 'serialization_failure';
  end if;
  if v_case.status in ('closed', 'abandoned') then
    raise exception 'case % is % and its case_data can no longer be edited', v_case.case_number, v_case.status;
  end if;

  for v_key in select jsonb_object_keys(coalesce(p_patch, '{}'::jsonb))
  loop
    if not (v_key = any(v_allowed_keys)) then
      raise exception 'case_data key "%" is not in the allowed list for update_blend_case_data', v_key;
    end if;
  end loop;

  v_merged := coalesce(v_case.case_data, '{}'::jsonb) || coalesce(p_patch, '{}'::jsonb);

  update public.blend_cases set
    case_data      = v_merged,
    record_version = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  insert into public.blend_case_events (blend_case_id, event_type, message, created_by, event_data)
  values (
    p_blend_case_id, 'note',
    coalesce(p_note, format('Case data updated: %s', array_to_string(array(select jsonb_object_keys(p_patch)), ', '))),
    p_actor, jsonb_build_object('updated_keys', array(select jsonb_object_keys(p_patch)))
  );

  return v_case;
end;
$$;

comment on function public.update_blend_case_data is
  'Merges an explicitly-allow-listed set of case_data keys server-side (never a blind whole-object replace), under optimistic concurrency, and logs which keys changed. For not-yet-broken-out prototype fields only -- planned/actual columns and results have their own dedicated functions. circulation/marginReview added by migration 025.';

grant execute on function public.update_blend_case_data(uuid, bigint, jsonb, text, text) to anon, authenticated;
