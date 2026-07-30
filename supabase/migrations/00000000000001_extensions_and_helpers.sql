-- 00000000000001_extensions_and_helpers.sql
-- Extensions and shared helper function used by every table below.

create extension if not exists pgcrypto; -- gen_random_uuid()

-- Generic "touch updated_at" trigger function, reused by every table that
-- has an updated_at column.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Shared BEFORE UPDATE trigger that stamps updated_at = now() on every row change.';
