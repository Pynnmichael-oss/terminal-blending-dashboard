-- 04_checkout_conflict_and_expiration.sql
--
-- Validates checkout_blend_case / renew_blend_case_checkout: a second
-- checkout while a lease is active is rejected (55P03), renewal only
-- works with the matching token, and an EXPIRED lease can be acquired by
-- a different device without going through force_release.
begin;

do $$
declare
  v_tank text := 'TEST-TANK-' || substr(gen_random_uuid()::text, 1, 8);
  v_case public.blend_cases;
  v_rejected boolean := false;
  v_wrong_token uuid := gen_random_uuid();
begin
  v_case := public.create_blend_case(
    p_operator := 'Test Operator', p_pq := 'Test PQ',
    p_tank := v_tank, p_tank_no := v_tank
  );

  -- Lease intentionally short (5 min) so the renewal step below (20 min)
  -- deterministically extends checkout_expires_at even though now() is
  -- frozen for the lifetime of this test's transaction (Postgres
  -- transaction-snapshot semantics) -- comparing against real elapsed
  -- wall-clock time wouldn't work from inside a single transaction.
  v_case := public.checkout_blend_case(v_case.id, 'Device A', 'Operator A', 5);
  if v_case.checkout_token is null then
    raise exception 'FAIL: checkout_blend_case did not set a checkout_token';
  end if;
  if v_case.checkout_device <> 'Device A' then
    raise exception 'FAIL: expected checkout_device Device A, got %', v_case.checkout_device;
  end if;

  -- A second device tries to check out the same, still-active-lease case.
  begin
    perform public.checkout_blend_case(v_case.id, 'Device B', 'Operator B', 20);
  exception when others then
    v_rejected := true;
    if sqlstate <> '55P03' then
      raise exception 'FAIL: expected lock_not_available (55P03) for a checkout conflict, got % (%)', sqlstate, sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: a second device successfully checked out a case with an active lease held by another device';
  end if;

  -- Renewal with the WRONG token is rejected.
  v_rejected := false;
  begin
    perform public.renew_blend_case_checkout(v_case.id, v_wrong_token, 20);
  exception when others then
    v_rejected := true;
    if sqlstate <> '55P03' then
      raise exception 'FAIL: expected lock_not_available (55P03) renewing with the wrong token, got % (%)', sqlstate, sqlerrm;
    end if;
  end;
  if not v_rejected then
    raise exception 'FAIL: renew_blend_case_checkout succeeded with a token that does not match the current lease';
  end if;

  -- Renewal with the CORRECT token succeeds and pushes checkout_expires_at forward.
  declare
    v_expires_before timestamptz := v_case.checkout_expires_at;
  begin
    v_case := public.renew_blend_case_checkout(v_case.id, v_case.checkout_token, 20);
    if v_case.checkout_expires_at <= v_expires_before then
      raise exception 'FAIL: renew_blend_case_checkout (20 min) did not extend checkout_expires_at past the original 5-min lease (before %, after %)', v_expires_before, v_case.checkout_expires_at;
    end if;
  end;

  -- Simulate the lease having expired (the RPC always sets a
  -- forward-looking expiry, so backdating it directly is the only way to
  -- test the "expired lease is acquirable" branch without a real wait).
  update public.blend_cases set checkout_expires_at = now() - interval '1 minute' where id = v_case.id;

  -- A different device should now be able to check it out WITHOUT force-release.
  v_case := public.checkout_blend_case(v_case.id, 'Device B', 'Operator B', 20);
  if v_case.checkout_device <> 'Device B' then
    raise exception 'FAIL: expected Device B to acquire the expired lease, got %', v_case.checkout_device;
  end if;
  if v_case.checkout_expires_at <= now() then
    raise exception 'FAIL: newly-acquired lease is not in the future';
  end if;

  raise notice 'PASS: 04_checkout_conflict_and_expiration -- conflicting checkout rejected (55P03), wrong-token renewal rejected, correct-token renewal extended the lease, and an expired lease was acquired by a different device without force-release';
end $$;

rollback;
