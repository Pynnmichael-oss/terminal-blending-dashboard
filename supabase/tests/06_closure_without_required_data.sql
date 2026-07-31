-- 06_closure_without_required_data.sql
--
-- Validates close_blend_case's two gates: it must be at stage 9, must
-- have release authorization recorded (case_data->certification->release),
-- and must have a blend_case_results row with close_gauge populated --
-- rejecting closure at each missing piece, then succeeding once all are
-- present.
begin;

do $$
declare
  v_tank text := 'TEST-TANK-' || substr(gen_random_uuid()::text, 1, 8);
  v_case public.blend_cases;
  v_rejected boolean;
begin
  v_case := public.create_blend_case(
    p_operator := 'Test Operator', p_pq := 'Test PQ',
    p_tank := v_tank, p_tank_no := v_tank
  );

  -- Not at stage 9 yet -- must be rejected on that basis alone.
  v_rejected := false;
  begin
    perform public.close_blend_case(v_case.id, v_case.record_version, 'Test Operator', null);
  exception when others then
    v_rejected := true;
    if sqlerrm not ilike '%final stage%' then
      raise exception 'FAIL: expected a "final stage" error closing before stage 9, got: %', sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: close_blend_case succeeded before the case reached stage 9';
  end if;

  -- Walk to stage 9.
  for i in 1..6 loop
    v_case := public.advance_blend_case_stage(v_case.id, v_case.record_version, 'Test Operator', null);
  end loop;
  if v_case.stage <> 9 then
    raise exception 'FAIL: expected to reach stage 9, got %', v_case.stage;
  end if;

  -- At stage 9, but no release recorded yet.
  v_rejected := false;
  begin
    perform public.close_blend_case(v_case.id, v_case.record_version, 'Test Operator', null);
  exception when others then
    v_rejected := true;
    if sqlerrm not ilike '%release authorization%' then
      raise exception 'FAIL: expected a "release authorization" error, got: %', sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: close_blend_case succeeded with no release authorization recorded';
  end if;

  -- Record release authorization, but still no close-gauge results.
  v_case := public.update_blend_case_data(
    v_case.id, v_case.record_version,
    jsonb_build_object('certification', jsonb_build_object('release', jsonb_build_object('at', now(), 'by', 'Test PQ'))),
    'Test PQ', null
  );

  v_rejected := false;
  begin
    perform public.close_blend_case(v_case.id, v_case.record_version, 'Test Operator', null);
  exception when others then
    v_rejected := true;
    if sqlerrm not ilike '%close-gauge results%' then
      raise exception 'FAIL: expected a "close-gauge results" error, got: %', sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: close_blend_case succeeded with no close-gauge results recorded';
  end if;

  -- Record close-gauge results. save_blend_case_results returns the
  -- results row, not the case row -- re-select the case for its current
  -- record_version (the function bumps it internally).
  perform public.save_blend_case_results(
    v_case.id, v_case.record_version,
    jsonb_build_object('close_gauge', jsonb_build_object('height', '10-0-0', 'netBbl', 1000)),
    'Test Operator'
  );
  select * into v_case from public.blend_cases where id = v_case.id;

  -- Now both gates are satisfied -- close should succeed.
  v_case := public.close_blend_case(v_case.id, v_case.record_version, 'Test Operator', 'test closure');
  if v_case.status <> 'closed' then
    raise exception 'FAIL: expected status closed, got %', v_case.status;
  end if;
  if v_case.completed_at is null then
    raise exception 'FAIL: expected completed_at to be set on closure';
  end if;

  -- Reopening a closed case is explicitly not supported -- confirm a
  -- second close (or anything else requiring status='open') is rejected.
  v_rejected := false;
  begin
    perform public.close_blend_case(v_case.id, v_case.record_version, 'Test Operator', null);
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'FAIL: close_blend_case succeeded a second time on an already-closed case';
  end if;

  raise notice 'PASS: 06_closure_without_required_data -- close_blend_case rejected before stage 9, without release authorization, and without close-gauge results, then succeeded once both were recorded';
end $$;

rollback;
