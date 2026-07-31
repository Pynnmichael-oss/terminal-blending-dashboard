-- 00000000000022_blend_case_decision_and_actual_volume_rpcs.sql
--
-- Hardening pass, part 10 (follow-up to 021): decision and actual_tov_bbl
-- are dedicated columns, not case_data keys, so update_blend_case_data()
-- doesn't cover them -- and migration 021 revoked direct client UPDATE on
-- both. These two narrow, version-checked setters replace that access.

create or replace function public.set_blend_case_decision(
  p_blend_case_id    uuid,
  p_expected_version bigint,
  p_decision         text,
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
  if p_decision is not null and p_decision not in ('exact-load', 'round-up', 'truncate') then
    raise exception 'invalid decision %', p_decision;
  end if;

  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.record_version <> p_expected_version then
    raise exception 'stale record: expected version % but case is at version %', p_expected_version, v_case.record_version
      using errcode = 'serialization_failure';
  end if;
  if v_case.status in ('closed', 'abandoned') then
    raise exception 'case % is % and its load-plan decision can no longer change', v_case.case_number, v_case.status;
  end if;

  update public.blend_cases set
    decision       = p_decision,
    record_version = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  return v_case;
end;
$$;

comment on function public.set_blend_case_decision is
  'Sets the load-plan decision (exact-load / round-up / truncate). Version-checked; does not itself write an audit event -- callers that want one should also call add_blend_case_note.';

grant execute on function public.set_blend_case_decision(uuid, bigint, text, text) to anon, authenticated;

create or replace function public.record_blend_case_actual_volume(
  p_blend_case_id    uuid,
  p_expected_version bigint,
  p_actual_tov_bbl   numeric,
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
  if p_actual_tov_bbl is not null and p_actual_tov_bbl < 0 then
    raise exception 'actual volume must be nonnegative';
  end if;

  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.record_version <> p_expected_version then
    raise exception 'stale record: expected version % but case is at version %', p_expected_version, v_case.record_version
      using errcode = 'serialization_failure';
  end if;
  if v_case.status in ('closed', 'abandoned') then
    raise exception 'case % is % and its actual volume can no longer change', v_case.case_number, v_case.status;
  end if;

  update public.blend_cases set
    actual_tov_bbl = p_actual_tov_bbl,
    record_version = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  return v_case;
end;
$$;

comment on function public.record_blend_case_actual_volume is
  'Sets actual_tov_bbl (open-gauge verified volume). Never touches planned_est_vol_bbl. Version-checked.';

grant execute on function public.record_blend_case_actual_volume(uuid, bigint, numeric, text) to anon, authenticated;
