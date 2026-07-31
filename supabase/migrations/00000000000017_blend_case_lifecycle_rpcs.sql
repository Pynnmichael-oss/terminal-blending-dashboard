-- 00000000000017_blend_case_lifecycle_rpcs.sql
--
-- Hardening pass, part 5: replace arbitrary status/stage jumps
-- (change_blend_case_status accepted any status + any stage) with
-- business-specific RPCs that validate the actual Blend Case Manager
-- workflow. Each function:
--   1. locks the case row (FOR UPDATE),
--   2. validates the current state and the expected record_version,
--   3. applies the change,
--   4. increments record_version,
--   5. inserts the blend_case_events row,
--   6. returns the updated row,
-- all in one transaction (a Postgres function body is implicit ACID).
--
-- The 10-step STAGES array in blend-case-manager.html only ever assigns
-- stage values 0,1,3,5,6,7,8,9 (stages 2 and 4 are placeholders in the
-- stepper UI and are never set by any action) -- ftw_allowed_next_stage()
-- below encodes exactly that adjacency so "no arbitrary stage skipping"
-- can be enforced without inventing a different workflow than the one
-- the app already implements.

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
    else null
  end;
$$;

comment on function public.ftw_allowed_next_stage is
  'The single legal next stage from a given stage in the Fort Worth blend case workflow, or null if the stage is terminal (9) or unrecognized. Mirrors the STAGES stepper in blend-case-manager.html, which never assigns stage 2 or 4.';

-- advance_blend_case_stage: move a case exactly one legal step forward.
create or replace function public.advance_blend_case_stage(
  p_blend_case_id   uuid,
  p_expected_version bigint,
  p_actor           text,
  p_message         text default null
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
  v_next smallint;
  v_prev smallint;
begin
  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.record_version <> p_expected_version then
    raise exception 'stale record: expected version % but case is at version %', p_expected_version, v_case.record_version
      using errcode = 'serialization_failure';
  end if;
  if v_case.status not in ('open', 'hold') then
    raise exception 'case % is % and cannot advance', v_case.case_number, v_case.status;
  end if;

  v_prev := v_case.stage;
  v_next := public.ftw_allowed_next_stage(v_case.stage);
  if v_next is null then
    raise exception 'case % is already at the final stage', v_case.case_number;
  end if;

  update public.blend_cases set
    stage          = v_next,
    record_version = record_version + 1,
    started_at     = coalesce(started_at, now())
  where id = p_blend_case_id
  returning * into v_case;

  insert into public.blend_case_events (
    blend_case_id, event_type, previous_stage, new_stage, message, created_by
  ) values (
    p_blend_case_id, 'stage_change', v_prev, v_case.stage,
    coalesce(p_message, format('Advanced to stage %s', v_case.stage)),
    p_actor
  );

  return v_case;
end;
$$;

comment on function public.advance_blend_case_stage is
  'Moves a blend case exactly one legal step forward per ftw_allowed_next_stage(). Rejects stage skipping, regression, and action on a closed/abandoned case. Requires the caller''s last-known record_version.';

grant execute on function public.advance_blend_case_stage(uuid, bigint, text, text) to anon, authenticated;

-- place_blend_case_on_hold: requires a non-empty reason.
create or replace function public.place_blend_case_on_hold(
  p_blend_case_id    uuid,
  p_expected_version bigint,
  p_reason           text,
  p_actor            text
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a reason is required to place a case on hold';
  end if;

  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.record_version <> p_expected_version then
    raise exception 'stale record: expected version % but case is at version %', p_expected_version, v_case.record_version
      using errcode = 'serialization_failure';
  end if;
  if v_case.status <> 'open' then
    raise exception 'case % must be open to place on hold (currently %)', v_case.case_number, v_case.status;
  end if;

  update public.blend_cases set
    status         = 'hold',
    hold_reason    = p_reason,
    hold_at        = now(),
    record_version = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  insert into public.blend_case_events (
    blend_case_id, event_type, previous_status, new_status, message, created_by
  ) values (
    p_blend_case_id, 'hold', 'open', 'hold', format('Placed on hold: %s', p_reason), p_actor
  );

  return v_case;
end;
$$;

comment on function public.place_blend_case_on_hold is
  'Places an open case on hold. Requires a non-empty reason and the caller''s last-known record_version.';

grant execute on function public.place_blend_case_on_hold(uuid, bigint, text, text) to anon, authenticated;

-- release_blend_case_hold: always creates an audit event; hold metadata
-- is intentionally cleared (the reason is preserved permanently in the
-- blend_case_events row rather than left dangling on the case).
create or replace function public.release_blend_case_hold(
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
  v_prior_reason text;
begin
  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.record_version <> p_expected_version then
    raise exception 'stale record: expected version % but case is at version %', p_expected_version, v_case.record_version
      using errcode = 'serialization_failure';
  end if;
  if v_case.status <> 'hold' then
    raise exception 'case % is not on hold (currently %)', v_case.case_number, v_case.status;
  end if;

  v_prior_reason := v_case.hold_reason;

  update public.blend_cases set
    status         = 'open',
    hold_reason    = null,
    hold_at        = null,
    record_version = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  insert into public.blend_case_events (
    blend_case_id, event_type, previous_status, new_status, message, created_by
  ) values (
    p_blend_case_id, 'status_change', 'hold', 'open',
    coalesce(p_message, format('Hold released (was: %s)', coalesce(v_prior_reason, 'no reason recorded'))),
    p_actor
  );

  return v_case;
end;
$$;

comment on function public.release_blend_case_hold is
  'Releases a case from hold back to open. The hold reason is preserved in the audit event, not left on the case row. Requires the caller''s last-known record_version.';

grant execute on function public.release_blend_case_hold(uuid, bigint, text, text) to anon, authenticated;

-- close_blend_case: requires stage 9 and a results row with completion
-- data recorded (the DB-level proxy for "packet complete" -- the full
-- document/packet checklist lives in blend_cases.case_data and
-- blend_case_results, populated by the client before calling this).
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
  if v_case.stage <> 9 then
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
    p_blend_case_id, 'status_change', 'open', 'closed', 9, 9,
    coalesce(p_message, 'Case signed, closed, and blend packet archived'),
    p_actor
  );

  return v_case;
end;
$$;

comment on function public.close_blend_case is
  'Closes a case at its final stage. Requires release authorization and close-gauge results to already be recorded, and sets completed_at. Reopening a closed case is not supported. Requires the caller''s last-known record_version.';

grant execute on function public.close_blend_case(uuid, bigint, text, text) to anon, authenticated;

-- The old generic change_blend_case_status() (migration 007) accepted
-- arbitrary status/stage combinations with no workflow validation. It is
-- superseded by the four functions above; revoke execution so the
-- browser client can no longer call it, but keep the function defined
-- (not dropped) since blend_case_events rows already reference the
-- transitions it wrote historically and dropping it is not necessary for
-- that history to remain readable.
revoke execute on function public.change_blend_case_status(uuid, text, smallint, text, text, text) from anon, authenticated;
