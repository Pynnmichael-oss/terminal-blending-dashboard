-- 01_concurrent_tank_conflict.sql
--
-- Validates blend_cases_one_active_per_tank: a second create_blend_case
-- for a tank that already has an active (open/hold) case is rejected.
-- See README.md's "A note on concurrent" for why this is exercised
-- sequentially rather than via two literally-simultaneous connections.
begin;

do $$
declare
  v_tank   text := 'TEST-TANK-' || substr(gen_random_uuid()::text, 1, 8);
  v_case1  public.blend_cases;
  v_rejected boolean := false;
  v_sqlstate text;
begin
  v_case1 := public.create_blend_case(
    p_operator := 'Test Operator', p_pq := 'Test PQ',
    p_tank := v_tank, p_tank_no := v_tank
  );
  if v_case1.id is null then
    raise exception 'FAIL: first create_blend_case for a fresh tank did not return a row';
  end if;
  if v_case1.status <> 'open' then
    raise exception 'FAIL: expected the first case to be open, got %', v_case1.status;
  end if;

  begin
    perform public.create_blend_case(
      p_operator := 'Test Operator 2', p_pq := 'Test PQ 2',
      p_tank := v_tank, p_tank_no := v_tank
    );
  exception when others then
    v_rejected := true;
    v_sqlstate := sqlstate;
    if sqlstate <> '23505' then
      raise exception 'FAIL: expected unique_violation (23505) for a second active case on the same tank, got % (%)', sqlstate, sqlerrm;
    end if;
  end;

  if not v_rejected then
    raise exception 'FAIL: a second active case for tank % was created -- blend_cases_one_active_per_tank did not block it', v_tank;
  end if;

  -- The 'hold' status also counts as active -- confirm the constraint
  -- covers it too, not just 'open'.
  update public.blend_cases set status = 'hold', hold_reason = 'test hold', hold_at = now()
  where id = v_case1.id;

  begin
    perform public.create_blend_case(
      p_operator := 'Test Operator 3', p_pq := 'Test PQ 3',
      p_tank := v_tank, p_tank_no := v_tank
    );
    raise exception 'FAIL: a second active case for tank % (case on hold) was created', v_tank;
  exception when others then
    if sqlstate <> '23505' then
      raise exception 'FAIL: expected unique_violation (23505) for a second case while the first is on hold, got % (%)', sqlstate, sqlerrm;
    end if;
  end;

  raise notice 'PASS: 01_concurrent_tank_conflict -- second create_blend_case for an active tank rejected with % both while open and while on hold', v_sqlstate;
end $$;

rollback;
