-- 00000000000007_rpc_functions.sql
--
-- Two RPCs back the "Plan Blend" flow and status/stage transitions with a
-- single atomic database round trip each (Postgres executes a function
-- body as one implicit transaction, so any raised exception rolls back
-- every insert/update it made -- no partially saved case can result).

-- create_blend_case is the backing function for "Plan Blend". It:
--   1. validates required fields and that the target tank has no other
--      open case,
--   2. optionally consumes a blend_plans row (marks it 'promoted', never
--      deletes it),
--   3. inserts the blend_cases row,
--   4. inserts any initial blend_case_deliveries rows (planned truck loads),
--   5. writes a 'created' blend_case_events row,
-- all in one transaction.
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

  if p_plan_id is not null then
    select * into v_plan from public.blend_plans where id = p_plan_id for update;
    if not found then
      raise exception 'blend plan % not found', p_plan_id;
    end if;
    if v_plan.status <> 'proposed' then
      raise exception 'blend plan % is not proposed (currently %)', p_plan_id, v_plan.status;
    end if;
  end if;

  if exists (
    select 1 from public.blend_cases where tank = p_tank and status <> 'closed'
  ) then
    raise exception 'an active case already exists for tank %', p_tank;
  end if;

  insert into public.blend_cases (
    case_number, plan_id, source_plan_snapshot, grade, tank, tank_no, row_label,
    operator, pq, planned_est_vol_bbl, planned_est_rvp, case_data, created_by
  ) values (
    p_case_number, p_plan_id,
    case when v_plan.id is not null then to_jsonb(v_plan) else null end,
    p_grade, p_tank, coalesce(p_tank_no, ''), p_row_label,
    p_operator, p_pq, p_planned_est_vol_bbl, p_planned_est_rvp,
    jsonb_build_object('window', p_window), coalesce(p_created_by, p_operator)
  )
  returning * into v_case;

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
  'Atomically creates a blend_cases row (optionally consuming a proposed blend_plans row and seeding initial deliveries) and logs a creation event. Backs the "Plan Blend" action. Raises on invalid input so no partial case can be saved.';

-- change_blend_case_status atomically updates status/stage and writes the
-- corresponding history event, so every meaningful transition is captured.
create or replace function public.change_blend_case_status(
  p_blend_case_id uuid,
  p_new_status    text default null,
  p_new_stage     smallint default null,
  p_hold_reason   text default null,
  p_message       text default null,
  p_actor         text default 'system'
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case      public.blend_cases;
  v_prev_status text;
  v_prev_stage  smallint;
begin
  if p_new_status is not null and p_new_status not in ('open', 'hold', 'closed') then
    raise exception 'invalid status %', p_new_status;
  end if;
  if p_new_stage is not null and (p_new_stage < 0 or p_new_stage > 9) then
    raise exception 'invalid stage %', p_new_stage;
  end if;

  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;

  v_prev_status := v_case.status;
  v_prev_stage  := v_case.stage;

  update public.blend_cases set
    status       = coalesce(p_new_status, status),
    stage        = coalesce(p_new_stage, stage),
    hold_reason  = case when p_new_status = 'hold' then p_hold_reason else hold_reason end,
    hold_at      = case when p_new_status = 'hold' then now() else hold_at end,
    started_at   = case when started_at is null and coalesce(p_new_stage, stage) >= 1 then now() else started_at end,
    completed_at = case when p_new_status = 'closed' then now() else completed_at end
  where id = p_blend_case_id
  returning * into v_case;

  if v_prev_status is distinct from v_case.status or v_prev_stage is distinct from v_case.stage then
    insert into public.blend_case_events (
      blend_case_id, event_type, previous_status, new_status, previous_stage, new_stage, message, created_by
    ) values (
      p_blend_case_id,
      case when p_new_status = 'hold' then 'hold'
           when v_prev_status is distinct from v_case.status then 'status_change'
           else 'stage_change' end,
      v_prev_status, v_case.status, v_prev_stage, v_case.stage,
      coalesce(p_message, format('%s/%s -> %s/%s', v_prev_status, v_prev_stage, v_case.status, v_case.stage)),
      p_actor
    );
  end if;

  return v_case;
end;
$$;

comment on function public.change_blend_case_status is
  'Atomically updates a blend case status/stage and writes the corresponding blend_case_events row so history is never dropped.';
