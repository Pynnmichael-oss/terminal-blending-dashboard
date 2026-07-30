-- 00000000000018_rpc_abandon_blend_case.sql
--
-- Hardening pass, part 6 (primary objective): replace permanent deletion
-- with an abandonment workflow that preserves every record. delete_blend_case
-- (migration 012) permanently removed a case and cascaded through
-- deliveries/events/results -- that is no longer part of the normal
-- workflow. abandon_blend_case() sets status='abandoned' and never
-- deletes anything.

create or replace function public.abandon_blend_case(
  p_blend_case_id    uuid,
  p_actor            text,
  p_reason           text,
  p_expected_version bigint
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
  v_prev_status text;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a reason is required to abandon a blend case';
  end if;
  if p_actor is null or length(trim(p_actor)) = 0 then
    raise exception 'an actor is required to abandon a blend case';
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
    raise exception 'case % is already % and cannot be abandoned', v_case.case_number, v_case.status;
  end if;

  v_prev_status := v_case.status;

  update public.blend_cases set
    status               = 'abandoned',
    abandoned_at         = now(),
    abandoned_by         = p_actor,
    abandonment_reason   = p_reason,
    checkout_device      = null, checkout_by = null, checkout_at = null,
    checkout_token       = null, checkout_expires_at = null,
    record_version       = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  if v_case.plan_id is not null then
    update public.blend_plans set status = 'proposed' where id = v_case.plan_id and status = 'promoted';
  end if;

  insert into public.blend_case_events (
    blend_case_id, event_type, previous_status, new_status, message, created_by, event_data
  ) values (
    p_blend_case_id, 'status_change', v_prev_status, 'abandoned',
    format('Case abandoned: %s', p_reason), p_actor,
    jsonb_build_object('reason', p_reason, 'plan_reverted', v_case.plan_id is not null)
  );

  return v_case;
end;
$$;

comment on function public.abandon_blend_case is
  'Abandons a case (requires a non-empty reason) instead of deleting it: sets status=abandoned, records who/why/when, clears any checkout lease, reverts a promoted source plan to proposed, and writes an audit event. Never deletes blend_cases, blend_case_deliveries, blend_case_events, or blend_case_results. Superseded delete_blend_case, whose execute grant is revoked below.';

grant execute on function public.abandon_blend_case(uuid, text, text, bigint) to anon, authenticated;

-- delete_blend_case (migration 012) permanently deleted a case and
-- cascaded through every child table. That is no longer part of the
-- normal workflow -- revoke execution so the browser client can't call
-- it. The function definition is kept (not dropped) only so a future,
-- deliberately-gated admin tool could reuse it; it is not exposed
-- anywhere in the normal UI.
revoke execute on function public.delete_blend_case(uuid, text) from anon, authenticated;
