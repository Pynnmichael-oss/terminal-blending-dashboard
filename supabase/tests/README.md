# Integration tests

Plain SQL, not pgTAP — this project has no test tooling at all yet, and
pgTAP isn't installed on the project (`select * from pg_available_extensions
where name = 'pgtap'` shows it available but `installed_version` null).
Installing a new extension on a live project is a real decision that
deserves its own explicit ask rather than being a side effect of adding
tests, so these are self-contained scripts instead: each one wraps its
work in `begin; ... rollback;`, asserts with plain `raise exception` on
failure, and prints `raise notice 'PASS: ...'` on success. Nothing they do
is ever committed — a script can be re-run any number of times against a
project with real data without leaving anything behind, and does not
require `anon`/`authenticated` role credentials (they call the
`SECURITY DEFINER` RPCs directly as whatever role runs the script, the
same way the prior session's manual smoke-testing did).

## Running

Any of:

- Supabase SQL Editor (dashboard) — paste and run one file at a time.
- `psql "$DATABASE_URL" -f supabase/tests/01_concurrent_tank_conflict.sql`
- The Supabase MCP `execute_sql` tool, one file's contents at a time.

Run them in order (each is independent, but the numbering matches the
order the hardening pass's own "Testing performed" section covers them
in). A clean run prints one `NOTICE: PASS: ...` per file and ends with
`ROLLBACK`. Any `FAIL:` message or an unexpected error means something
regressed.

## Coverage

| File | Validates |
|---|---|
| `01_concurrent_tank_conflict.sql` | `blend_cases_one_active_per_tank` — a second `create_blend_case` for a tank that already has an active case is rejected (`23505`). |
| `02_concurrent_plan_promotion.sql` | A `blend_plans` row already promoted (`status='promoted'`) cannot be promoted again via `create_blend_case`. |
| `03_stale_version_rejection.sql` | Every mutating RPC's `record_version` check — a stale `p_expected_version` is rejected with `40001 serialization_failure`, and the row is left unchanged. |
| `04_checkout_conflict_and_expiration.sql` | A second `checkout_blend_case` while a lease is active is rejected (`55P03`); an **expired** lease can be acquired by a different device without `force_release_blend_case_checkout`. |
| `05_stage_skip_rejection.sql` | `advance_blend_case_stage` only ever moves one legal step (per `ftw_allowed_next_stage`); the superseded `change_blend_case_status` back door is no longer callable by `anon`/`authenticated` at all (`EXECUTE` revoked). |
| `06_closure_without_required_data.sql` | `close_blend_case` rejects a case missing release authorization, then rejects one still missing close-gauge results, then succeeds once both are recorded. |
| `07_abandonment_preserves_child_rows.sql` | `abandon_blend_case` never deletes `blend_case_deliveries`/`blend_case_events`/`blend_case_results`, sets the abandonment metadata, clears any checkout lease, and reverts a promoted source plan back to `proposed`. |
| `08_hold_requires_reason.sql` | `place_blend_case_on_hold` rejects an empty/null reason; a successful hold → release round-trip preserves the original reason in the audit event even though it's cleared off the row. |

## A note on "concurrent"

`01` and `02` validate the invariant that makes a real race safe (the
unique indexes / row-level status checks), exercised **sequentially** in
a single session — not two genuinely simultaneous connections. The
enforcement mechanism (a unique index checked at insert time, or a
`for update` row lock plus a status check) is identical regardless of
whether the second attempt arrives a nanosecond or a full second after
the first, so this is a meaningful regression test for the constraint
itself. It is not a substitute for a true two-connection timing test
(e.g. two parallel `psql` processes coordinated with `pg_sleep`), which
would need its own harness outside plain SQL — flagged as a possible
follow-up, not built here.
