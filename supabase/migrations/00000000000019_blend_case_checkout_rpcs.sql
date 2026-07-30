-- 00000000000019_blend_case_checkout_rpcs.sql
--
-- Hardening pass, part 7: the existing checkout_device/checkout_by/
-- checkout_at columns were only ever a client-side convention -- any
-- browser could overwrite them directly via updateBlendCase(). These
-- RPCs make acquiring, renewing, and releasing a checkout atomic and
-- server-authoritative:
--   * the server generates checkout_token (client never invents one),
--   * every lease has an expiration,
--   * a non-expired lease can only be renewed/released by the holder of
--     the matching token,
--   * an EXPIRED lease can be acquired by a different device without a
--     force-release,
--   * force-release requires a reason and writes an audit event.
--
-- checkout_device / checkout_by remain free-text display/audit labels
-- (no auth system exists -- see the RLS migration's caveat). The token is
-- what actually gates renewal/release, not the device label.

create or replace function public.checkout_blend_case(
  p_blend_case_id uuid,
  p_device        text,
  p_by            text,
  p_lease_minutes integer default 20
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
begin
  if p_device is null or length(trim(p_device)) = 0 then
    raise exception 'a device label is required to check out a case';
  end if;

  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.status in ('closed', 'abandoned') then
    raise exception 'case % is % and cannot be checked out', v_case.case_number, v_case.status;
  end if;
  if v_case.checkout_token is not null and v_case.checkout_expires_at > now() then
    raise exception 'case % is already checked out to % (lease active until %)',
      v_case.case_number, v_case.checkout_device, v_case.checkout_expires_at
      using errcode = 'lock_not_available';
  end if;

  update public.blend_cases set
    checkout_device      = p_device,
    checkout_by          = p_by,
    checkout_at          = now(),
    checkout_token        = gen_random_uuid(),
    checkout_expires_at   = now() + make_interval(mins => greatest(1, p_lease_minutes)),
    record_version        = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  insert into public.blend_case_events (
    blend_case_id, event_type, message, created_by
  ) values (
    p_blend_case_id, 'system', format('Checked out to %s (%s)', p_device, coalesce(p_by, 'unspecified operator')), coalesce(p_by, p_device)
  );

  return v_case;
end;
$$;

comment on function public.checkout_blend_case is
  'Atomically acquires a checkout lease. Fails if the case is closed/abandoned or already leased to someone else with time remaining. An expired lease can be acquired without going through force_release_blend_case_checkout. The returned checkout_token must be stored client-side and presented to renew/release.';

grant execute on function public.checkout_blend_case(uuid, text, text, integer) to anon, authenticated;

create or replace function public.renew_blend_case_checkout(
  p_blend_case_id uuid,
  p_checkout_token uuid,
  p_lease_minutes integer default 20
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
begin
  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.checkout_token is null or v_case.checkout_token <> p_checkout_token then
    raise exception 'checkout token does not match the current lease for case %; it may have expired or been released', v_case.case_number
      using errcode = 'lock_not_available';
  end if;

  update public.blend_cases set
    checkout_expires_at = now() + make_interval(mins => greatest(1, p_lease_minutes)),
    record_version       = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  return v_case;
end;
$$;

comment on function public.renew_blend_case_checkout is
  'Extends an active checkout lease. Only succeeds if the caller presents the current checkout_token -- a client can only renew its own checkout, never someone else''s.';

grant execute on function public.renew_blend_case_checkout(uuid, uuid, integer) to anon, authenticated;

create or replace function public.release_blend_case_checkout(
  p_blend_case_id uuid,
  p_checkout_token uuid,
  p_actor text default null
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
begin
  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.checkout_token is null then
    return v_case; -- already released, nothing to do
  end if;
  if v_case.checkout_token <> p_checkout_token then
    raise exception 'checkout token does not match the current lease for case %; use force_release_blend_case_checkout if the holder is unavailable', v_case.case_number
      using errcode = 'lock_not_available';
  end if;

  update public.blend_cases set
    checkout_device = null, checkout_by = null, checkout_at = null,
    checkout_token = null, checkout_expires_at = null,
    record_version = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  insert into public.blend_case_events (
    blend_case_id, event_type, message, created_by
  ) values (
    p_blend_case_id, 'system', 'Checked in / checkout released', coalesce(p_actor, 'system')
  );

  return v_case;
end;
$$;

comment on function public.release_blend_case_checkout is
  'Normal check-in: releases the lease. Requires the matching checkout_token -- a client can only release its own checkout.';

grant execute on function public.release_blend_case_checkout(uuid, uuid, text) to anon, authenticated;

create or replace function public.force_release_blend_case_checkout(
  p_blend_case_id uuid,
  p_actor         text,
  p_reason        text
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
  v_prior_device text;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a reason is required to force-release a checkout';
  end if;
  if p_actor is null or length(trim(p_actor)) = 0 then
    raise exception 'an actor is required to force-release a checkout';
  end if;

  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;

  v_prior_device := v_case.checkout_device;

  update public.blend_cases set
    checkout_device = null, checkout_by = null, checkout_at = null,
    checkout_token = null, checkout_expires_at = null,
    record_version = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  insert into public.blend_case_events (
    blend_case_id, event_type, message, created_by, event_data
  ) values (
    p_blend_case_id, 'system',
    format('Checkout force-released (was held by %s): %s', coalesce(v_prior_device, 'no one'), p_reason),
    p_actor, jsonb_build_object('reason', p_reason, 'prior_device', v_prior_device)
  );

  return v_case;
end;
$$;

comment on function public.force_release_blend_case_checkout is
  'Bypasses the token check to release a stuck lease -- requires a reason and always writes an audit event. Intended for the case where the original holder is genuinely unavailable, not as routine usage.';

grant execute on function public.force_release_blend_case_checkout(uuid, text, text) to anon, authenticated;

-- Direct client writes to the checkout_* columns are no longer needed --
-- they are fully superseded by the RPCs above. Column-level revoke so
-- updateBlendCase()-style calls can no longer set them directly.
revoke update (checkout_device, checkout_by, checkout_at, checkout_token, checkout_expires_at)
  on public.blend_cases from anon, authenticated;
