-- 08_hold_requires_reason.sql
--
-- Validates place_blend_case_on_hold rejects an empty/null reason, and
-- that a hold -> release round-trip clears hold_reason off the row while
-- preserving the original reason text permanently in the audit event.
begin;

do $$
declare
  v_tank text := 'TEST-TANK-' || substr(gen_random_uuid()::text, 1, 8);
  v_case public.blend_cases;
  v_rejected boolean;
  v_reason text := 'held for discussion -- test reason ' || substr(gen_random_uuid()::text, 1, 8);
begin
  v_case := public.create_blend_case(
    p_operator := 'Test Operator', p_pq := 'Test PQ',
    p_tank := v_tank, p_tank_no := v_tank
  );
  if v_case.status <> 'open' then
    raise exception 'FAIL: expected a freshly-created case to be open, got %', v_case.status;
  end if;

  -- Empty reason rejected.
  v_rejected := false;
  begin
    perform public.place_blend_case_on_hold(v_case.id, v_case.record_version, '', 'Test Operator');
  exception when others then
    v_rejected := true;
    if sqlerrm not ilike '%reason is required%' then
      raise exception 'FAIL: expected a "reason is required" error for an empty reason, got: %', sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: place_blend_case_on_hold succeeded with an empty reason';
  end if;

  -- Whitespace-only reason rejected too (the function trims before checking).
  v_rejected := false;
  begin
    perform public.place_blend_case_on_hold(v_case.id, v_case.record_version, '   ', 'Test Operator');
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'FAIL: place_blend_case_on_hold succeeded with a whitespace-only reason';
  end if;

  -- Null reason rejected.
  v_rejected := false;
  begin
    perform public.place_blend_case_on_hold(v_case.id, v_case.record_version, null, 'Test Operator');
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'FAIL: place_blend_case_on_hold succeeded with a null reason';
  end if;

  -- A real reason succeeds.
  v_case := public.place_blend_case_on_hold(v_case.id, v_case.record_version, v_reason, 'Test Operator');
  if v_case.status <> 'hold' then
    raise exception 'FAIL: expected status hold, got %', v_case.status;
  end if;
  if v_case.hold_reason <> v_reason then
    raise exception 'FAIL: expected hold_reason to be stored verbatim, got %', v_case.hold_reason;
  end if;

  -- A case not currently open cannot be placed on hold again.
  v_rejected := false;
  begin
    perform public.place_blend_case_on_hold(v_case.id, v_case.record_version, 'another reason', 'Test Operator');
  exception when others then
    v_rejected := true;
    if sqlerrm not ilike '%must be open%' then
      raise exception 'FAIL: expected a "must be open" error placing an already-held case on hold, got: %', sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: place_blend_case_on_hold succeeded on a case that was already on hold';
  end if;

  -- Release clears hold_reason off the row...
  v_case := public.release_blend_case_hold(v_case.id, v_case.record_version, 'Test Operator', null);
  if v_case.status <> 'open' then
    raise exception 'FAIL: expected status open after release, got %', v_case.status;
  end if;
  if v_case.hold_reason is not null then
    raise exception 'FAIL: expected hold_reason to be cleared on release, still %', v_case.hold_reason;
  end if;

  -- ...but the original reason text is preserved permanently in the audit event.
  if not exists (
    select 1 from public.blend_case_events
    where blend_case_id = v_case.id and event_type = 'status_change' and message ilike '%' || v_reason || '%'
  ) then
    raise exception 'FAIL: expected the release event message to preserve the original hold reason text';
  end if;

  -- Releasing a case that is not on hold is rejected.
  v_rejected := false;
  begin
    perform public.release_blend_case_hold(v_case.id, v_case.record_version, 'Test Operator', null);
  exception when others then
    v_rejected := true;
    if sqlerrm not ilike '%not on hold%' then
      raise exception 'FAIL: expected a "not on hold" error, got: %', sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: release_blend_case_hold succeeded on a case that was not on hold';
  end if;

  raise notice 'PASS: 08_hold_requires_reason -- empty/whitespace/null reasons all rejected, hold -> release round-tripped correctly, and the original reason survives in the audit event after being cleared off the row';
end $$;

rollback;
