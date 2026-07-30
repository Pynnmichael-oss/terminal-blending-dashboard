-- 05_stage_skip_rejection.sql
--
-- Validates that a blend case can only ever move one legal stage step at
-- a time (per ftw_allowed_next_stage: 0->1->3->5->6->7->8->9), and that
-- the old back door for arbitrary stage/status jumps
-- (change_blend_case_status, migration 007) is no longer reachable by
-- anon/authenticated at all -- its EXECUTE grant was revoked in the
-- hardening pass rather than the function being dropped.
--
-- CURRENTLY FAILS against the live project as of migration 022: writing
-- this test found that the has_function_privilege() checks below fail --
-- migrations 017/018 revoked EXECUTE on change_blend_case_status and
-- delete_blend_case from `anon, authenticated`, but never from PUBLIC,
-- which Postgres grants EXECUTE to by default on function creation and
-- which anon/authenticated implicitly inherit. Both functions are
-- therefore still fully callable by anyone holding the anon key. See
-- migration 00000000000023_revoke_public_execute_on_superseded_rpcs.sql,
-- which fixes this -- apply it before this test will pass.
begin;

do $$
declare
  v_tank text := 'TEST-TANK-' || substr(gen_random_uuid()::text, 1, 8);
  v_case public.blend_cases;
  v_expected_path smallint[] := array[3,5,6,7,8,9];
  v_stage smallint;
  v_rejected boolean;
begin
  v_case := public.create_blend_case(
    p_operator := 'Test Operator', p_pq := 'Test PQ',
    p_tank := v_tank, p_tank_no := v_tank
  );
  if v_case.stage <> 1 then
    raise exception 'FAIL: expected a freshly-created case to start at stage 1 (see migration 011), got %', v_case.stage;
  end if;

  -- Walk the entire legal path one call at a time; each call must land
  -- on exactly the next value in ftw_allowed_next_stage, never further.
  foreach v_stage in array v_expected_path loop
    v_case := public.advance_blend_case_stage(v_case.id, v_case.record_version, 'Test Operator', null);
    if v_case.stage <> v_stage then
      raise exception 'FAIL: expected stage % after advance_blend_case_stage, got %', v_stage, v_case.stage;
    end if;
  end loop;

  -- At the final stage (9), one more advance must be rejected outright,
  -- not silently no-op or wrap around.
  v_rejected := false;
  begin
    perform public.advance_blend_case_stage(v_case.id, v_case.record_version, 'Test Operator', null);
  exception when others then
    v_rejected := true;
    if sqlerrm not ilike '%final stage%' then
      raise exception 'FAIL: expected a "final stage" error advancing past stage 9, got: %', sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: advance_blend_case_stage succeeded past the final stage (9)';
  end if;

  -- The superseded generic RPC must not be callable by anon/authenticated
  -- at all -- this is what actually prevents "jump straight to stage 9"
  -- or "set an arbitrary status" from the browser now, since the RPC
  -- that used to allow it has no grant.
  if has_function_privilege(
    'anon', 'public.change_blend_case_status(uuid, text, smallint, text, text, text)', 'EXECUTE'
  ) then
    raise exception 'FAIL: anon can still EXECUTE change_blend_case_status -- the arbitrary stage/status back door is not actually closed';
  end if;
  if has_function_privilege(
    'authenticated', 'public.change_blend_case_status(uuid, text, smallint, text, text, text)', 'EXECUTE'
  ) then
    raise exception 'FAIL: authenticated can still EXECUTE change_blend_case_status';
  end if;

  -- delete_blend_case (the pre-abandonment permanent-delete RPC) must
  -- likewise be unreachable now that abandon_blend_case replaces it.
  if has_function_privilege('anon', 'public.delete_blend_case(uuid, text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.delete_blend_case(uuid, text)', 'EXECUTE') then
    raise exception 'FAIL: anon/authenticated can still EXECUTE delete_blend_case -- permanent deletion back door is not closed';
  end if;

  raise notice 'PASS: 05_stage_skip_rejection -- advance_blend_case_stage only ever moved one legal step, rejected advancing past stage 9, and change_blend_case_status/delete_blend_case are confirmed unreachable by anon/authenticated';
end $$;

rollback;
