-- 00000000000008_row_level_security.sql
--
-- *** TEMPORARY DEVELOPMENT POLICY -- READ BEFORE DEPLOYING TO PRODUCTION ***
--
-- The existing application (blend-case-manager.html) has NO authentication
-- system at all: it is a static HTML/JS prototype using localStorage, with
-- no login, no session, no user identity. There is therefore no
-- `auth.uid()` to scope rows to.
--
-- RLS is enabled on every table below (never left off), but the policies
-- currently grant the anon role full read/write access to all rows. This
-- is intentionally permissive so the existing no-login UI keeps working
-- against Supabase, but it means:
--   - ANY holder of the anon/publishable key can read, insert, update, and
--     (for non-append-only tables) delete every blend case in the project.
--   - There is no per-user or per-role restriction of any kind.
--
-- RISK: do not point this project at real operational data, and do not
-- ship this policy set to production. Before a production rollout:
--   1. Add real authentication (e.g. Supabase Auth) to the app.
--   2. Replace `using (true)` / `with check (true)` below with policies
--      scoped to auth.uid() / a role claim (e.g. operator vs. viewer).
--   3. Remove UPDATE/DELETE from anon entirely and route writes through
--      SECURITY DEFINER RPCs (like create_blend_case /
--      change_blend_case_status) that enforce business rules server-side.
--
-- blend_case_events is append-only by design: anon gets INSERT + SELECT
-- only, no UPDATE/DELETE, matching "append-only operational history".

alter table public.blend_plans           enable row level security;
alter table public.blend_cases           enable row level security;
alter table public.blend_case_deliveries enable row level security;
alter table public.blend_case_events     enable row level security;
alter table public.blend_case_results    enable row level security;

-- blend_plans: full CRUD for the prototype's anon client.
create policy "dev_anon_select_blend_plans" on public.blend_plans
  for select to anon, authenticated using (true);
create policy "dev_anon_insert_blend_plans" on public.blend_plans
  for insert to anon, authenticated with check (true);
create policy "dev_anon_update_blend_plans" on public.blend_plans
  for update to anon, authenticated using (true) with check (true);

-- blend_cases: full CRUD for the prototype's anon client.
create policy "dev_anon_select_blend_cases" on public.blend_cases
  for select to anon, authenticated using (true);
create policy "dev_anon_insert_blend_cases" on public.blend_cases
  for insert to anon, authenticated with check (true);
create policy "dev_anon_update_blend_cases" on public.blend_cases
  for update to anon, authenticated using (true) with check (true);

-- blend_case_deliveries: full CRUD (planned rows are inserted at plan
-- time, actuals are updated independently on offload completion).
create policy "dev_anon_select_blend_case_deliveries" on public.blend_case_deliveries
  for select to anon, authenticated using (true);
create policy "dev_anon_insert_blend_case_deliveries" on public.blend_case_deliveries
  for insert to anon, authenticated with check (true);
create policy "dev_anon_update_blend_case_deliveries" on public.blend_case_deliveries
  for update to anon, authenticated using (true) with check (true);

-- blend_case_events: INSERT + SELECT only -- append-only, no update/delete
-- policy is defined, so those operations are rejected by RLS by default.
create policy "dev_anon_select_blend_case_events" on public.blend_case_events
  for select to anon, authenticated using (true);
create policy "dev_anon_insert_blend_case_events" on public.blend_case_events
  for insert to anon, authenticated with check (true);

-- blend_case_results: full CRUD (upserted as certification/close-gauge/
-- completion data becomes available).
create policy "dev_anon_select_blend_case_results" on public.blend_case_results
  for select to anon, authenticated using (true);
create policy "dev_anon_insert_blend_case_results" on public.blend_case_results
  for insert to anon, authenticated with check (true);
create policy "dev_anon_update_blend_case_results" on public.blend_case_results
  for update to anon, authenticated using (true) with check (true);

-- RPCs are SECURITY DEFINER (see migration 007) -- explicitly grant EXECUTE
-- to anon/authenticated so the browser client can call them.
grant execute on function public.create_blend_case to anon, authenticated;
grant execute on function public.change_blend_case_status to anon, authenticated;
