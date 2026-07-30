// blend-repository.js
//
// Data-access layer for the Blend Planner / Blend Case Manager. All
// Supabase calls for this feature live here -- the presentation code in
// blend-case-manager.html should never call `supabase.from(...)` directly.
// Exposed as `window.BlendRepo` (this app has no module bundler, so the
// classic inline <script> below consumes it as a global).
//
// Every function throws a plain Error with a readable `.message` on
// failure; callers are expected to catch and surface it in the UI (see
// showErrorBanner() in blend-case-manager.html).

import { supabase } from './supabase-client.js';

function assertNoError(error, context) {
  if (error) {
    console.error(`[BlendRepo] ${context}:`, error);
    throw new Error(`${context}: ${error.message || 'unknown Supabase error'}`);
  }
}

/** List blend plans that have not yet been promoted (proposed/deferred). */
async function listBlendPlans() {
  const { data, error } = await supabase
    .from('blend_plans')
    .select('*')
    .neq('status', 'promoted')
    .order('created_at', { ascending: true });
  assertNoError(error, 'listBlendPlans');
  return data;
}

/**
 * List all blend cases with their deliveries, events, and results eagerly
 * loaded. This prototype's data volume is small (a handful of active
 * cases), so we load everything up front rather than lazily per-open --
 * simpler and keeps the existing render() functions working against an
 * in-memory `state` object exactly as they did against localStorage.
 */
async function listBlendCases() {
  const { data, error } = await supabase
    .from('blend_cases')
    .select(`
      *,
      blend_case_deliveries ( * ),
      blend_case_events ( * ),
      blend_case_results ( * )
    `)
    .order('created_at', { ascending: true });
  assertNoError(error, 'listBlendCases');
  return data;
}

/**
 * Atomically creates a blend case (optionally promoting a blend_plans row)
 * via the create_blend_case RPC. Backs the "Plan Blend" action. Throws if
 * the tank already has an active case, or if required fields are missing --
 * no partially-saved case can result, since the whole thing runs as one
 * Postgres function invocation.
 */
async function createBlendCase({
  caseNumber,
  operator,
  pq,
  tank,
  planId = null,
  grade = 'REGULAR',
  tankNo = '',
  rowLabel = null,
  plannedEstVolBbl = null,
  plannedEstRvp = null,
  window: windowInfo = {},
  createdBy = null,
  deliveries = [],
}) {
  const { data, error } = await supabase.rpc('create_blend_case', {
    p_case_number: caseNumber,
    p_operator: operator,
    p_pq: pq,
    p_tank: tank,
    p_plan_id: planId,
    p_grade: grade,
    p_tank_no: tankNo,
    p_row_label: rowLabel,
    p_planned_est_vol_bbl: plannedEstVolBbl,
    p_planned_est_rvp: plannedEstRvp,
    p_window: windowInfo,
    p_created_by: createdBy,
    p_deliveries: deliveries,
  });
  assertNoError(error, 'createBlendCase');
  return data;
}

/** Convenience wrapper: promote a proposed blend_plans row into a case. */
async function promoteBlendPlan(plan, { operator, pq, note, caseNumber }) {
  return createBlendCase({
    caseNumber,
    operator,
    pq,
    tank: plan.tank,
    tankNo: plan.tank_no,
    planId: plan.id,
    grade: plan.grade,
    rowLabel: plan.label,
    plannedEstVolBbl: plan.est_tov_bbl,
    plannedEstRvp: plan.incoming_rvp,
    window: { lastTruck: plan.truck_finish, note },
    createdBy: operator,
  });
}

/**
 * Atomically updates a case's status/stage and writes the corresponding
 * blend_case_events row via the change_blend_case_status RPC.
 */
async function changeBlendCaseStatus(blendCaseId, {
  newStatus = null,
  newStage = null,
  holdReason = null,
  message = null,
  actor = 'system',
}) {
  const { data, error } = await supabase.rpc('change_blend_case_status', {
    p_blend_case_id: blendCaseId,
    p_new_status: newStatus,
    p_new_stage: newStage,
    p_hold_reason: holdReason,
    p_message: message,
    p_actor: actor,
  });
  assertNoError(error, 'changeBlendCaseStatus');
  return data;
}

/** Append a row to the append-only blend_case_events audit trail. */
async function appendEvent(blendCaseId, { eventType = 'note', message, actor = 'system', eventData = {} }) {
  const { data, error } = await supabase
    .from('blend_case_events')
    .insert({
      blend_case_id: blendCaseId,
      event_type: eventType,
      message,
      created_by: actor,
      event_data: eventData,
    })
    .select()
    .single();
  assertNoError(error, 'appendEvent');
  return data;
}

/**
 * General-purpose case field sync -- used for everything that isn't a
 * status/stage transition (decision, actual_tov_bbl, checkout lock,
 * case_data catch-all for documents/certification/preBlendResults/etc).
 * Never touches planned_est_vol_bbl / planned_est_rvp, so planned values
 * are never silently overwritten by actuals.
 */
async function updateBlendCase(blendCaseId, patch) {
  const { data, error } = await supabase
    .from('blend_cases')
    .update(patch)
    .eq('id', blendCaseId)
    .select()
    .single();
  assertNoError(error, 'updateBlendCase');
  return data;
}

/**
 * Upsert a single truck delivery (planned bbl set once, actual bbl set
 * independently later). Uses the (blend_case_id, sequence) unique key.
 */
async function upsertDelivery(blendCaseId, delivery) {
  const row = {
    blend_case_id: blendCaseId,
    sequence: delivery.sequence,
    bol: delivery.bol ?? null,
    driver: delivery.driver ?? null,
    operator: delivery.operator ?? null,
    status: delivery.status ?? 'offloading',
    planned_bbl: delivery.plannedBbl,
    actual_bbl: delivery.actualBbl ?? null,
    worksheet: delivery.worksheet ?? {},
    started_at: delivery.startedAt ?? null,
    completed_at: delivery.completedAt ?? null,
    refused_at: delivery.refusedAt ?? null,
  };
  const { data, error } = await supabase
    .from('blend_case_deliveries')
    .upsert(row, { onConflict: 'blend_case_id,sequence' })
    .select()
    .single();
  assertNoError(error, 'upsertDelivery');
  return data;
}

/**
 * Upsert the case's single results row: close gauge, reconciliation,
 * quality data (DVPE samples / certification), operational notes, and
 * completion. `blendCaseId` is unique on blend_case_results, so this is a
 * true upsert (create-on-first-write, update thereafter).
 */
async function saveBlendCaseResults(blendCaseId, patch) {
  const row = { blend_case_id: blendCaseId, ...patch };
  const { data, error } = await supabase
    .from('blend_case_results')
    .upsert(row, { onConflict: 'blend_case_id' })
    .select()
    .single();
  assertNoError(error, 'saveBlendCaseResults');
  return data;
}

/** Update a blend_plans row directly (used for defer / reopen actions). */
async function updateBlendPlan(planDbId, patch) {
  const { data, error } = await supabase
    .from('blend_plans')
    .update(patch)
    .eq('id', planDbId)
    .select()
    .single();
  assertNoError(error, 'updateBlendPlan');
  return data;
}

window.BlendRepo = {
  listBlendPlans,
  listBlendCases,
  createBlendCase,
  promoteBlendPlan,
  changeBlendCaseStatus,
  appendEvent,
  updateBlendCase,
  updateBlendPlan,
  upsertDelivery,
  saveBlendCaseResults,
};

// Signal to the classic <script> below that the repository is ready to use.
window.dispatchEvent(new Event('blend-repo-ready'));
