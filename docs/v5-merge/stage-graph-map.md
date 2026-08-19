# Batch 9 — stage graph mapping (design, before code)

This is the design step the brief asks for before touching the routing table
("audit every stage-dependent function... not a mechanical +1 shift"). Written
against the current file state (batches 1–8 committed, all additive).

## Old graph (current production, `STAGES` array + `stageHtml()` dispatch)

```
0  Plan Source                    -> inline (plan snapshot box)
1  Open Gauge & Sample            -> openGaugeStage(c,z)
2  Validate & Order Trucks        -> validateAndOrderStage(c,z)
3  Open Circulation / Blend Start -> startCirculationStage(c)
4  Process Trucks                 -> processTrucksStage(c)
5  (STAGES[5] === null)           -> stopCirculationStage(c)  [same fn as 6]
6  Final Circulation & Settle     -> stopCirculationStage(c)
7  Close Gauge                    -> closeGaugeStage(c)
8  Certify & Release              -> certificationStage(c)
9  Final Blend Summary            -> finalBlendSummaryStage(c)
10 (default/else)                 -> closePacketStage(c)
```
49 numeric `.stage` comparisons, 11 `setStage()` sites, 3 `stage:N` literal
fields (`makeCase` default `stage:1`, two seed cases) — re-confirmed against
the current file, unchanged by batches 1–8 (they're all either additive or,
where they touched live code in 5/6, kept the same gate numbers).

## New graph (brief, literal STAGES text)

```
1  Plan Source
2  Header Sample & Tentative Trucks
3  Static Gauge & U/M/L Samples
4  Official Blend Calculation & Truck Order
5  Opening Alignment & Start Circulation
6  Process Trucks
7  Complete Circulation & Closing Alignment
8  Settle
9  Close Gauge & Post-Blend Samples
10 Certify & Release
11 Final Blend Summary & Close
```

## Content-function assignment, new stage by new stage

| New | Content | Advance condition / action | Notes |
|---|---|---|---|
| 1 | Plan Source (existing inline box, reused as-is) | promotion always lands here | Same content as old 0. |
| 2 | `headerSampleStage(c)` (batch 3) | `recordHeaderSample()` records the sample; **does not** auto-advance — operator may still send the tentative preorder (`openTentativeOrderModal()`, batch 3) from this same stage before moving on. Advance to 3 is its own explicit step (see below). | Batch 3's functions already exist; this is new wiring, not new logic. |
| 3 | `staticSampleStage(c)` (batch 4) | `recordStaticSamples()` records gauge+U/M/L. **Design decision:** stage 3 ends here — `recordStaticSamples()` should call `setStage(c,4)` directly. The "Draft Official Truck Order" button currently rendered inside `staticSampleStage()`'s recorded branch (batch 4) needs to move to stage 4's own content instead — batch 4 built it there because stage 4 didn't exist yet to hold it. **Action item for the wiring pass:** relocate that button/action out of `staticSampleStage()` into the new stage-4 function below. | |
| 4 | New `officialCalculationStage(c)` (not yet written) | Shows `compareTruckPlans()` (batch 4, already exists) result (confirm/revise) + the "Draft Official Truck Order" action (`draftOfficialTruckOrder()`, batch 4, already exists — just needs a real modal per batch 4's own deferred-UI note). `recordOfficialTruckOrder()` (batch 4) advances via `setStage(c,5)`. | The comparison/order logic already exists (batch 4); this stage is new render-fragment glue, not new business logic. |
| 5 | New `openingAlignmentStage(c)` (not yet written, but see below) | Main valve opening alignment (excluding truck valves) — **already exists and is already correctly scoped** (`valveSegmentHtml(c,'opening','circulation')`, confirmed in batch 5's investigation: the CIRCULATION phase is already separated from the per-truck OFFLOAD phase in the valve data). `recordCirculationStart()` (existing, already editable/defaults-to-now per batch-5 findings) advances via `setStage(c,4)` **today** — needs to become `setStage(c,6)` under the new numbering. | Mostly a renumber + confirming the existing opening-alignment content (currently folded into old stage 3's `startCirculationStage`) gets its own stage-5 slot. |
| 6 | Existing `processTrucksStage(c)` | Unchanged content — already correctly does per-truck valve open→offload→close (confirmed live in batch 5's investigation, nothing to restructure). Advances once all trucks complete via existing `completeOffload()`/`advanceToBlend()` gating — needs its `setStage()` target renumbered to 7. | No logic changes, only the numbers it's gated on/advances to. |
| 7 | Existing `stopCirculationStage(c)` / `circulationPostPanel(c)` (already fixed in batch 5 to measure the 2hr target from actual start) | `completeCirculationShutdown()` (batch 5, already fixed) advances — currently targets `setStage(c,7)` under old numbering (stage 6→7); needs to become `setStage(c,8)`. | Batch 5 already did the *hard* part (timing fix, acknowledgement). This is a pure renumber. |
| 8 | Existing settle content (also inside `stopCirculationStage(c)`'s rendering, per current structure) | `completeSettle()` (batch 5, already un-prototyped) advances — currently `setStage(c,7)`; needs to become `setStage(c,9)`. | Same: batch 5 did the hard part. |
| 9 | Existing `closeGaugeStage(c)` (chart-derived volume since batch 2) **plus** `postBlendSampleSetHtml(c)` (batch 6, currently appended onto `closeGaugeStage()`'s recorded branch) | `recordCloseGauge()` (batch 2) records the gauge; `recordPostBlendSampleSet()` (batch 6) records the sample set. Advance to 10 happens once **both** are recorded — currently neither function calls `setStage()` at all for this transition (old model didn't have a separate post-blend-sample gate). **New:** `recordPostBlendSampleSet()` should call `setStage(c,10)` once both `c.closeGauge` and `c.postBlendSampleSet` exist. | Batch 6 already appended the right content in the right place; needs an explicit advance added. |
| 10 | Existing `certificationStage(c)`, needs its self-cert/third-party sub-views swapped from the OLD testModal-driven flow to `selfCertStage(c)`(batch 7a) / `thirdPartyCertStage(c)`(batch 8) | `recordSelfCertification()` / `recordThirdPartyCertification()` (batches 7a/8) need a `setStage(c,11)` added once outcome is recorded (self-cert) or CoA received (third-party) — neither currently advances stage, matching the "not wired yet" status. | **This is the real remaining risk area**: `certificationStage(c)` today branches on `c.certification.route` (terminal/third-party) and drives the OLD `evaluateTest()`/`releaseIteration()` flow. Swapping its content to batches 7a/8's functions without breaking `releaseIteration()`'s own release-authorization bookkeeping (`c.certification.release`, used by `closeCase()`'s gate) needs its own close look — flagged, not resolved by this map. |
| 11 | Existing `finalBlendSummaryStage(c)` + `closePacketStage(c)`, **merged** — brief's new stage 11 is "Final Blend Summary & Close" as one stage where the old model had two (9 and 10). | `continueFromFinalSummary()` (existing) currently does `setStage(c,10)` then `closeCase()` gates on `c.stage!==10`. Under the new model there's no separate stage 10 — `closeCase()`'s gate becomes `c.stage!==11`, and whatever `continueFromFinalSummary()` did to justify a stage transition needs to fold into staying at 11 (or the summary/close boundary needs its own small design note — not fully resolved here either). | Second flagged risk area. |

## What this map does NOT yet resolve (explicit, not silently decided)

1. **Certify & Release (new 10) content swap** — how `certificationStage(c)` transitions from the old terminal/third-party branch to batches 7a/8's self-cert/third-party functions without losing `c.certification.release`'s role as `closeCase()`'s gate. Needs its own focused pass, likely its own sub-batch (9c) rather than folded into the mechanical renumbering (9b).
2. **Final Blend Summary & Close (new 11) merge** — collapsing old stages 9+10 into one. Needs a decision on what, if anything, `continueFromFinalSummary()` still does as a distinct step versus folding directly into `closeCase()`'s stage-11 gate.
3. **`ftw_allowed_next_stage()`** (server-side RPC, migration 017) — still encodes the *old* stage graph. Every `advance_blend_case_stage` call under the new numbering will be rejected by the database until this is rewritten and applied. This is a Supabase migration, written and read-only-verified per our process, **not applied live without an explicit go-ahead**.
4. **`blend_cases_closed_requires_final_stage`** constraint (migration 025) checks `stage = 9` — already wrong for the *old* 11-value model's real terminal stage (10) before this merge even starts; doubly wrong for the new model's terminal stage (11). Flagged as a pre-existing bug independent of this merge, worth fixing in the same migration pass regardless.

## Sequencing constraint (why this can't just be turned on)

Flipping `stageHtml()`'s routing table to the new numbering the moment it's
written would immediately misrender every one of the 4 real cases currently
live in Supabase (stages 4/8/10/10 in *old* numbering — none of which mean
what those numbers mean in the *new* graph). This makes batch 9 (new graph)
and batch 10 (legacy migration) **not independently deployable** — the new
graph can only go live gated behind `c.workflowVersion===2`, with legacy
cases (`workflowVersion` absent) continuing through the *old*, completely
unmodified routing. That gate is minimal batch-10 scope pulled forward into
batch 9's own scope, not a merge of the two batches — the *evidence-based*
legacy stage inference (mapping an old case's real progress to a new stage
number, in case a legacy case's `workflowVersion` ever needs promoting) stays
its own later step.

## Planned sub-sequence for batch 9

- **9a (this commit):** this design doc. No code.
- **9b:** `workflowVersion` field + branching gate in `stageHtml()` — old path
  untouched and used for every real case that exists today; new path is a
  stub that new (`workflowVersion:2`) cases would hit, initially still
  rendering via the *old* functions (safe no-op) until 9c/9d wire in the
  real new-stage content. Verified by confirming legacy-shaped cases render
  byte-identical to before.
- **9c:** wire stages 1–9 (the mechanical/already-solved renumbering rows in
  the table above) into the new routing.
- **9d:** resolve the two flagged risk areas (Certify & Release content
  swap, Final Summary & Close merge) — these need focused attention, not
  mechanical wiring.
- **9e:** the `ftw_allowed_next_stage()` / terminal-stage-constraint
  migration — written, read-only-verified, not applied live without sign-off.
