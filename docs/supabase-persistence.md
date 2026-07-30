# Supabase Persistence — Setup, Validation, and Follow-up

## What this milestone delivers

The Blend Planner / Blend Case Manager (`blend-case-manager.html`) now
persists to Supabase Postgres instead of `localStorage`. This covers the
brief's "First Milestone" vertical slice:

1. Database schema created (5 tables + 2 RPCs, all migrated, all RLS-enabled).
2. **Plan Blend** (promoting a planner row to an active case) saves atomically
   to Supabase via the `create_blend_case` RPC.
3. Blend Case Manager loads all cases from Supabase on page load.
4. Opening a case loads its deliveries, events, and results (all eager-loaded
   at initial fetch, given the prototype's small data volume).
5. Status/stage changes, actual truck volumes, and notes persist independently
   from planned values.

## Project

- Supabase project: `terminal-blending-dashboard` (ref `lmmgaeeoyukfbihoajxi`, `us-east-2`)
- Created in your org (`jvuypncilgtifascbhjb`) after you deleted the
  inactive "Loose Itenerary" project to free up your org's 2-project free-tier slot.

## Environment configuration

This is a static site with **no build step**, deployed via **GitHub Pages**
(which serves committed files directly — there is no CI/build stage to
inject secrets at deploy time). Because of that, the convention here is
the opposite of a typical `.env` setup:

```
assets/js/supabase-config.example.js   <- template, for reference
assets/js/supabase-config.js           <- the REAL, COMMITTED config file
```

**`supabase-config.js` must be committed to the repo, not gitignored.**
This is safe: it only contains the project URL and the **anon/publishable
key**, which Supabase is explicitly designed to expose in browser code —
access is enforced entirely by Row Level Security policies, not by keeping
this key secret (see `supabase/migrations/00000000000008_row_level_security.sql`
for the current, intentionally-permissive dev policies).

> **Earlier version of this doc got this backwards** — it gitignored
> `supabase-config.js`, which meant the file never made it to the GitHub
> Pages deployment and the live site hung indefinitely on "Connecting to
> Supabase…" with no config at all. That's been corrected: the file is
> now committed with real values, and `waitForBlendRepo()` in
> `blend-case-manager.html` now times out after 8s and shows the red error
> banner instead of hanging silently if this ever breaks again.

**The service-role key must never appear anywhere in this repository.**
There is no server-side component here to keep it safe in.

## Files changed / added

```
supabase/migrations/00000000000001_extensions_and_helpers.sql
supabase/migrations/00000000000002_blend_plans.sql
supabase/migrations/00000000000003_blend_cases.sql
supabase/migrations/00000000000004_blend_case_deliveries.sql
supabase/migrations/00000000000005_blend_case_events.sql
supabase/migrations/00000000000006_blend_case_results.sql
supabase/migrations/00000000000007_rpc_functions.sql
supabase/migrations/00000000000008_row_level_security.sql
supabase/migrations/00000000000009_dev_seed.sql
assets/js/supabase-config.example.js   (new, committed, template only)
assets/js/supabase-config.js           (new, committed — see note above on why)
assets/js/supabase-client.js           (new)
assets/js/blend-repository.js          (new — the data-access/repository layer)
blend-case-manager.html                (modified — see below)
.gitignore                             (new)
docs/supabase-persistence.md           (this file)
```

Nothing else in the repository (`index.html`, `lab-procedures.html`,
`operator-proficiency.html`, `rack-demand-forecast.html`,
`receipt-schedule.html`, `data/`, `fuels-snapshot.js`, `t4-schedule.js`)
was touched.

### What changed inside `blend-case-manager.html`

- 3 `<script>` tags added to `<head>` to load the config, client, and
  repository (in that order).
- A sync/error status banner added under the hero section.
- `loadState`/`saveState` (localStorage) kept only as a non-authoritative
  local mirror; a new `buildStateFromSupabase()` + mapping functions
  (`mapDbPlanToAppPlan`, `mapDbCaseToAppCase`) reconstruct the exact
  in-memory shape the rest of the file already expects, from Supabase rows.
- `log()` now also inserts a `blend_case_events` row when the case is
  Supabase-backed.
- `setStage()`, `placeDiscussionHold()`, and `closeCase()` now call the
  `change_blend_case_status` RPC so every stage/status transition is
  recorded in history.
- `promotePlan()` (the "Plan Blend" action) now calls
  `BlendRepo.promoteBlendPlan(...)`, which atomically runs `create_blend_case`,
  then refreshes local state from Supabase on success.
- `confirmDeferPlan()` / `reopenPlan()` persist plan status changes.
- `render()` now also fires `persistCurrentCase()`, a debounced sync of the
  currently selected case's deliveries, results, and catch-all `case_data`
  fields (actual quantities, notes, gauge data, certification info) to
  Supabase, comparing a snapshot hash so unchanged state isn't re-sent.
- The bottom of the script replaced a synchronous `render()` bootstrap with
  an async `initApp()`: waits for the repository module, loads real state
  from Supabase, and falls back to local demo data (`seed()`) with a visible
  red error banner if Supabase is unreachable — errors are never swallowed.

## Deviations from the original brief (read this)

The actual repository differs substantially from the brief's conceptual
model — see the deviation summary given at the start of this task. In short:

- There's no build tooling at all (no `package.json`/framework/bundler);
  Supabase is loaded as an ES module straight from a CDN (`esm.sh`).
- The app is a single-product butane-blending (RVP/DVPE) execution tracker,
  not a multi-component fuel blend planner. `blend_components` became
  `blend_case_deliveries` (planned vs. actual truck loads — the real
  planned/actual pair in this domain) plus `blend_plans` (pre-promotion
  planner rows).
- Status is modeled as the app's own `stage` (0–9) + coarse
  `open/hold/closed`, not the brief's generic `draft/planned/.../cancelled`
  list, per the brief's own "unless the app already has a compatible status
  model" rule.
- There is no UI to *create* a new planner row from scratch — planner rows
  are seeded server-side today. "Plan Blend" for this milestone is the
  existing **promote-plan-to-case** action, which is the app's actual
  planning-to-execution boundary. Adding a "create new plan" form is
  flagged as follow-up work, not built here (avoiding unrequested UI
  redesign per the working rules).
- A large amount of nested, still-evolving state (packet/document
  checklist, certification route bookkeeping, compliance-sample linkage,
  pre-blend DVPE validation samples, mixing/settle timestamps) is kept in
  a `case_data` jsonb catch-all on `blend_cases` rather than fully
  normalized, per the brief's own guidance to prefer relational with
  "selective jsonb for flexible or not-yet-finalized" data. Supplier
  compliance-sample tracking (the 500,000-gal / 90-day oversight cycle)
  remains local-only this milestone.

## Authentication and RLS

The existing app has no login/session/user identity of any kind. Per the
brief's instructions for this situation, RLS is enabled on every table, but
the current policies are **permissive dev-only policies that grant the
anon key full read/write access to all rows**. This is documented in-line
in `supabase/migrations/00000000000008_row_level_security.sql` with an
explicit risk callout and a checklist of what must change before any
production rollout (real auth, `auth.uid()`-scoped policies, moving writes
behind the existing `SECURITY DEFINER` RPCs only).

## Validation performed

Automated/direct-to-database checks (via the Supabase connector, bypassing
the browser — see "Known gap" below):

- ✅ All 9 migrations applied cleanly; `list_tables` confirms 5 tables, RLS
  enabled on all of them, dev seed present (1 plan, 1 case).
- ✅ `create_blend_case` rejects a duplicate active-tank case (raises,
  no row created) — confirms "a failed component insert does not leave an
  incomplete blend case" and "an active case already exists" validation.
- ✅ `create_blend_case` with a malformed delivery payload (bad numeric
  value) rolls back the *entire* call — zero orphaned `blend_cases` or
  `blend_case_deliveries` rows — confirms atomicity end-to-end, not just
  at the top-level insert.
- ✅ `change_blend_case_status` advances stage 0→1 and writes a
  `stage_change` event row alongside the original `created` event —
  confirms "status changes persist" and "status changes generate history
  events".
- ✅ All three new JS files (`supabase-client.js`, `blend-repository.js`,
  and the modified inline script in `blend-case-manager.html`) pass
  `node --check` syntax validation.
- ✅ The two new mapping functions (`mapDbPlanToAppPlan`,
  `mapDbCaseToAppCase`) were extracted and run against realistic Supabase
  row shapes (including numeric-as-string coercion, nested deliveries, and
  event arrays) in an isolated Node harness — output matches the shape the
  rest of the app's render functions expect.

### Known gap — not yet verified

**The app has not been opened in an actual browser.** This environment has
no browser, and this sandbox's network egress is restricted to a small
domain allowlist that does not include `supabase.co` or `esm.sh`, so I
cannot make a live REST call as the anon key from here, and cannot load
the CDN module or render the page myself. Everything above was verified
either via direct Postgres access (which bypasses RLS and browser-side
concerns entirely) or via an isolated Node reproduction of the pure
JS logic. **Please run the manual checklist below in an actual browser
before considering this milestone done** — it is the one thing I could not
do myself, and it is the most likely place for a real bug to surface (e.g.
RLS blocking anon writes, a CORS/config typo, or the `esm.sh` import
failing to load in your specific browser).

## Manual validation checklist (please run this in a browser)

1. Open `blend-case-manager.html` directly (e.g. via `python3 -m http.server`
   and a local URL, or any static file server) with dev tools open.
2. Confirm the mode chip shows "● Live · Supabase" and the sync banner
   disappears after a moment. If you instead see a red "Could not load
   from Supabase" banner, check the browser console — likely a CORS,
   RLS, or config-typo issue.
3. Confirm "Blend 1" (`BL-2026-0312`) appears on the active-blends board
   and "Blend 2" (`PLAN-2026-W31-02`) appears in the planner queue — this
   is the dev seed data, proving the initial Supabase load works.
4. Promote "Blend 2": fill in operator/PQ, click **Promote to active
   blend**. Confirm it appears on the board with a new `BL-2026-####` id.
5. **Refresh the page.** Confirm the promoted case is still there (this is
   the "refreshing does not lose data" test) — it now comes from Supabase,
   not from the promote action's in-memory state.
6. Open the newly promoted case, check it out, and step it through Open
   Gauge → Isolation → Window → Validate (confirm a load plan). Refresh
   again mid-way and confirm the case re-opens at the same stage with the
   same data (the "case can be reopened" test).
7. Confirm the case audit trail panel shows each of the actions you just
   took, in order, with timestamps (events persisting).
8. Confirm the planner's original `est.vol` / `est.rvp` values are still
   shown as "Plan TOV" / "Est RVP" on the case card **before** you record
   an open gauge, and that they don't change after you later enter actual
   TOV/RVP at open gauge — this is the planned-vs-actual separation test.
9. In the Supabase dashboard's Table Editor (or via SQL), confirm:
   - `blend_cases` row exists with the correct `stage`/`status`.
   - `blend_case_events` has one row per audit-trail entry.
   - `blend_case_deliveries` rows appear once you complete a truck (Receive
     stage), with `planned_bbl` unchanged and `actual_bbl` populated only
     after you verify the load.
   - `blend_case_results` row appears once you record a close gauge, with
     `expected_close_bbl`/`actual_close_bbl`/`variance_bbl` populated.
10. Disconnect from the network (or temporarily break `supabase-config.js`)
    and reload — confirm the red error banner appears and the app falls
    back to local demo data rather than showing a blank page or a silent
    failure (Supabase errors surfaced clearly).
11. View page source / the Network tab and confirm no `service_role` key or
    database password appears anywhere in the delivered HTML/JS (client
    code contains no privileged credentials).

## Remaining follow-up work (not in this milestone)

- Add real authentication and replace the permissive dev RLS policies with
  `auth.uid()`-scoped ones (see the risk callout in migration 008).
- Build a "create new plan" form — currently plans are only ever seeded.
- Move supplier butane-oversight compliance tracking (500,000 gal / 90 day
  cycle) into Supabase; it's local-only this milestone.
- Normalize more of the `case_data` / `quality_data` jsonb catch-alls
  (documents/packet checklist, certification route, DVPE sample sets,
  compliance sample linkage) into first-class tables once their shape
  stabilizes.
- Add realtime subscriptions so multiple terminal workstations see the
  same board update live (today it's load-once + explicit writes).
- Add automated tests — this project has no test runner or `package.json`
  at all today, so an automated suite would need its own tooling decision
  (e.g. adding Playwright) before it could be introduced; the manual
  checklist above is the interim substitute per the brief's own allowance
  for that.
- Debounce/queue `persistCurrentCase()` writes more robustly (currently a
  simple snapshot-hash compare) if multiple rapid edits ever race.
