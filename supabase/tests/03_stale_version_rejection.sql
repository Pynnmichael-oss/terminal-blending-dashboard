-- 03_stale_version_rejection.sql
--
-- Validates optimistic concurrency (blend_cases.record_version): a
-- mutating RPC called with a stale p_expected_version is rejected with
-- 40001 (serialization_failure) and leaves the row completely unchanged
-- -- no blind last-write-wins. Exercised against advance_blend_case_stage
-- and place_blend_case_on_hold as representative examples; every other
-- mutating RPC (release_blend_case_hold, close_blend_case,
-- abandon_blend_case, update_blend_case_data, save_blend_case_results,
-- set_blend_case_decision, record_blend_case_actual_volume) shares the
-- exact same "select ... for update; if record_version <> expected then
-- raise 40001" pattern -- see the migration files.
begin;

do $$
declare
  v_tank  text := 'TEST-TANK-' || substr(gen_random_uuid()::text, 1, 8);
  v_case  public.blend_cases;
  v_before public.blend_cases;
  v_rejected boolean := false;
begin
  v_case := public.create_blend_case(
    p_operator := 'Test Operator', p_pq := 'Test PQ',
    p_tank := v_tank, p_tank_no := v_tank
  );
  if v_case.record_version <> 1 then
    raise exception 'FAIL: expected a freshly-created case to start at record_version 1, got %', v_case.record_version;
  end if;

  select * into v_before from public.blend_cases where id = v_case.id;

  -- Deliberately pass the wrong (stale) version.
  begin
    perform public.advance_blend_case_stage(v_case.id, v_case.record_version + 999, 'Test Operator', 'should be rejected');
  exception when others then
    v_rejected := true;
    if sqlstate <> '40001' then
      raise exception 'FAIL: expected serialization_failure (40001) for a stale record_version, got % (%)', sqlstate, sqlerrm;
    end if;
    if sqlerrm not ilike '%stale record%' then
      raise exception 'FAIL: expected a "stale record" message, got: %', sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: advance_blend_case_stage succeeded with a deliberately wrong record_version';
  end if;

  -- Confirm the row is byte-for-byte unchanged -- no partial/blind apply.
  if (select stage from public.blend_cases where id = v_case.id) <> v_before.stage
     or (select record_version from public.blend_cases where id = v_case.id) <> v_before.record_version then
    raise exception 'FAIL: the case row changed despite the stale-version RPC call being rejected';
  end if;

  -- Same check against a second RPC (place_blend_case_on_hold) to confirm
  -- this isn't specific to advance_blend_case_stage.
  v_rejected := false;
  begin
    perform public.place_blend_case_on_hold(v_case.id, v_case.record_version + 999, 'a valid reason', 'Test Operator');
  exception when others then
    v_rejected := true;
    if sqlstate <> '40001' then
      raise exception 'FAIL: expected serialization_failure (40001) from place_blend_case_on_hold with a stale version, got % (%)', sqlstate, sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: place_blend_case_on_hold succeeded with a deliberately wrong record_version';
  end if;

  -- Now confirm the CORRECT version is accepted and actually advances
  -- record_version, so the guard isn't just permanently rejecting.
  v_case := public.advance_blend_case_stage(v_case.id, v_case.record_version, 'Test Operator', 'correct version');
  if v_case.record_version <> v_before.record_version + 1 then
    raise exception 'FAIL: record_version did not increment on a successful call (expected %, got %)', v_before.record_version + 1, v_case.record_version;
  end if;
  if v_case.stage <> 3 then
    raise exception 'FAIL: expected stage to advance from 1 to 3, got %', v_case.stage;
  end if;

  raise notice 'PASS: 03_stale_version_rejection -- stale record_version rejected with 40001 and left the row unchanged; correct version succeeded and incremented it';
end $$;

rollback;
