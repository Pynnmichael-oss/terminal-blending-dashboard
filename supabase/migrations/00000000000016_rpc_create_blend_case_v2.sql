-- 00000000000016_rpc_create_blend_case_v2.sql
--
-- Hardening pass, part 4: create_blend_case no longer accepts a
-- caller-supplied case number -- it always calls next_blend_case_number()
-- itself, so the browser is never the authoritative source. It still
-- keeps a friendly pre-check for "does this tank already have an active
-- case" / "is this plan already promoted", but the actual guarantee is
-- the unique indexes from migration 014: if two concurrent calls both
-- pass the pre-check, one of them hits a unique_violation and gets a
-- clear error instead of silently creating a duplicate.

-- The new signature drops p_case_number, which changes the function's
-- identity (Postgres overloads on parameter list) -- drop the old
-- overload explicitly so we don't leave two create_blend_case functions
-- behind.
drop function if exists public.create_blend_case(
  text, text, text, text, uuid, text, text, text, numeric, numeric, jsonb, text, jsonb
);

create or replace function public.create_blend_case(
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
      public.next_blend_case_number(), p_plan_id,
      case when v_plan.id is not null then to_jsonb(v_plan) else null end,
      p_grade, p_tank, coalesce(p_tank_no, ''), p_row_label,
      p_operator, p_pq, p_planned_est_vol_bbl, p_planned_est_rvp,
      jsonb_build_object('window', p_window), coalesce(p_created_by, p_operator)
    )
    returning * into v_case;
  exception
    when unique_violation then
      -- Either the tank-active-case index or the plan_id-promoted index
      -- fired -- this is the real concurrency guarantee kicking in after
      -- the friendly pre-checks above raced and both passed.
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
  'Atomically creates a blend_cases row with a database-generated case_number (optionally consuming a proposed blend_plans row and seeding initial deliveries) and logs a creation event. Backs the "Plan Blend" action. The unique indexes on (tank_key where active) and (plan_id where not null) are the real concurrency guarantee; this function raises a friendly error either from its own pre-check or by catching the resulting unique_violation.';

grant execute on function public.create_blend_case(
  text, text, text, uuid, text, text, text, numeric, numeric, jsonb, text, jsonb
) to anon, authenticated;
