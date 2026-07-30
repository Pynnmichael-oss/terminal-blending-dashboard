-- 02_concurrent_plan_promotion.sql
--
-- Validates that a blend_plans row already promoted (status='promoted')
-- cannot be promoted a second time via create_blend_case -- both the
-- function's own status check and the blend_cases_plan_id_unique index
-- guard this. See README.md's "A note on concurrent" for why this is
-- exercised sequentially.
begin;

do $$
declare
  v_tank1 text := 'TEST-TANK-' || substr(gen_random_uuid()::text, 1, 8);
  v_tank2 text := 'TEST-TANK-' || substr(gen_random_uuid()::text, 1, 8);
  v_plan_id uuid;
  v_case1 public.blend_cases;
  v_rejected boolean := false;
begin
  insert into public.blend_plans (
    plan_code, tank, tank_no, window_start, window_end, status
  ) values (
    'TEST-PLAN-' || substr(gen_random_uuid()::text, 1, 8),
    v_tank1, v_tank1, '2026-01-01 00:00', '2026-01-01 12:00', 'proposed'
  ) returning id into v_plan_id;

  v_case1 := public.create_blend_case(
    p_operator := 'Test Operator', p_pq := 'Test PQ',
    p_tank := v_tank1, p_plan_id := v_plan_id, p_tank_no := v_tank1
  );
  if v_case1.plan_id <> v_plan_id then
    raise exception 'FAIL: created case is not linked to the source plan';
  end if;
  if (select status from public.blend_plans where id = v_plan_id) <> 'promoted' then
    raise exception 'FAIL: source plan was not marked promoted after create_blend_case';
  end if;

  -- Promote the SAME plan again, from a different tank, to isolate the
  -- plan-id check from the tank-conflict check tested in 01.
  begin
    perform public.create_blend_case(
      p_operator := 'Test Operator 2', p_pq := 'Test PQ 2',
      p_tank := v_tank2, p_plan_id := v_plan_id, p_tank_no := v_tank2
    );
  exception when others then
    v_rejected := true;
    if sqlerrm not ilike '%not proposed%' then
      raise exception 'FAIL: expected a "not proposed" error re-promoting the same plan, got: %', sqlerrm;
    end if;
  end;

  if not v_rejected then
    raise exception 'FAIL: the same blend_plans row was promoted into a second blend_cases row';
  end if;

  if (select count(*) from public.blend_cases where plan_id = v_plan_id) <> 1 then
    raise exception 'FAIL: expected exactly one blend_cases row linked to the plan, found %', (select count(*) from public.blend_cases where plan_id = v_plan_id);
  end if;

  raise notice 'PASS: 02_concurrent_plan_promotion -- re-promoting an already-promoted plan was rejected';
end $$;

rollback;
