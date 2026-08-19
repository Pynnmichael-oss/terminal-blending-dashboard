# Batch 10 — legacy stage inference (design)

## What's already done (9b), confirmed live

`normalize()` tags every case without a `workflowVersion` as `1`. `stageHtml()`
dispatches on it: `1` (or absent) → `stageHtmlLegacy()`, byte-identical to
pre-merge behavior; `2` → `stageHtmlV5()`. Verified moments ago against a real
live case (`FTW55081826A`): loading it under the current codebase correctly
stamped `workflowVersion:1` into its `case_data` via the existing sync
safety-net, with `stage`/`status` completely unchanged. This satisfies the
brief's "open, closed, and abandoned legacy cases must all continue to load
correctly" requirement — already true, already proven against real data.

## What's actually missing: evidence-based stage inference

For the scenario the brief anticipates — moving a legacy case onto the new
workflow mid-flight — `workflowVersion` alone isn't enough. A case flipped to
`2` needs a `stage` number that means something under the *new* graph. The
brief is explicit: never reinterpret the old numeric `stage` by index; infer
real physical progress from what evidence actually exists on the case.

Legacy cases don't have and will never retroactively gain the v5-specific
fields (`headerSample`, `staticGauge`, `officialOrder`, etc.) — inventing
those would fabricate records that never happened, which the brief forbids
("must never destroy or rewrite existing event/result data"). So this
function does **not** synthesize v5 field data. It only computes which v5
*stage number* best represents where the case physically stands today, based
on evidence every legacy case already carries (`openGauge`, `order`,
`circulation.*`, `timestamps.settleCompleteAt`, `closeGauge`,
`certification.release`) — content stages 5–9 already reuse verbatim (per
9c-2), so a case flipped mid-flight would render real content, not a
placeholder.

## The inference ladder (monotonic, evidence-first)

```
no openGauge                                    -> 2  (Header Sample & Tentative Trucks)
openGauge, no order                              -> 4  (Official Blend Calc & Truck Order)
order, circulation.startedAt not set             -> 5  (Opening Alignment & Start Circulation)
circulation.startedAt set, trucks not all done    -> 6  (Process Trucks)
all trucks done, circulation.stoppedAt not set    -> 7  (Complete Circulation & Closing Alignment)
circulation.stoppedAt set, settle not complete    -> 8  (Settle)
settle complete, no closeGauge                    -> 9  (Close Gauge & Post-Blend Samples)
closeGauge set, no certification.release          -> 10 (Certify & Release)
certification.release set                         -> 11 (Final Blend Summary & Close)
```

Notes:
- Skips new-only stage 3 (Static Gauge & U/M/L) deliberately — a legacy case's
  `openGauge`+`preBlendResults` is evidence of *a* gauge/sample event having
  happened, but not the v5-specific static-gauge-with-chart-derived-volume
  event. Mapping straight to 4 avoids implying stage 3 happened when it
  didn't.
- `abandoned` cases are excluded from inference entirely — no operational
  reason to reclassify an archived case's workflow version, and the brief
  says abandoned cases "keep their historical meaning unchanged."
- `closed` cases always land on 11 via the `certification.release` check
  (closing already requires release, per `closeCase()`'s own existing gate)
  — consistent, not a special case.
- This function computes and returns a proposal with its evidence trail. It
  does not mutate anything. Applying it (flipping a real case's
  `workflowVersion` and `stage`) is a separate, explicit, much bigger
  decision — not done as part of building or testing this function.
