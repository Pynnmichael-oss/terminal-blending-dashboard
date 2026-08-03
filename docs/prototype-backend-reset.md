# Prototype Backend Reset

This branch replaces the prior RPC-heavy Supabase model with three tables while preserving the existing Blend Case Manager HTML workflow and validations.

## Data model

- `blend_plans`: saved Blend Planner output. New rows use `status = planned` and appear in the Case Manager planner queue.
- `blend_cases`: one execution row per promoted plan. The immutable planner row is copied to `source_plan_snapshot`; current operational data is stored in `case_state`.
- `terminal_state`: terminal-wide state such as certified-butane compliance volume.
- Storage bucket `blend-case-files`: reserved for BOL and CoA persistence.

## Planner-to-case transfer

Promotion preserves the complete source row. The fields used directly by the current UI are also made explicit in `case_state.data.plannerTransfer`:

- incoming RVP
- target RVP
- planned butane barrels
- planned truck count
- predicted final RVP

The operator assigns the Fort Worth blend number in Blend Case Manager. The planner does not assign it.

## Compatibility adapter

`assets/js/blend-repository.js` keeps the existing `window.BlendRepo` API so the current single-file HTML does not need a workflow rewrite. Internally it performs direct table operations and stores deliveries, logs, results, and evolving workflow fields inside `blend_cases.case_state`.

The compatibility checkout is only a UI edit-mode marker. It has no lease, token enforcement, timeout, optimistic concurrency rejection, retry loop, or database lock.

## New Supabase project setup

1. Create a new Supabase project.
2. Open SQL Editor and run `supabase/prototype-reset.sql` once.
3. Copy the new project URL and publishable key into `assets/js/supabase-config.js`.
4. Configure the same URL and key in the Blend Planner Vite environment.
5. Deploy the dashboard branch and the matching Planner branch.

Do not run the reset SQL against the old project. It is intentionally written for a clean project and does not migrate old prototype data.

## Required validation

1. Save a plan from Blend Planner.
2. Confirm it appears as **Planned** in Blend Case Manager.
3. Confirm tank, grade, windows, estimated inventory, incoming RVP, target RVP, planned butane, truck count, and predicted final RVP match.
4. Enter a blend number and promote the plan.
5. Refresh and confirm the case persists.
6. Record an open gauge and confirm planned values do not change.
7. Complete a truck and confirm planned and actual truck volumes remain separate.
8. Refresh during the workflow and confirm the current stage and records reload.
9. Release and close the case; confirm it reloads read-only.

## Deferred work

The Storage bucket is created, but the current HTML still keeps some attachment payloads in browser state. Wiring every file control to Supabase Storage is a separate, bounded follow-up after the core reset is live.
