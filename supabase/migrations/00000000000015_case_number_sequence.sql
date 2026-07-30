-- 00000000000015_case_number_sequence.sql
--
-- Hardening pass, part 3: stop trusting the browser to generate
-- case_number (it was a random 4-digit suffix -- collision-prone and not
-- authoritative). A Postgres sequence is atomic under concurrency by
-- construction, so nextval() is the generator.
--
-- Format: BL-<year>-<6-digit sequence>, e.g. BL-2026-000123. The sequence
-- is global (not reset per year) -- the year in the string is a display
-- convenience, not a per-year counter, so no reset logic is needed and no
-- collisions are possible across years since the year prefix differs.
-- Existing shorter-form numbers (e.g. BL-2026-6719) remain valid: the
-- unique constraint is on the whole text value, and formats never collide
-- because new numbers are always 6 digits.

create sequence if not exists public.blend_case_number_seq start 1;

create or replace function public.next_blend_case_number()
returns text
language sql
volatile
as $$
  select 'BL-' || extract(year from now())::int || '-' ||
         lpad(nextval('public.blend_case_number_seq')::text, 6, '0');
$$;

comment on function public.next_blend_case_number() is
  'Atomically allocates the next case number (BL-<year>-<6-digit seq>). The browser must never generate case numbers itself; create_blend_case() calls this internally.';

revoke all on sequence public.blend_case_number_seq from public;
grant usage on sequence public.blend_case_number_seq to anon, authenticated;
