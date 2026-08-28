// Fort Worth Blend Case Manager -- window.BlendRepo implementation.
//
// This module is the ONLY place that knows about Supabase. It exposes
// exactly the methods the v8.11.0 front end calls on window.BlendRepo,
// and normalizes every RPC failure into an Error whose .message is the
// server's message, with .isStaleVersion set to true when the failure
// was an optimistic-concurrency conflict (record_version mismatch) so
// the front end's handleStaleVersion()/staleRetry logic can react to it.
//
// All mutating calls go through Postgres RPC functions (SECURITY DEFINER,
// version-checked). Tables are otherwise read-only to the anon key -- see
// supabase/migrations for the schema and RLS policies.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cfg = window.__SUPABASE_CONFIG__;
if (!cfg || !cfg.url || !cfg.anonKey) {
  console.error('[supabase-client] window.__SUPABASE_CONFIG__ is missing url/anonKey.');
}

const supabase = cfg ? createClient(cfg.url, cfg.anonKey) : null;

function wrapError(error) {
  const e = new Error(error?.message || 'Supabase request failed');
  e.isStaleVersion = /^STALE_VERSION/.test(error?.message || '');
  e.cause = error;
  return e;
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw wrapError(error);
  return data;
}

// The front end's setStage()/advanceBlendCaseStage() call site only ever
// passes a message of the exact form "Advanced to stage N (Label)" -- the
// numeric target stage is embedded in the string rather than passed as
// its own argument. Extract it here so the RPC can receive an explicit
// integer instead of trying to parse free text server-side.
function extractStageNumber(message) {
  const m = /stage (\d+)/i.exec(String(message || ''));
  return m ? parseInt(m[1], 10) : null;
}

window.BlendRepo = {
  // ---- reads ----
  async listBlendPlans() {
    return await rpc('list_blend_plans', {});
  },
  async listBlendCases() {
    return await rpc('list_blend_cases', {});
  },
  async getBlendCase(caseId) {
    const row = await rpc('get_blend_case', { p_case_id: caseId });
    if (!row) throw new Error('Blend case not found.');
    return row;
  },
  async getButaneComplianceStatus() {
    return await rpc('get_butane_compliance_status', {});
  },

  // ---- notes / audit ----
  async addNote(caseId, who, text) {
    return await rpc('add_note', { p_case_id: caseId, p_actor: who, p_message: text });
  },

  // ---- stage / lifecycle ----
  async advanceBlendCaseStage(caseId, expectedVersion, actor, message) {
    return await rpc('advance_blend_case_stage', {
      p_case_id: caseId,
      p_expected_version: expectedVersion,
      p_stage: extractStageNumber(message),
      p_actor: actor,
      p_message: message
    });
  },
  async closeBlendCase(caseId, expectedVersion, actor, reason) {
    return await rpc('close_blend_case', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_actor: actor, p_reason: reason
    });
  },
  async placeBlendCaseOnHold(caseId, expectedVersion, reason, actor) {
    return await rpc('place_blend_case_on_hold', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_reason: reason, p_actor: actor
    });
  },
  async releaseBlendCaseHold(caseId, expectedVersion, actor, reason) {
    return await rpc('release_blend_case_hold', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_actor: actor, p_reason: reason
    });
  },
  async setBlendCaseDecision(caseId, expectedVersion, decision, actor) {
    return await rpc('set_blend_case_decision', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_decision: decision, p_actor: actor
    });
  },
  async recordBlendCaseActualVolume(caseId, expectedVersion, net, actor) {
    return await rpc('record_blend_case_actual_volume', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_net: net, p_actor: actor
    });
  },
  async abandonBlendCase(caseId, expectedVersion, actor, reason) {
    return await rpc('abandon_blend_case', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_actor: actor, p_reason: reason
    });
  },

  // ---- checkout / device lease ----
  async checkoutBlendCase(caseId, device, actor) {
    return await rpc('checkout_blend_case', { p_case_id: caseId, p_device: device, p_actor: actor });
  },
  async releaseBlendCaseCheckout(caseId, token, actor) {
    return await rpc('release_blend_case_checkout', { p_case_id: caseId, p_token: token, p_actor: actor });
  },
  async forceReleaseBlendCaseCheckout(caseId, device, reason) {
    return await rpc('force_release_blend_case_checkout', { p_case_id: caseId, p_device: device, p_reason: reason });
  },
  async renewBlendCaseCheckout(caseId, token, leaseMinutes) {
    return await rpc('renew_blend_case_checkout', {
      p_case_id: caseId, p_token: token, p_lease_minutes: leaseMinutes
    });
  },

  // ---- generic case_data / results sync ----
  async updateBlendCaseData(caseId, expectedVersion, payload, actor) {
    return await rpc('update_blend_case_data', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_payload: payload, p_actor: actor
    });
  },
  async saveBlendCaseResults(caseId, expectedVersion, results, actor) {
    return await rpc('save_blend_case_results', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_results: results, p_actor: actor
    });
  },

  // ---- planner integration ----
  async updateBlendPlan(planId, expectedVersion, patch) {
    return await rpc('update_blend_plan', {
      p_plan_id: planId, p_expected_version: expectedVersion, p_patch: patch
    });
  },
  async promoteBlendPlan(plan, opts) {
    return await rpc('promote_blend_plan', {
      p_plan_id: plan.id,
      p_case_number: opts.caseNumber,
      p_operator: opts.operator,
      p_pq: opts.pq ?? null
    });
  },

  // ---- deliveries ----
  async startDelivery(caseId, expectedVersion, payload) {
    return await rpc('start_delivery', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_payload: payload
    });
  },
  async recordRefusedDelivery(caseId, expectedVersion, payload) {
    return await rpc('record_refused_delivery', {
      p_case_id: caseId, p_expected_version: expectedVersion, p_payload: payload
    });
  },
  async completeDeliveryWithoutMeasuredVolume(deliveryId, expectedVersion, payload) {
    return await rpc('complete_delivery_without_measured_volume', {
      p_delivery_id: deliveryId, p_expected_version: expectedVersion, p_payload: payload
    });
  }
};

window.dispatchEvent(new Event('blend-repo-ready'));
