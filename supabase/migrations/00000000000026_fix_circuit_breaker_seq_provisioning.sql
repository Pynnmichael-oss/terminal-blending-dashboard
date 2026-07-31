-- Fix: the server-side conflict circuit breaker (applied live on 2026-07-31 as
-- "server_side_conflict_circuit_breaker", never committed to this repo) has been
-- a silent no-op since it was written.
--
-- record_rpc_circuit_failure() calls nextval() on a per-(case, function) sequence
-- named via rpc_fail_seq_name(), but nothing ever created that sequence first.
-- The nextval() call hit undefined_table, which was caught and swallowed, so the
-- failure count never incremented and check_rpc_circuit_breaker() never tripped
-- -- even after thousands of consecutive stale-version conflicts (incident:
-- 2026-07-31, runaway stale browser tab flooded update_blend_case_data).
--
-- Fix: self-provision the sequence at the start of both record_rpc_circuit_failure
-- and check_rpc_circuit_breaker, so the breaker works regardless of call order.

create or replace function public.check_rpc_circuit_breaker(p_blend_case_id uuid, p_function_name text, p_max_failures integer default 5)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_seq text := public.rpc_fail_seq_name(p_blend_case_id, p_function_name);
  v_count bigint;
  v_is_called boolean;
begin
  perform public.ensure_rpc_circuit_breaker_seq(p_blend_case_id, p_function_name);

  execute format('select last_value, is_called from public.%I', v_seq) into v_count, v_is_called;

  if v_count is not null and v_is_called and v_count >= p_max_failures then
    raise exception 'Updates to this case via % are temporarily suspended after % consecutive conflicts. Reset via reset_rpc_circuit_breaker() once the underlying cause is resolved.', p_function_name, v_count
      using errcode = '55P03';
  end if;
end;
$function$;

create or replace function public.record_rpc_circuit_failure(p_blend_case_id uuid, p_function_name text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_seq text := public.rpc_fail_seq_name(p_blend_case_id, p_function_name);
begin
  perform public.ensure_rpc_circuit_breaker_seq(p_blend_case_id, p_function_name);
  execute format('select nextval(''public.%I'')', v_seq);
end;
$function$;
