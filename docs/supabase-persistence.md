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

## Hardening pass (migrations 013–022)

A second pass focused on data-integrity risks that the first milestone
left open: no way to end a case except a real hard delete, no protection
against two concurrent writers, and no server-side enforcement of the
workflow. **Authentication was explicitly out of scope for this pass** —
see "No authentication" below.

### Abandonment replaces permanent deletion

`delete_blend_case` (migration 012) permanently removed a case and
cascaded through its deliveries/events/results. That is no longer part of
the normal workflow — its `EXECUTE` grant has been revoked (the function
itself is kept, unused, rather than dropped). The Blend Case Manager's
"Delete blend" button is now **"Abandon blend"**:

- Requires a non-empty reason (prompted in the UI).
- Sets `blend_cases.status = 'abandoned'` and records
  `abandoned_at` / `abandoned_by` / `abandonment_reason`.
- Clears any checkout lease.
- Reverts a promoted source `blend_plans` row back to `proposed` so it can
  be promoted again.
- Writes an audit event. **Never deletes** `blend_cases`,
  `blend_case_deliveries`, `blend_case_events`, or `blend_case_results`.

RPC: `abandon_blend_case(p_blend_case_id, p_actor, p_reason, p_expected_version)`.

### Lifecycle enforced in Postgres

The old `change_blend_case_status` RPC (migration 007) accepted any
status/stage combination — its `EXECUTE` grant is now revoked in favor of
four business-specific RPCs, each locking the row, validating the
transition, checking `record_version`, updating the row, and writing the
audit event in one transaction:

- `advance_blend_case_stage` — moves exactly one legal step forward per
  `ftw_allowed_next_stage()`, which encodes the real stage graph the app
  already uses (`0→1→3→5→6→7→8→9`; stages 2 and 4 are UI placeholders the
  app never assigns). Stage skipping and regression are rejected.
- `place_blend_case_on_hold` — requires a non-empty reason.
- `release_blend_case_hold` — always writes an audit event; the reason is
  preserved in that event rather than left on the row.
- `close_blend_case` — requires stage 9, requires release authorization
  (`case_data->certification->release`) and close-gauge results to already
  be recorded, and sets `completed_at`. **Reopening a closed case is not
  supported.**

### One active case per tank / one case per plan

Both are real unique indexes now, not read-before-insert checks:

- `blend_cases_one_active_per_tank` — unique on the generated `tank_key`
  column (prefers `tank_no`, falls back to a normalized `tank` label for
  legacy rows with a blank `tank_no`) `where status in ('open','hold')`.
- `blend_cases_plan_id_unique` — unique on `plan_id where plan_id is not null`.

`create_blend_case` still does a friendly pre-check for a nicer error
message, but under real concurrency the unique index is what actually
prevents two simultaneous requests from both succeeding — the function
catches the resulting `unique_violation` and re-raises a clear message.

### Case numbers generated in Postgres

`next_blend_case_number()` uses a sequence (`blend_case_number_seq`) to
atomically produce `BL-<year>-<6-digit seq>` (e.g. `BL-2026-000123`). The
browser no longer generates or supplies a case number — `create_blend_case`
calls this internally and returns the generated value. Existing
shorter-form numbers (e.g. `BL-2026-6719`) remain valid; formats never
collide because new numbers are always 6 digits.

### Optimistic concurrency (`record_version`)

`blend_cases.record_version` starts at 1 and is incremented by every
mutation RPC. Every mutating RPC takes `p_expected_version` and rejects a
mismatch with SQLSTATE `40001` (`serialization_failure`) and a
`stale record: expected version X but case is at version Y` message.
`blend-repository.js` marks these errors with `.isStaleVersion = true`;
the UI's `handleStaleVersion()` reloads the case from Supabase and shows a
banner rather than retrying or overwriting. **Nothing does blind
last-write-wins on `case_data` or any other field.**

### Checkout leases

The `checkout_device`/`checkout_by`/`checkout_at` columns were previously
just a client-side convention — any browser could overwrite them via a
generic update. They're now driven entirely by RPCs:

- `checkout_blend_case(id, device, by, lease_minutes=20)` — fails if
  already leased with time remaining; the server generates
  `checkout_token` (a `uuid`) and sets `checkout_expires_at`.
- `renew_blend_case_checkout(id, token, lease_minutes)` — only succeeds if
  the caller presents the current token.
- `release_blend_case_checkout(id, token, actor)` — normal check-in;
  requires the matching token.
- `force_release_blend_case_checkout(id, actor, reason)` — bypasses the
  token check but requires a reason and always writes an audit event.
- An **expired** lease can be acquired by a different device without
  going through force-release.

The client stores `checkout_token` in its own localStorage key
(`ftw_bcm_checkout_tokens_v1`), separate from the case-data cache, keyed
per case `dbId` — so a refresh on the *same* device can still check itself
back in, but a different device loading the same case never inherits
someone else's token. `checkout_device`/`checkout_by` remain free-text
display/audit labels, not verified identities (see "No authentication").

**Auto-renewal:** `renew_blend_case_checkout` existed but nothing called
it, so a lease could lapse mid-task on a stage that legitimately runs
longer than the 20-minute default (blend + settle hold routinely does).
`syncCheckoutRenewal()` now runs from `render()` (the same chokepoint
`persistCurrentCase()` uses) and starts a 5-minute `setInterval` calling
`renew_blend_case_checkout` whenever the current case is checked out to
this device; it's idempotent per case (won't restart the interval on
every render) and stops on checkin, force-release, close, abandonment, a
rejected renewal (token mismatch — this device no longer actually holds
the lease), or the tab closing (`beforeunload`/`pagehide`).

### Delivery lifecycle

Generic `upsert()` on `blend_case_deliveries` is revoked (`INSERT`/`UPDATE`
from anon/authenticated). Specific RPCs replace it:
`plan_blend_case_delivery`, `complete_blend_case_delivery`,
`refuse_blend_case_delivery`, and
`correct_completed_blend_case_delivery` (the *only* way to change a
delivery already `status='complete'` — requires a reason and writes a
distinct audit event from the original completion, so a correction is
visible in history rather than silently overwriting it).

### `case_data` / results / decision / actual volume

`case_data` is no longer replaced wholesale. `update_blend_case_data`
merges an explicit allow-list of top-level keys server-side, under
`record_version`, and logs which keys changed. `save_blend_case_results`
upserts the results row the same way. `decision` and `actual_tov_bbl` are
dedicated columns with their own narrow setters
(`set_blend_case_decision`, `record_blend_case_actual_volume`) since
direct `UPDATE` on those columns is now revoked. Freeform notes go through
`add_blend_case_note` — direct `INSERT` into `blend_case_events` is
revoked for anon/authenticated; it is insert-only by design (no
`UPDATE`/`DELETE` policy exists for any caller, including the RPCs).

**Not fully eliminated:** `persistCurrentCase()` in `blend-case-manager.html`
still runs after every `render()` rather than purely from explicit save
actions (objective: rendering should be read-only). It remains as a
snapshot-deduped safety net for any `case_data` field not yet covered by
an explicit call site — normally a no-op, since the actions below now
save before they render.

What *has* been converted to its own explicit, version-checked save call
(await the RPC, update `c.dbVersion` from the response, `handleStaleVersion()`
on a stale conflict, only then `render()`), on top of the RPCs that already
did this (`recordOpenGauge`, `approveScenario`, `beginTruckOffload`/
`refuseTruck`/`completeOffload`, checkout/checkin/force-release):
`chooseTerminalCertification`, `recordSplOrder`, `evaluateTest`,
`releaseIteration`, `startBlend`, `stopBlend`, `completeSettle`. These all
share a `syncCaseData(c, actor)` helper factored out of
`persistCurrentCase()`'s core logic (`updateBlendCaseData` +, when
gauge/reconciliation/release/closed data is present, `saveBlendCaseResults`),
so both the explicit call sites and the safety-net path stay in sync on
what "already saved" means (`lastSyncedSnapshot`).

**`sendAndRecordOversightOrder` / `recordOversightResult` were checked and
found to need no change here:** neither function mutates any field on the
case object (`c`) at all — they only mutate the local-only supplier
compliance record (`state.compliance.suppliers[...]`, not yet in Supabase —
see "Remaining follow-up work" above) and call `log()`, which is already
its own independent, already-persisted RPC (`add_blend_case_note`). There
was no `case_data` write for these two to protect with a version check.

### Invariant constraints

Added via `CHECK` constraints (verified against live data before adding —
this project had 1 case / 0 deliveries at the time, so no conflicting
rows): nonnegative planned/actual volume, positive delivery sequence,
positive planned delivery volume, nonnegative actual delivery volume,
completed deliveries require `completed_at`, refused deliveries require
`refused_at`, closed cases require `completed_at` and `stage=9`, abandoned
cases require `abandoned_at`/`abandoned_by`/`abandonment_reason`, hold
status requires `hold_reason`.

### No authentication (explicitly out of scope for this pass)

**This application still has no login, no session, and no verified user
identity.** Anyone holding the Supabase anon/publishable key can call any
RPC granted to `anon` — including `abandon_blend_case`,
`force_release_blend_case_checkout`, and every lifecycle transition. The
RPC validation added in this pass protects against **accidental**
corruption, invalid workflow transitions, race conditions, stale
overwrites, and loss of audit history — it does **not** protect against a
person with the anon key who intentionally calls an allowed function.
Operator/device labels (`operator`, `pq`, `checkout_by`, `checkout_device`,
event `created_by`) are free text for display and audit context, not
verified identities. A future authentication milestone (Supabase Auth,
`auth.uid()`-scoped RLS policies, replacing free-text actor fields with
verified identity) is deferred and **not implemented** here.

### New/changed RPCs (this pass)

Added: `next_blend_case_number`, `abandon_blend_case`,
`advance_blend_case_stage`, `place_blend_case_on_hold`,
`release_blend_case_hold`, `close_blend_case`, `checkout_blend_case`,
`renew_blend_case_checkout`, `release_blend_case_checkout`,
`force_release_blend_case_checkout`, `plan_blend_case_delivery`,
`complete_blend_case_delivery`, `refuse_blend_case_delivery`,
`correct_completed_blend_case_delivery`, `update_blend_case_data`,
`save_blend_case_results` (replaces the old direct-upsert version),
`add_blend_case_note`, `set_blend_case_decision`,
`record_blend_case_actual_volume`, `ftw_allowed_next_stage` (helper).

Changed: `create_blend_case` (no longer accepts `p_case_number`; generates
it via `next_blend_case_number()`; catches `unique_violation` from the new
indexes).

Revoked `EXECUTE` (kept defined, not dropped): `delete_blend_case`,
`change_blend_case_status`.

**This revoke did not actually take effect until migration 023.**
Migrations 017/018 revoked `EXECUTE` on both functions from
`anon, authenticated` only. Postgres grants `EXECUTE` to the `PUBLIC`
pseudo-role by default when a function is created, and every role
(including `anon`) implicitly inherits `PUBLIC`'s grants — so neither
revoke had any real effect, confirmed via `has_function_privilege()`
while writing `supabase/tests/05_stage_skip_rejection.sql`. Both the old
arbitrary-stage/status RPC and the permanent-delete RPC remained fully
callable by anyone holding the anon key for the entire time between
migration 018 and 023, undermining the lifecycle-enforcement RPCs and the
abandonment-preserves-everything guarantee this pass exists to provide.
`00000000000023_revoke_public_execute_on_superseded_rpcs.sql` fixes this
by explicitly revoking from `PUBLIC` too, and has been applied to the
live project. The other 21 `SECURITY DEFINER` functions added in this
pass carry the same implicit `PUBLIC` grant, but it's a no-op for them —
they're intentionally callable by `anon`/`authenticated` (the only real
caller of this anon-key-only, no-auth browser app) via their own explicit
grants already.

### Browser UI walkthrough (found and fixed 2 real bugs)

Driven end-to-end with Playwright + real Chrome against the live project
(`lmmgaeeoyukfbihoajxi`) — the first time this app was actually opened
in a browser rather than validated by `node --check` and code review.
Found two real bugs neither the SQL test suite nor code review caught,
both fixed:

1. **`promotePlan()`'s client-side guard didn't exclude abandoned
   cases.** `if(state.cases.some(c=>!c.closed&&c.tank===p.tank))` treated
   an abandoned case as still blocking re-promotion of its tank, even
   though the server-side check correctly excludes `abandoned`. Fixed to
   `!c.closed&&!c.abandoned&&c.tank===p.tank`.
2. **`renderBoard()` didn't exclude abandoned cases from the active
   board either** (`filter(x=>!x.c.closed)`, same missing
   `&&!x.c.abandoned` the rest of the file already uses in the
   equivalent spots). An abandoned case would keep occupying a slot on
   the active board. Fixed. (Abandoned cases still don't appear in the
   closed archive either — they're simply gone from view once
   abandoned. Not a bug — no such requirement exists — but worth a
   deliberate design decision in a future pass.)

A third, more serious bug was found the same way and fixed at the
database level, not just the client: see migration `00000000000024`
below — `blend_cases_plan_id_unique` had no `abandoned` exclusion,
so a plan could never actually be re-promoted after its case was
abandoned, contradicting `abandon_blend_case`'s own documented purpose.

Verified via real clicks (not just SQL): app reaches "Live · Supabase"
mode; the planner queue loads; **Plan Blend** promotes a plan into a
server-generated case number; the promoted case **survives a page
refresh** (loaded fresh from Supabase); **checkout** shows "Checked out
to this device"; a **second browser context with no cached token**
correctly sees the lease as held (Force-release only, not a free
checkout) rather than silently overwriting it; **Abandon blend**
prompts for a reason and correctly abandons the case server-side
(confirmed via direct RPC re-verification after the harness's own
polling window closed early — see caveat below).

**Caveat — not resolved, likely a test-harness artifact, not an app
bug:** in this specific sandboxed Playwright environment, RPC calls made
shortly after a second browser context loads/renders the same case
sometimes take 60–125+ seconds to resolve (`TypeError: Failed to fetch`
transiently, then eventually `504 upstream request timeout` from
Supabase's gateway, or eventual success well outside any reasonable UI
wait window). Reproduced identically bypassing the button entirely (a
direct `page.evaluate()` call to `window.BlendRepo.abandonBlendCase`),
which rules out a click/DOM-timing bug specifically. The RPC itself was
independently re-verified correct via direct SQL and via an isolated
single-context browser run (no second context involved), both fast and
correct every time. Likely cause: this sandbox's network path to
`esm.sh` (CDN) + the Supabase project's free-tier connection
pooler under rapid automated multi-context churn — not something a real
operator clicking through the app at human speed would trigger. Flagged
for a human to re-confirm in an ordinary browser/network if there's any
doubt.

### Manual Supabase deployment steps

1. Apply migrations `00000000000013` through `00000000000024` in order
   (`supabase db push`, or run each file's SQL via the dashboard SQL
   editor / `apply_migration`). They were also applied directly to the
   live project during this pass — confirm your target project matches
   before re-applying.
2. Run `supabase db diff` / the security advisor
   (`get_advisors(type: 'security')` via the Supabase MCP tools, or the
   dashboard's Advisors panel) after applying — this pass could not run
   it interactively and it has not been independently re-verified.
3. If you have existing `blend_cases` rows with `tank_no` as an empty
   string on more than one **simultaneously active** (`open`/`hold`) case
   for the same tank, `blend_cases_one_active_per_tank` will fail to
   create — resolve the conflicting rows first (this project had none).

### Testing performed

Run directly against the live project (`lmmgaeeoyukfbihoajxi`) via SQL,
end to end on a disposable test case (created, exercised, then deleted —
not through the app, since normal deletion is intentionally no longer
available):

- ✅ Case number generated as `BL-2026-000123`-style, not client-supplied.
- ✅ Duplicate active case for the same tank rejected
  (`23505 unique_violation: an active case already exists for tank...`).
- ✅ Stage advance moves exactly one legal step (`1→3`); a stale
  `p_expected_version` is rejected with `40001 serialization_failure`.
- ✅ `close_blend_case` rejected at a non-final stage.
- ✅ A second `checkout_blend_case` from a different device while a lease
  is active is rejected (`55P03 lock_not_available`).
- ✅ `plan_blend_case_delivery` → `complete_blend_case_delivery` →
  `correct_completed_blend_case_delivery` (with reason) all round-tripped
  correctly; a second `complete_blend_case_delivery` on an already-complete
  row is rejected.
- ✅ `place_blend_case_on_hold` rejects an empty reason; hold → release
  round-tripped, `hold_reason` cleared on release.
- ✅ `abandon_blend_case` rejects an empty reason; on success, status,
  metadata, checkout-clearing, and the audit event were all correct, and
  every delivery/event row for the case was confirmed still present
  afterward (not cascaded away).
- ✅ Full audit trail for the test case read back in order — one event per
  transition, in the intended sequence.

**Since resolved:** reusable SQL integration-test scripts now exist at
`supabase/tests/` (8 files, see that folder's `README.md`) covering
concurrent-tank-conflict, concurrent-plan-promotion, stale-version
rejection, checkout conflict + expiration, stage-skip rejection, closure
without required data, abandonment preserving child rows, and hold
requiring a reason. All 8 pass against the live project. Writing them is
what found the `PUBLIC`-grant gap documented above under "New/changed
RPCs (this pass)". Client-side (`blend-case-manager.html`) flows were
still only verified by static syntax-check (`node --check`) and code
review against the new RPC surface as of this writing, not by driving the
actual browser UI — see the follow-up items in
"Remaining follow-up work" above.

## V8.9.8 UI merge (migration 025)

A separate design/UI effort produced a new `blend-case-manager.html`
(V8.9.8) on top of an **earlier, pre-hardening baseline** with zero
Supabase wiring of its own. This merge grafted the hardening pass's
Supabase layer (checkout leases, abandonment, optimistic concurrency,
lifecycle RPCs, `case_data` sync) onto that UI's new business logic,
and added one new migration (`00000000000025_ftw_case_number_and_stage_10.sql`)
for two real backend-affecting changes that shipped in the new UI:

### Case numbers are client-supplied again (FTW format)

The V8.9.8 UI replaced the DB-generated `BL-<year>-<6-digit seq>` case
number with an operator-typed number in the format
`FTW<2-digit tank number><MMDDYY>[optional disambiguation letter]`
(e.g. `FTW55073026`), validated client-side against
`/^[A-Z]{3}\d{8}[A-Z]?$/`.

`create_blend_case` now accepts `p_case_number` again (it had stopped
accepting it in migration 016 during the hardening pass). It:
- re-validates the format server-side against `^FTW\d{8}[A-Z]?$`
  (defense in depth — never trusts the client-side check alone),
- relies on the pre-existing `case_number not null unique` constraint
  (migration 003) as the real concurrency guarantee, same as it already
  was for DB-generated numbers,
- catches the resulting `unique_violation` on a collision and raises a
  friendly `"blend number X already exists"` error, following the same
  pattern already used in this function for tank/plan conflicts.

`next_blend_case_number()` (migration 015) is **kept defined but no
longer called automatically** — it's not invoked anywhere in the current
UI, but is left in place in case a future flow wants a generated-fallback
option. `assets/js/blend-repository.js`'s `createBlendCase()` /
`promoteBlendPlan()` now take a `caseNumber` and pass `p_case_number`
through to the RPC.

### Stage 10 ("Close Blend") is now the terminal stage

The UI's `STAGES` array grew from 10 entries (0–9) to 11: stage 9 is now
"Final Blend Summary" (`finalBlendSummaryStage()` /
`continueFromFinalSummary()`, which calls `setStage(c,10)`), and the new
stage 10 ("Close Blend") is what `closeCase()` gates on
(`c.stage!==10`, previously `!==9`). Migration 025 updates every place
that hardcoded 9 as the terminal stage:
- `blend_cases.stage` CHECK constraint: `0–9` → `0–10`.
- `blend_cases_closed_requires_final_stage`: `stage = 9` → `stage = 10`.
- `ftw_allowed_next_stage()`: added the `9 → 10` transition; `8 → 9`
  is unchanged (still "Certify & Release → Final Blend Summary", just no
  longer terminal).
- `close_blend_case()`: requires `stage = 10` (was 9); the audit event
  it writes now records `previous_stage`/`new_stage` as `10, 10`.

A full grep of all 24 prior migrations for `stage.*9|9.*stage` confirmed
these were the only hardcoded terminal-stage references needing a change
(migration 011's comment mentioning "stage 0" and migration 017's
`ftw_allowed_next_stage` doc comment were updated for accuracy but had no
other logic depending on 9 being terminal).

**Verified live** against project `lmmgaeeoyukfbihoajxi` (see git history
for the exact SQL): a valid FTW-format case create succeeds; a duplicate
FTW number is rejected with the friendly error; a malformed (non-FTW)
case number is rejected server-side even though the client would never
send one; advancing a case through stage 9 → 10 via
`advance_blend_case_stage`/`ftw_allowed_next_stage` succeeds; attempting
`close_blend_case` at stage 9 is rejected ("must be at the final stage");
at stage 10 without release authorization or close-gauge results it is
still correctly rejected by the existing gates; with both present, close
succeeds and the row ends at `status='closed', stage=10`. The widened
`stage between 0 and 10` and `stage=11` correctly still rejected.

### `case_data` allow-list gained `circulation` and `marginReview`

The V8.9.8 UI added tank-circulation-timing tracking (`c.circulation`,
written by `recordCirculationStart`/`recordButaneIsolation`/
`completeCirculationShutdown`/`beginTruckOffload`/`completeOffload`) and
a margin/target-capture review step (`c.marginReview`, written by
`continueFromFinalSummary()`). Both are now in `update_blend_case_data`'s
`v_allowed_keys` allow-list (migration 025).

**Verified mechanically, not by inspection:** a Node harness constructed
a case via `makeCase({})` and via `seed()`'s three demo cases, ran
`buildCaseDataPayload(c)` on each, and diffed the resulting key sets
against `CASE_DATA_EXCLUDE` and the RPC's allow-list. Result: zero keys
produced by any real case object fall outside the allow-list (i.e.
nothing a real save would ever attempt to sync gets rejected). Three
allow-list entries (`truckPlan`, `orderedVolume`, `actualSamples`) are
absent from a freshly-created case's payload — expected, since those are
only populated once `approveScenario()`/gauge recording run, not part of
the pre-existing allow-list gap this migration fixes. One seed-only
`mixing` field appeared in a raw (pre-`normalize()`) seeded case's
payload; `normalize()` (which runs at the start of every `render()`,
before any sync can fire) unconditionally deletes it, so it never
reaches a real save.

### `oversightCompliance()` confirmed local-only, no change needed

`oversightCompliance()` reads/writes `state.compliance.suppliers[...]`
only — a top-level `state.compliance` field, never part of any case's
`case_data`, and never sent through any Supabase RPC. This matches
`freshCompliance()`'s existing local-only design (see "Deviations from
the original brief" above) exactly. No wiring was needed or added.

### Known limitation (new, not addressed here): Oversight CoA records are local-only and unsynced

The V8.9.8 UI removed the old `renderLedger()`/`ledgerRows` ledger
entirely, replacing it with an **"Oversight CoA records" system**
(`openOversightCoaDb`, `saveOversightCoaFile`, `loadOversightCoaFile`,
`clearOversightCoaFiles`, `handleOversightCoa`, `renderOversightRecords`)
that stores AmSpec Certificate-of-Analysis file **attachments in the
browser's IndexedDB** (`ftw-oversight-coa` object store), not Supabase.

**This is a real, permanent gap, not a temporary placeholder:**
- CoA files never leave the browser that recorded them.
- They are lost if the browser's storage is cleared, or if the operator
  switches devices/workstations.
- Unlike every other domain field on a case, there is no server-side
  copy, no audit-trail linkage beyond a `recordId` string stored in
  `case_data.complianceSupplier`-adjacent oversight records (which
  *is* synced, but the `recordId` is only useful on the device that
  actually holds the IndexedDB blob).

Wiring this into Supabase Storage was **out of scope for this merge**
(no Storage bucket exists yet, and doing so is a real design decision —
bucket policy, upload flow, size limits — not a drop-in fix). Flagged
here explicitly rather than silently accepted; whether the UI should
also say this out loud to the operator (today it only says "not shared
with other tablets or workstations" in the generic storage-status
banner, not specifically about CoA files) is a product call for a human
to make, not something changed silently as part of this merge.

### Checkout/abandon layer: unchanged, straight swap

The checkout/abandon business logic in the V8.9.8 UI was unchanged from
the pre-hardening prototype (same `'Already checked out.'` alert text, no
abandon flow). `checkoutBlock`, `checkoutCase`, `checkinCase`,
`forceRelease`, `abandonCurrentCase`, `log()`, `setStage()`,
`placeDiscussionHold()`, `approveScenario()`, `recordOpenGauge()`,
`chooseTerminalCertification()`, `recordSplOrder()`, `evaluateTest()`,
and `refuseTruck()` were swapped in verbatim from the hardening-pass
branch (verified byte-identical business logic aside from the Supabase
wiring itself, done via exact-match-count string replacement, not manual
line editing). `releaseIteration`, `completeSettle`, `beginTruckOffload`,
`completeOffload`, the three circulation functions
(`recordCirculationStart`/`recordButaneIsolation`/
`completeCirculationShutdown`), and `promotePlan` had genuinely new
business logic in the V8.9.8 UI (circulation gating, valve alignment,
the settle-warning-override branch, the FTW case-number capture) and got
the same `syncCaseData()`/delivery-RPC wiring pattern grafted in at the
equivalent point in each function's new body instead of a wholesale swap.

