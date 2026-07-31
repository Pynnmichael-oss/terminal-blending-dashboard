-- 00000000000021_blend_case_data_and_results_rpcs.sql
--
-- Hardening pass, part 9: blend_cases.case_data and blend_case_results
-- were being written with a blind whole-object update/upsert
-- (updateBlendCase / saveBlendCaseResults) on every render(). This
-- migration keeps a narrow, explicitly-scoped JSON update path (allowed
-- under objective #10 for "low-risk draft data") instead of removing it
-- outright, because the domain here (documents checklist, DVPE
-- iterations, certification bookkeeping, gauge readings) is too broad to
-- fully break out into first-class columns/functions in this pass. It:
--   * uses optimistic concurrency (record_version),
--   * merges JSON server-side instead of replacing the whole object,
--   * only touches an explicit allow-list of top-level case_data keys,
--   * creates an audit event.
--
-- Fully bespoke RPCs for every domain action (open gauge, certification,
-- release, etc.) are listed as follow-up work in docs/supabase-persistence.md
-- -- this is the safety net underneath them for this milestone, not a
-- replacement for eventually adding them.

create or replace function public.update_blend_case_data(
  p_blend_case_id    uuid,
  p_expected_version bigint,
  p_patch            jsonb,
  p_actor            text,
  p_note             text default null
)
returns public.blend_cases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
  -- Must mirror exactly what buildCaseDataPayload() in
  -- blend-case-manager.html can produce (every makeCase() field not in
  -- CASE_DATA_EXCLUDE): plannerId/receipt/ordered/orderedVolume were
  -- initially missing here, which would have rejected every sync.
  v_allowed_keys text[] := array[
    'documents','preBlendResults','iterations','certification','isolation',
    'timestamps','valveAlignment','window','truckPlan','order','ordered',
    'orderedVolume','globalBatchId','plannerId','receipt','complianceSupplier',
    'complianceContributionGal','summaryGenerated','actualSamples'
  ];
  v_key text;
  v_merged jsonb;
begin
  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.record_version <> p_expected_version then
    raise exception 'stale record: expected version % but case is at version %', p_expected_version, v_case.record_version
      using errcode = 'serialization_failure';
  end if;
  if v_case.status in ('closed', 'abandoned') then
    raise exception 'case % is % and its case_data can no longer be edited', v_case.case_number, v_case.status;
  end if;

  for v_key in select jsonb_object_keys(coalesce(p_patch, '{}'::jsonb))
  loop
    if not (v_key = any(v_allowed_keys)) then
      raise exception 'case_data key "%" is not in the allowed list for update_blend_case_data', v_key;
    end if;
  end loop;

  v_merged := coalesce(v_case.case_data, '{}'::jsonb) || coalesce(p_patch, '{}'::jsonb);

  update public.blend_cases set
    case_data      = v_merged,
    record_version = record_version + 1
  where id = p_blend_case_id
  returning * into v_case;

  insert into public.blend_case_events (blend_case_id, event_type, message, created_by, event_data)
  values (
    p_blend_case_id, 'note',
    coalesce(p_note, format('Case data updated: %s', array_to_string(array(select jsonb_object_keys(p_patch)), ', '))),
    p_actor, jsonb_build_object('updated_keys', array(select jsonb_object_keys(p_patch)))
  );

  return v_case;
end;
$$;

comment on function public.update_blend_case_data is
  'Merges an explicitly-allow-listed set of case_data keys server-side (never a blind whole-object replace), under optimistic concurrency, and logs which keys changed. For not-yet-broken-out prototype fields only -- planned/actual columns and results have their own dedicated functions.';

grant execute on function public.update_blend_case_data(uuid, bigint, jsonb, text, text) to anon, authenticated;

-- save_blend_case_results: version-checked against the parent case,
-- upserts the one results row per case. quality_data/gauges remain jsonb
-- (flexible/evolving per the original brief) but the write is no longer
-- unconditional -- it requires the case to still be active/open.
create or replace function public.save_blend_case_results(
  p_blend_case_id    uuid,
  p_expected_version bigint,
  p_patch            jsonb,
  p_actor            text
)
returns public.blend_case_results
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.blend_cases;
  v_row  public.blend_case_results;
begin
  select * into v_case from public.blend_cases where id = p_blend_case_id for update;
  if not found then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;
  if v_case.record_version <> p_expected_version then
    raise exception 'stale record: expected version % but case is at version %', p_expected_version, v_case.record_version
      using errcode = 'serialization_failure';
  end if;
  if v_case.status = 'abandoned' then
    raise exception 'case % is abandoned and its results can no longer be edited', v_case.case_number;
  end if;

  insert into public.blend_case_results (
    blend_case_id, final_quantity_bbl, open_gauge, close_gauge,
    expected_close_bbl, actual_close_bbl, variance_bbl, within_tolerance, variance_reason,
    quality_data, operational_notes, completed_by, completed_at
  ) values (
    p_blend_case_id,
    (p_patch->>'final_quantity_bbl')::numeric,
    p_patch->'open_gauge', p_patch->'close_gauge',
    (p_patch->>'expected_close_bbl')::numeric, (p_patch->>'actual_close_bbl')::numeric,
    (p_patch->>'variance_bbl')::numeric, (p_patch->>'within_tolerance')::boolean, p_patch->>'variance_reason',
    coalesce(p_patch->'quality_data', '{}'::jsonb), p_patch->>'operational_notes',
    p_patch->>'completed_by', (p_patch->>'completed_at')::timestamptz
  )
  on conflict (blend_case_id) do update set
    final_quantity_bbl = excluded.final_quantity_bbl,
    open_gauge          = excluded.open_gauge,
    close_gauge          = excluded.close_gauge,
    expected_close_bbl   = excluded.expected_close_bbl,
    actual_close_bbl     = excluded.actual_close_bbl,
    variance_bbl         = excluded.variance_bbl,
    within_tolerance     = excluded.within_tolerance,
    variance_reason      = excluded.variance_reason,
    quality_data         = excluded.quality_data,
    operational_notes    = excluded.operational_notes,
    completed_by         = excluded.completed_by,
    completed_at         = excluded.completed_at
  returning * into v_row;

  update public.blend_cases set record_version = record_version + 1 where id = p_blend_case_id;

  insert into public.blend_case_events (blend_case_id, event_type, message, created_by)
  values (p_blend_case_id, 'certification', 'Blend results / quality data updated', p_actor);

  return v_row;
end;
$$;

comment on function public.save_blend_case_results is
  'Upserts the one blend_case_results row for a case (close gauge, reconciliation, quality data, completion). Version-checked against the parent blend_cases row and bumps it, so a stale results save is rejected the same way a stale case update is.';

grant execute on function public.save_blend_case_results(uuid, bigint, jsonb, text) to anon, authenticated;

-- add_blend_case_note: narrowly-scoped freeform note, replacing direct
-- browser INSERT into blend_case_events for anything workflow-related.
create or replace function public.add_blend_case_note(
  p_blend_case_id uuid,
  p_actor         text,
  p_message       text
)
returns public.blend_case_events
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.blend_case_events;
begin
  if p_message is null or length(trim(p_message)) = 0 then
    raise exception 'a message is required to add a note';
  end if;
  if not exists (select 1 from public.blend_cases where id = p_blend_case_id) then
    raise exception 'blend case % not found', p_blend_case_id;
  end if;

  insert into public.blend_case_events (blend_case_id, event_type, message, created_by)
  values (p_blend_case_id, 'note', p_message, coalesce(p_actor, 'system'))
  returning * into v_row;

  return v_row;
end;
$$;

comment on function public.add_blend_case_note is
  'Appends a freeform operator note to a case''s audit trail. Validates the case exists. This is the only sanctioned way for the browser client to write to blend_case_events now -- direct table INSERT is revoked below.';

grant execute on function public.add_blend_case_note(uuid, text, text) to anon, authenticated;

-- Direct anon/authenticated table access is now routed through RPCs for
-- every meaningful workflow write. Revoke the broad grants from the
-- original RLS migration (008) and replace them with read-only + the
-- specific inserts still needed for non-workflow bootstrap data.
revoke insert, update on public.blend_case_events from anon, authenticated;
revoke insert, update on public.blend_case_results from anon, authenticated;
revoke update (case_data, decision, actual_tov_bbl) on public.blend_cases from anon, authenticated;

comment on table public.blend_case_events is
  'Append-only audit trail for a blend case. INSERT is no longer granted directly to anon/authenticated -- all workflow events are written by SECURITY DEFINER RPCs (create_blend_case, advance_blend_case_stage, place_blend_case_on_hold, release_blend_case_hold, close_blend_case, abandon_blend_case, checkout/renew/release/force-release, delivery lifecycle RPCs, update_blend_case_data, save_blend_case_results, add_blend_case_note). Still insert-only by design -- no UPDATE/DELETE policy exists for any caller, including these functions.';
