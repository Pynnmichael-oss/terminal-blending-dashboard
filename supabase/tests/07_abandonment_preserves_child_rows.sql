-- 07_abandonment_preserves_child_rows.sql
--
-- Validates abandon_blend_case: never deletes blend_case_deliveries /
-- blend_case_events / blend_case_results, sets the abandonment metadata,
-- clears any checkout lease, and reverts a promoted source plan back to
-- 'proposed'. This is the primary objective of the hardening pass --
-- deletion previously cascaded through all of these.
begin;

do $$
declare
  v_tank text := 'TEST-TANK-' || substr(gen_random_uuid()::text, 1, 8);
  v_plan_id uuid;
  v_case public.blend_cases;
  v_delivery_count_before int;
  v_event_count_before int;
  v_results_exists_before boolean;
  v_rejected boolean;
begin
  insert into public.blend_plans (
    plan_code, tank, tank_no, window_start, window_end, status
  ) values (
    'TEST-PLAN-' || substr(gen_random_uuid()::text, 1, 8),
    v_tank, v_tank, '2026-01-01 00:00', '2026-01-01 12:00', 'proposed'
  ) returning id into v_plan_id;

  v_case := public.create_blend_case(
    p_operator := 'Test Operator', p_pq := 'Test PQ',
    p_tank := v_tank, p_plan_id := v_plan_id, p_tank_no := v_tank
  );

  v_case := public.checkout_blend_case(v_case.id, 'Device A', 'Operator A', 20);

  perform public.plan_blend_case_delivery(v_case.id, 1, 190, 'BOL-1', 'Driver A', 'Test Operator');
  perform public.complete_blend_case_delivery(
    (select id from public.blend_case_deliveries where blend_case_id = v_case.id and sequence = 1),
    189.6, 'Test Operator'
  );
  perform public.add_blend_case_note(v_case.id, 'Test Operator', 'a freeform audit note');
  select * into v_case from public.blend_cases where id = v_case.id;
  perform public.save_blend_case_results(
    v_case.id, v_case.record_version,
    jsonb_build_object('open_gauge', jsonb_build_object('height', '5-0-0', 'netBbl', 500)),
    'Test Operator'
  );
  select * into v_case from public.blend_cases where id = v_case.id;

  select count(*) into v_delivery_count_before from public.blend_case_deliveries where blend_case_id = v_case.id;
  select count(*) into v_event_count_before from public.blend_case_events where blend_case_id = v_case.id;
  select exists(select 1 from public.blend_case_results where blend_case_id = v_case.id) into v_results_exists_before;

  if v_delivery_count_before <> 1 then
    raise exception 'FAIL: expected 1 delivery before abandonment, got %', v_delivery_count_before;
  end if;
  if v_event_count_before < 4 then -- created, checked out, delivery, note (at least)
    raise exception 'FAIL: expected at least 4 events before abandonment, got %', v_event_count_before;
  end if;
  if not v_results_exists_before then
    raise exception 'FAIL: expected a results row to exist before abandonment';
  end if;

  -- Reason is required.
  v_rejected := false;
  begin
    perform public.abandon_blend_case(v_case.id, 'Test Operator', '', v_case.record_version);
  exception when others then
    v_rejected := true;
    if sqlerrm not ilike '%reason is required%' then
      raise exception 'FAIL: expected a "reason is required" error for an empty reason, got: %', sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: abandon_blend_case succeeded with an empty reason';
  end if;

  v_case := public.abandon_blend_case(v_case.id, 'Test Operator', 'test-driven abandonment', v_case.record_version);

  if v_case.status <> 'abandoned' then
    raise exception 'FAIL: expected status abandoned, got %', v_case.status;
  end if;
  if v_case.abandoned_at is null or v_case.abandoned_by is null or v_case.abandonment_reason is null then
    raise exception 'FAIL: expected abandoned_at/abandoned_by/abandonment_reason to all be set';
  end if;
  if v_case.checkout_token is not null or v_case.checkout_device is not null then
    raise exception 'FAIL: expected the checkout lease to be cleared on abandonment';
  end if;

  -- Nothing was cascaded away.
  if (select count(*) from public.blend_case_deliveries where blend_case_id = v_case.id) <> v_delivery_count_before then
    raise exception 'FAIL: delivery rows were lost on abandonment';
  end if;
  if (select count(*) from public.blend_case_events where blend_case_id = v_case.id) < v_event_count_before then
    raise exception 'FAIL: event rows were lost on abandonment (abandonment itself should only ADD one)';
  end if;
  if not exists(select 1 from public.blend_case_results where blend_case_id = v_case.id) then
    raise exception 'FAIL: results row was lost on abandonment';
  end if;

  -- The source plan reverts to 'proposed' so it can be promoted again.
  if (select status from public.blend_plans where id = v_plan_id) <> 'proposed' then
    raise exception 'FAIL: expected source plan status to revert to proposed, got %', (select status from public.blend_plans where id = v_plan_id);
  end if;

  -- An already-abandoned case cannot be abandoned again.
  v_rejected := false;
  begin
    perform public.abandon_blend_case(v_case.id, 'Test Operator', 'second attempt', v_case.record_version);
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'FAIL: abandon_blend_case succeeded a second time on an already-abandoned case';
  end if;

  raise notice 'PASS: 07_abandonment_preserves_child_rows -- deliveries/events/results all preserved, checkout cleared, source plan reverted to proposed, empty reason and double-abandonment both rejected';
end $$;

rollback;
