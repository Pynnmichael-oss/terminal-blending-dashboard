# v5 merge — implementation map

Baseline SHA: `0d75e145793da504eec3a2a85ebf69f7ad8e6f1e` (master, includes patches
0001–0006: CoA Generator page, analyzer-photo capture in the certify modal,
its inert-script bugfix, Supabase Storage for those photos, and the restyle/
field-parity follow-ups).

Branch: `feat/ftw-blend-case-manager-v5`.

This is a map, not a redesign doc, per the brief's own instruction — it exists
to keep the diff honest, not to re-litigate the workflow (which the brief
already approved).

## 1. Stage renumbering (the highest-risk single change)

Old (current production, 0–10, 11 values):
```
0 (pre-promotion) 1 Open Gauge → ... 8 Certify & Release → 9 Final Blend
Summary → 10 Close Blend (terminal)
```
New (brief, 1–11, 11 values — literal STAGES array text from the prototype):
```
1 Plan Source
2 Header Sample & Tentative Trucks
3 Static Gauge & U/M/L Samples
4 Official Blend Calculation & Truck Order
5 Opening Alignment & Start Circulation
6 Process Trucks
7 Complete Circulation & Closing Alignment
8 Settle
9 Close Gauge & Post-Blend Samples
10 Certify & Release
11 Final Blend Summary & Close
```
Note the new model **merges old stages 9 and 10** (Final Blend Summary /
Close Blend) into a single terminal stage 11, and **inserts two new stages
before anything physical happens** (Header Sample, and splitting static
gauge from official calc/order). Every downstream stage number shifts.

Grep against current production found **49 numeric `.stage` comparisons**
across 30+ functions, plus 11 `setStage(c, N)` call sites and 3 `stage:N`
literal object fields (`makeCase` default, two seed cases). All of these
need re-auditing against the new numbering — not a mechanical +1 shift,
because stage boundaries themselves moved (e.g. "opening gauge" no longer
exists as its own stage the same way; it's folded into stage 3 with U/M/L,
and stage 5's "opening alignment" is now stage-gated separately from
"process trucks" at stage 6, where today they're one stage-4 flow).

Known call sites requiring re-audit (non-exhaustive, found via grep, not
yet individually verified against new semantics):
`setStage`, `targetLocked`, `openTruckModal` (`.stage!==4`), `openTestModal`
(`.stage!==8`), `closeCase` (`.stage!==10`), `promotePlan` (sets `viewStageIndex=1`
and case stage 1), `normalize()` (has existing `if(c.stage===5)c.stage=6` /
`if(c.closed&&c.stage===9)c.stage=10` migration shims already — these are
the precedent pattern to extend, not replace), archive/closed-case rendering,
progress display, next-action text, `blend_cases_closed_requires_final_stage`
DB constraint (currently `stage = 9` per migration 025 — wrong number for
either the old *or* new model's true terminal stage and needs its own fix
regardless of this merge, worth flagging separately), `ftw_allowed_next_stage()`
RPC (currently encodes the old `0→1→3→5→6→7→8→9` graph server-side —
this is the actual server-side gate on `advance_blend_case_stage` and must be
rewritten to the new 11-stage graph or every stage advance under the new
workflow will be rejected by the database).

## 2. Legacy migration approach (brief calls this "most likely to go wrong")

Reuse the prototype's `workflowVersion` field (2 = v5, absent/1 = legacy).
Per the brief: **never** reinterpret an old numeric `stage` by index alone —
derive real physical progress from evidence already on the case (which
events/results exist), then map to new semantics. Current `normalize()`
already has narrow, evidence-based shims for exactly this kind of drift
(`if(c.closed&&c.stage===9)c.stage=10` from the V8.9.8 merge) — extend that
pattern, keyed off `workflowVersion`, rather than a blanket stage-index
remap. Needs a concrete mapping table (old evidence → new stage) before any
code is written, covering at minimum: no-samples-yet, header-sample-only
(doesn't exist in legacy data — legacy cases jump straight to what is now
"static"), post-static/pre-order, post-order/pre-circulation, mid-truck,
post-circulation/pre-settle, post-settle/pre-certify, certified/released,
closed, abandoned, on-hold-at-each-point. This table is not yet written.

## 3. Real architectural collision found (not anticipated by the brief)

The brief was written against the **pre-patch** production baseline. Patches
0002–0006 (applied this session, after the prototype was forked) already
added a *different, narrower* analyzer-photo integration to the existing
stage-8 certify modal: Upper/Middle/Lower PTOT + RVP(ASTM) photo capture
(`checkPair`, `vaporBoxes`, `updateVpEntryUI`, `vpPhotoLocalId`/
`vpPhotoRemotePath`, Supabase Storage upload via `uploadCaseFile`/
`downloadCaseFile` in `assets/js/blend-repository.js`) that mirrors PTOT into
the release-calculation table.

The prototype's stage-10 self-cert (brief §"Self-certification", handoff
item 18) is a **superset** of this: same PTOT/ASTM capture *plus* E10
PTOT+ASTM, D86 distillation fields, the fixed-layout distillation-photo
reader, T50/completeness/PASS-HOLD gates, and generated-CoA storage — using
different function names (`checkGrabnerPair`, `refreshSelfCertPairCheck`,
`loadSelfCertTesseract`, `parseFixedNumericOcr`, `chooseEndpointFbp`, etc.)
that were independently built rather than sharing code with 0002–0006.

This needs a real decision, not a mechanical merge: port the prototype's
fuller self-cert wholesale (superseding 0002–0006's narrower version, but
preserving its already-working Supabase Storage upload path rather than
reverting to the prototype's local-only storage), or reconcile the two
function sets by hand. Recommend the former — the brief explicitly asks for
the full CoA-Generator-derived self-cert (D86/T50 included), which 0002–0006
never attempted. Flagging this now because guessing wrong here changes a
safety/compliance gate (T50 HOLD logic, PASS/HOLD determination).

## 4. Confirmed *not* requiring a migration

- **Driver Name removal**: grep-verified the current schema already has
  `p_driver text default null` in `plan_blend_case_delivery`
  (migration 020) — no NOT NULL constraint anywhere. The actual requirement
  is 100% client-side: `beginTruckOffload()`'s
  `if(!w.bol||!w.driver||!w.operator){alert(...)}` guard in
  `blend-case-manager.html`. Removing it is a UI-only change (drop the
  `#t-driver` field, the guard clause, and the `driver:` references in
  `worksheetData()`/delivery display) — the brief's "if an old RPC signature
  doesn't fit... fix it with a migration" clause turns out not to apply here.

## 5. Confirmed present, ready to port

- `STRAPPING_CHARTS` object in the prototype: keyed by tank number
  (`"23155"`, `"23156"`, `"27405"` — confirmed, `"27404"` absent as the brief
  says), each with a `gallons` array at 1/16" increments plus `version`/
  `source`/`sheet` provenance fields. Straightforward to port verbatim;
  needs a `tankVolumeFromGauge()` wrapper (already named/present in the
  prototype) that explicitly errors for 27404 rather than falling through.
- New STAGES array text (verbatim, see §1).
- Full new-function inventory extracted via signature diff (98 functions
  present in the prototype and absent from current production — full list
  captured in this session's scratch output, not reproduced here to keep
  this doc short; re-derivable any time via `comm -13` on sorted
  `^function name` extractions from both files' inline scripts).

## 6. What's genuinely unverified

- **No test harness is present in either reference file.** Grepped the
  prototype for a `test(`/`assertEqual`/runner pattern — zero matches. The
  handoff doc's "77/77 tests passing" was produced by tooling that isn't in
  this workspace and isn't reproducible from what was supplied. This repo
  has no client-side test infrastructure today (per `CLAUDE.md`'s own
  Development section) to fall back on.
- No live-browser smoke test has been run yet (Regular blend, Premium
  blend, shortened circulation/settle, one legacy open case, one legacy
  closed case, per the brief's required smoke tests).
- No Supabase migration for the new stage graph / RPC changes has been
  written or applied yet.
