-- 00000000000013_blend_case_lifecycle_columns.sql
--
-- Hardening pass, part 1: add the columns needed for an abandonment
-- workflow (replacing hard delete), optimistic concurrency control, an
-- atomic checkout lease, and a canonical per-tank key that can be
-- constrained safely even though blend_cases.tank_no is sometimes an
-- empty string in existing/legacy rows.
--
-- No behavior changes yet -- RPCs that use these columns are added in
-- later migrations in this pass.

alter table public.blend_cases
  add column if not exists record_version    bigint not null default 1,
  add column if not exists abandoned_at      timestamptz,
  add column if not exists abandoned_by      text,
  add column if not exists abandonment_reason text,
  add column if not exists checkout_token    uuid,
  add column if not exists checkout_expires_at timestamptz;

comment on column public.blend_cases.record_version is
  'Optimistic concurrency token. Incremented by every mutation RPC. Callers must pass the version they last read; a mismatch is rejected so stale writes never silently overwrite newer data.';
comment on column public.blend_cases.abandoned_at is
  'Set by abandon_blend_case(). Distinct from completed_at (normal closure) -- abandonment ends a case without completing the workflow, but never deletes it.';
comment on column public.blend_cases.checkout_token is
  'Server-issued opaque lease token for the current checkout, set by checkout_blend_case(). A client must present the matching token to release or to have some mutating RPCs act on the case. Not an identity/auth mechanism -- see row_level_security migrations for that caveat.';
comment on column public.blend_cases.checkout_expires_at is
  'Lease expiration for the current checkout. An expired lease may be acquired by a different device without a force-release.';

-- status now includes 'abandoned' alongside the existing open/hold/closed.
alter table public.blend_cases drop constraint if exists blend_cases_status_check;
alter table public.blend_cases
  add constraint blend_cases_status_check
  check (status in ('open', 'hold', 'closed', 'abandoned'));

-- Canonical tank identifier used for the "one active case per tank"
-- constraint added in the next migration. tank_no is the physical asset
-- tag and is preferred, but some existing/legacy rows have it as an empty
-- string rather than null (see blend_plans_tank_no_nullable migration for
-- why tank_no can be blank upstream), so fall back to a normalized tank
-- label in that case. Stored (not virtual) so it can be indexed cheaply.
alter table public.blend_cases
  add column if not exists tank_key text
  generated always as (
    coalesce(nullif(trim(tank_no), ''), upper(trim(tank)))
  ) stored;

comment on column public.blend_cases.tank_key is
  'Canonical per-tank identifier used to enforce one active case per tank. Prefers tank_no (physical asset tag); falls back to a normalized tank label when tank_no is blank.';
