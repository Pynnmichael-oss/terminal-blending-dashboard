-- 00000000000012_rpc_delete_blend_case.sql
--
-- delete_blend_case permanently removes a blend case and everything under
-- it (deliveries, events, results -- all cascade via FK). This is a real,
-- irreversible delete, used for ending/abandoning a case outright rather
-- than completing the formal Certify & Release / Close-Packet workflow.
--
-- Runs as SECURITY DEFINER (table owner) specifically so the cascade
-- delete of blend_case_events succeeds despite that table intentionally
-- having no DELETE policy for anon/authenticated (append-only by design
-- for cases that finish normally). Deleting the whole case is a distinct,
-- explicit action gated behind this one function, not a general erosion
-- of the append-only guarantee.
--
-- If the case originated from a promoted blend_plans row, that plan is
-- reverted to 'proposed' so it can be promoted again -- deleting the case
-- undoes the promotion, it doesn't strand the source plan forever.
create or replace function public.delete_blend_case(
  p_blend_case_id uuid,
  p_actor text default 'system'
)
returns table(case_number text, plan_reverted boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case_number text;
  v_plan_id uuid;
begin
  select c.case_number, c.plan_id into v_case_number, v_plan_id
  from public.blend_cases c where c.id = p_blend_case_id for update;

  if v_case_number is null then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;

  delete from public.blend_cases where id = p_blend_case_id;

  if v_plan_id is not null then
    update public.blend_plans set status = 'proposed' where id = v_plan_id and status = 'promoted';
  end if;

  return query select v_case_number, v_plan_id is not null;
end;
$$;

comment on function public.delete_blend_case is
  'Permanently deletes a blend case and all its deliveries/events/results (cascade). Reverts the source plan to proposed if one was linked. Irreversible -- ending/abandoning a case, distinct from the formal close workflow.';

grant execute on function public.delete_blend_case to anon, authenticated;
